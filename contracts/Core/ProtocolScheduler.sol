// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ProtocolIsPaused, ZeroAddress} from "../Errors/CommonErrors.sol";
import {AlreadyProcessed, InvalidUser, SchedulerIsPaused, UnauthorizedCaller} from "../Errors/SchedulerErrors.sol";
import {IProtocolConfig} from "../Interfaces/IProtocolConfig.sol";
import {IProtocolScheduler} from "../Interfaces/IProtocolScheduler.sol";

/// @title ProtocolScheduler
/// @author Aurex Protocol
/// @notice The protocol's single timing source and duplicate-execution guard.
/// @dev
/// ## Purpose
/// Derives the protocol day / week / month from the launch timestamp and records which users
/// have been processed in each period, so downstream logic (the ProtocolEngine, in a later
/// phase) can never process the same user twice for the same period.
///
/// ## Boundaries
/// This contract only tracks time and execution state. It performs **no** reward
/// calculations. Days/weeks/months are fixed windows: 1 day, 7 days and 30 days.
///
/// ## Upgradeability
/// UUPS (ERC-1967). Deploy behind an `ERC1967Proxy`; only the owner may authorize an upgrade,
/// pause or resume the scheduler.
contract ProtocolScheduler is Initializable, OwnableUpgradeable, UUPSUpgradeable, IProtocolScheduler {
    /// @notice Length of a protocol day, in seconds.
    uint256 public constant DAY = 1 days;

    /// @notice Length of a protocol week, in seconds.
    uint256 public constant WEEK = 7 days;

    /// @notice Length of a protocol month, in seconds.
    uint256 public constant MONTH = 30 days;

    /// @inheritdoc IProtocolScheduler
    uint256 public override protocolLaunchTimestamp;

    /// @inheritdoc IProtocolScheduler
    uint256 public override currentProtocolDay;
    /// @inheritdoc IProtocolScheduler
    uint256 public override currentProtocolWeek;
    /// @inheritdoc IProtocolScheduler
    uint256 public override currentProtocolMonth;

    /// @inheritdoc IProtocolScheduler
    uint256 public override lastDailyExecution;
    /// @inheritdoc IProtocolScheduler
    uint256 public override lastWeeklyExecution;
    /// @inheritdoc IProtocolScheduler
    uint256 public override lastMonthlyExecution;

    /// @inheritdoc IProtocolScheduler
    bool public override schedulerPaused;

    /// @inheritdoc IProtocolScheduler
    mapping(address user => mapping(uint256 day => bool processed)) public override dailyProcessed;
    /// @inheritdoc IProtocolScheduler
    mapping(address user => mapping(uint256 week => bool processed)) public override weeklyProcessed;
    /// @inheritdoc IProtocolScheduler
    mapping(address user => mapping(uint256 month => bool processed)) public override monthlyProcessed;

    /// @notice The ProtocolConfig consulted for the protocol-wide pause. Owner-updatable.
    /// @dev Zero until wired; while zero, the protocol-wide pause is not enforced here. Appended in
    ///      the operational phase.
    address public protocolConfig;

    /// @notice Whether an address is authorized to mark daily/weekly/monthly processing. Owner-managed.
    /// @dev Appended in the corrective phase to close the scheduler-marking griefing vector: only the
    ///      ProtocolEngine (and any future authorized processor) may consume a user's period slot, so
    ///      an arbitrary caller can no longer pre-mark a victim and permanently deny their rewards.
    mapping(address account => bool authorized) public override authorizedCallers;

    /// @notice Reserved storage slots (13 used + 37 reserved = 50) for forward-compatible upgrades.
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[37] private __gap;

    /// @notice Emitted when the owner updates the ProtocolConfig address.
    event ProtocolConfigUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when a caller is authorized to mark processing.
    event CallerAuthorized(address indexed account);

    /// @notice Emitted when a caller's marking authorization is revoked.
    event CallerRevoked(address indexed account);

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the scheduler, assigns ownership and records the launch timestamp.
    /// @dev Callable exactly once, on the proxy. The launch timestamp anchors all timing.
    /// @param owner_ Protocol administrator; may pause/resume and authorize upgrades.
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        protocolLaunchTimestamp = block.timestamp;
    }

    // -------------------------------------------------------------------------
    // Timing views
    // -------------------------------------------------------------------------

    /// @inheritdoc IProtocolScheduler
    function daysSinceLaunch() public view override returns (uint256) {
        return (block.timestamp - protocolLaunchTimestamp) / DAY;
    }

    /// @inheritdoc IProtocolScheduler
    function weeksSinceLaunch() public view override returns (uint256) {
        return (block.timestamp - protocolLaunchTimestamp) / WEEK;
    }

    /// @inheritdoc IProtocolScheduler
    function monthsSinceLaunch() public view override returns (uint256) {
        return (block.timestamp - protocolLaunchTimestamp) / MONTH;
    }

    /// @inheritdoc IProtocolScheduler
    function currentDay() public view override returns (uint256) {
        return daysSinceLaunch() + 1;
    }

    /// @inheritdoc IProtocolScheduler
    function currentWeek() public view override returns (uint256) {
        return weeksSinceLaunch() + 1;
    }

    /// @inheritdoc IProtocolScheduler
    function currentMonth() public view override returns (uint256) {
        return monthsSinceLaunch() + 1;
    }

    // -------------------------------------------------------------------------
    // Execution guards
    // -------------------------------------------------------------------------

    /// @inheritdoc IProtocolScheduler
    function canProcessDaily(address user) external view override returns (bool) {
        return !schedulerPaused && !dailyProcessed[user][currentDay()];
    }

    /// @inheritdoc IProtocolScheduler
    function canProcessWeekly(address user) external view override returns (bool) {
        return !schedulerPaused && !weeklyProcessed[user][currentWeek()];
    }

    /// @inheritdoc IProtocolScheduler
    function canProcessMonthly(address user) external view override returns (bool) {
        return !schedulerPaused && !monthlyProcessed[user][currentMonth()];
    }

    /// @inheritdoc IProtocolScheduler
    function markDailyProcessed(address user) external override {
        _requireProcessable(user);
        uint256 day = currentDay();
        if (dailyProcessed[user][day]) revert AlreadyProcessed();

        dailyProcessed[user][day] = true;
        currentProtocolDay = day;
        lastDailyExecution = block.timestamp;

        emit DailyMarked(user, day);
    }

    /// @inheritdoc IProtocolScheduler
    function markWeeklyProcessed(address user) external override {
        _requireProcessable(user);
        uint256 week = currentWeek();
        if (weeklyProcessed[user][week]) revert AlreadyProcessed();

        weeklyProcessed[user][week] = true;
        currentProtocolWeek = week;
        lastWeeklyExecution = block.timestamp;

        emit WeeklyMarked(user, week);
    }

    /// @inheritdoc IProtocolScheduler
    function markMonthlyProcessed(address user) external override {
        _requireProcessable(user);
        uint256 month = currentMonth();
        if (monthlyProcessed[user][month]) revert AlreadyProcessed();

        monthlyProcessed[user][month] = true;
        currentProtocolMonth = month;
        lastMonthlyExecution = block.timestamp;

        emit MonthlyMarked(user, month);
    }

    // -------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------

    /// @notice Pauses the scheduler, blocking all `mark*` executions.
    function pauseScheduler() external onlyOwner {
        schedulerPaused = true;
        emit SchedulerPaused();
    }

    /// @notice Resumes the scheduler.
    function resumeScheduler() external onlyOwner {
        schedulerPaused = false;
        emit SchedulerResumed();
    }

    /// @notice Updates the ProtocolConfig address consulted for the protocol-wide pause.
    /// @param newProtocolConfig The new ProtocolConfig address (non-zero).
    function setProtocolConfig(address newProtocolConfig) external onlyOwner {
        if (newProtocolConfig == address(0)) revert ZeroAddress();
        address previous = protocolConfig;
        protocolConfig = newProtocolConfig;
        emit ProtocolConfigUpdated(previous, newProtocolConfig);
    }

    /// @notice Authorizes `account` to mark daily/weekly/monthly processing.
    /// @dev Deployment MUST authorize the ProtocolEngine so its `processDaily/WeeklyReward` flow can
    ///      mark periods; no other account should be authorized in production.
    /// @param account The address to authorize (non-zero).
    function authorizeCaller(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedCallers[account] = true;
        emit CallerAuthorized(account);
    }

    /// @notice Revokes `account`'s authorization to mark processing.
    /// @param account The address to de-authorize (non-zero).
    function removeAuthorizedCaller(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedCallers[account] = false;
        emit CallerRevoked(account);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Shared guard for `mark*`: reverts unless the caller is authorized (the owner or an
    ///      authorized processor), then if the scheduler is paused, the protocol is paused (when a
    ///      ProtocolConfig is wired), or the user is invalid. The caller check is first so an
    ///      unauthorized account can never consume a user's period slot (griefing).
    function _requireProcessable(address user) private view {
        if (msg.sender != owner() && !authorizedCallers[msg.sender]) revert UnauthorizedCaller();
        if (schedulerPaused) revert SchedulerIsPaused();
        address pc = protocolConfig;
        if (pc != address(0) && IProtocolConfig(pc).protocolPaused()) revert ProtocolIsPaused();
        if (user == address(0)) revert InvalidUser();
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
