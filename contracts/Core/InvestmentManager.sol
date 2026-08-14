// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AlreadyPaused, ModuleIsPaused, NotPaused, ProtocolIsPaused, ZeroAddress} from "../Errors/CommonErrors.sol";
import {
    AlreadyRegistered,
    AutoReinvestDisabled,
    DailyDepositLimitExceeded,
    InvalidInvestmentIndex,
    InvalidPackage,
    InvalidReferral,
    PackageNotUpgradeable,
    RegistryRepairMismatch,
    ReinvestAmountOutOfBounds,
    ReinvestCooldownActive,
    SelfReferral,
    UnauthorizedCaller,
    UserNotActive,
    UserNotRegistered
} from "../Errors/InvestmentErrors.sol";
import {IInvestmentLifecycleEngine} from "../Interfaces/IInvestmentLifecycleEngine.sol";
import {IInvestmentManager} from "../Interfaces/IInvestmentManager.sol";
import {ILiquidityManager} from "../Interfaces/ILiquidityManager.sol";
import {IProtocolConfig} from "../Interfaces/IProtocolConfig.sol";
import {IRankEngine} from "../Interfaces/IRankEngine.sol";

/// @title InvestmentManager
/// @author Aurex Protocol
/// @notice Upgradeable manager for user onboarding, the referral tree, the package lifecycle and
///         the per-user investment history of the Aurex protocol.
/// @dev
/// ## Responsibilities
/// Registration, referral relationships, package purchases / upgrades, and — as of the re-topup
/// phase — an immutable per-user {Investment} history. Every investment event (first investment,
/// re-topup, automatic reinvestment) appends a new investment record: an independent ROI stream
/// with its own start time and ROI accounting. On any investment it moves USDT from the funding
/// wallet straight to the Treasury using `SafeERC20`.
///
/// ## One unified pipeline
/// A first investment, a manual {reTopup} and an {executeAutoReinvestment} all run through the
/// **same** post-investment lifecycle: after recording the investment and collecting funds, the
/// manager forwards the event to the wired {InvestmentLifecycleEngine}, which performs the
/// allocation split and triggers the referral / infinity / weekly / daily-ROI stages. There is
/// never a second investment pipeline. Routing is skipped while the lifecycle engine is unwired.
///
/// ## Explicit non-responsibilities
/// This contract **never** calculates rewards or ROI, transfers rewards, or runs any bonus/payout
/// logic. It only records users, packages and investments (including each investment's accumulated
/// `roiEarned`, supplied by the authorized ProtocolEngine); downstream modules compute and pay.
///
/// ## Rules
/// - One account per wallet; referral is set once at registration and can never change.
/// - Self-referral is prohibited; a referrer must already be registered (the root, set at
///   initialization, is the sole exception).
/// - Packages must be at least the configured minimum (100 USDT) and a whole multiple of the
///   configured step (50 USDT), up to the configured maximum — all read from ProtocolConfig, so
///   e.g. 100, 150, 250 and 1000 are valid. Until a ProtocolConfig is wired the fallback is
///   `packageUnit` for both the minimum and the step.
///
/// ## Upgradeability
/// UUPS (ERC-1967). Deploy behind an `ERC1967Proxy`; state lives in the proxy. Only the owner may
/// authorize an upgrade. New state is appended after the original layout (the storage gap shrinks
/// accordingly), so existing storage slots are preserved. The reentrancy guard is the
/// storage-namespaced OpenZeppelin v5 `ReentrancyGuard` (no initializer required).
contract InvestmentManager is Initializable, OwnableUpgradeable, ReentrancyGuard, UUPSUpgradeable, IInvestmentManager {
    using SafeERC20 for IERC20;

    /// @notice The default package granularity, in whole USDT. Seeds `packageUnit` at
    ///         initialization; the live minimum and step come from ProtocolConfig once populated.
    uint256 public constant MIN_PACKAGE_USDT = 100;

    // --- Original storage layout (slots 0..6) — never reordered -----------------

    /// @notice The Treasury that receives investment funds. Owner-updatable.
    address public override treasury;

    /// @notice The USDT token used for investment. Fixed after initialization.
    address public override usdt;

    /// @notice The ARX token address. Fixed after initialization (reserved for later phases).
    address public override arx;

    /// @notice The package unit in USDT base units: `MIN_PACKAGE_USDT * 10 ** usdt.decimals()`.
    ///         The fallback minimum and step used only while the ProtocolConfig investment rules
    ///         are unwired or unset; otherwise `ProtocolConfig.minimumInvestment` /
    ///         `investmentStep` govern. See {_validatePackage}.
    uint256 public packageUnit;

    /// @notice The total number of registered accounts, including the root account.
    uint256 public override totalUsers;

    /// @notice The total number of package instances ever created (purchases + upgrades + re-topups).
    ///         Also the source of the monotonically increasing package id.
    uint256 public totalPackages;

    /// @notice User records keyed by wallet address.
    mapping(address wallet => User record) private _users;

    // --- Appended storage (slots 7..) — added in the re-topup phase -------------

    /// @notice Per-user investment history. Each entry is an independent, non-overwritable ROI stream.
    mapping(address wallet => Investment[] history) private _investments;

    /// @notice Whether an address is authorized to record ROI / execute automatic reinvestment.
    mapping(address account => bool authorized) public override authorizedContracts;

    /// @notice The InvestmentLifecycleEngine every investment event is routed through. Owner-updatable.
    /// @dev Zero until wired; while zero, lifecycle routing is skipped (the record and fund transfer
    ///      still occur). Set by the owner via {setLifecycleEngine}.
    address public override lifecycleEngine;

    /// @notice The ProtocolConfig read for the automatic-reinvestment bounds/toggle. Owner-updatable.
    /// @dev Zero until wired; while zero, reinvest bounds are not enforced and auto-reinvest
    ///      execution is disabled.
    address public protocolConfig;

    /// @notice The total number of investment records ever created across all users.
    uint256 public override totalInvestments;

    /// @notice Per-user automatic-reinvestment configuration.
    mapping(address wallet => AutoReinvestConfig config) private _autoReinvest;

    /// @notice Whether new investments / re-topups / auto-reinvestments are paused at the module level
    ///         (independent of the protocol-wide pause). Owner-controlled. Appended in the operational phase.
    bool public investmentsPaused;

    // --- Appended storage (spec-v2.1 phase) -----------------------------------

    /// @notice The RankEngine consulted for the depositor's rank (daily-limit scaling).
    ///         Owner-updatable; zero = every depositor uses the rank-0 limit.
    address public rankEngine;

    /// @notice Cumulative deposits per user per UTC day (`day = block.timestamp / 1 days`), in
    ///         USDT base units. Backs the rank-scaled daily deposit limits.
    mapping(address wallet => mapping(uint256 day => uint256 total)) private _dailyDeposited;

    // --- On-chain network registry (appended in the tree/keeper phase) ---------
    // Enumeration that event logs previously provided; stored on-chain so keepers and the
    // frontend tree never depend on RPC `eth_getLogs` availability.

    /// @notice Every wallet ever registered (excluding the root), in registration order.
    address[] private _allUsers;

    /// @notice Direct referrals per referrer, in registration order.
    mapping(address referrer => address[] directs) private _directReferrals;

    // --- Appended storage (company-share phase) — APPEND-ONLY below this line --

    /// @notice The company/creator wallet paid the treasury-allocation share of every deposit
    ///         INSTANTLY at deposit time (the business owner's 20%). Owner-updatable; zero
    ///         disables the instant split — the share then stays in the Treasury vault.
    /// @dev Appended AFTER the registry arrays. An earlier implementation wrongly inserted this
    ///      slot BEFORE them (an upgrade-layout violation that shifted the registry); the
    ///      corrected order restores the original slots, and {repairRegistryLength} recovers the
    ///      one value that upgrade overwrote.
    address public companyWallet;

    /// @notice The LiquidityManager that executes the deposit-funded buyback. Owner-updatable; zero
    ///         disables the buyback leg entirely, so the deposit splits company/Treasury as before.
    /// @dev Appended AFTER {companyWallet}, consuming one gap slot. Every slot declared above keeps
    ///      its position.
    address public liquidityManager;

    /// @notice Reserved storage slots (19 used + 31 reserved = 50) for forward-compatible upgrades.
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[31] private __gap;

    /// @notice Emitted when investments are paused at the module level.
    event InvestmentsPaused(address indexed account);

    /// @notice Emitted when investments are resumed at the module level.
    event InvestmentsResumed(address indexed account);

    /// @notice Restricts a function to the owner or an authorized protocol contract.
    modifier onlyAuthorized() {
        _requireAuthorized();
        _;
    }

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the manager, wires protocol addresses and registers the root.
    /// @dev Callable exactly once, on the proxy. The owner becomes the root account of the
    ///      referral tree. `packageUnit` is derived from the USDT token's decimals.
    /// @param owner_ Protocol administrator and root account.
    /// @param treasury_ Treasury that receives investment funds.
    /// @param usdt_ USDT token used for investment.
    /// @param arx_ ARX token address (stored for later phases).
    function initialize(address owner_, address treasury_, address usdt_, address arx_) external initializer {
        if (owner_ == address(0) || treasury_ == address(0) || usdt_ == address(0) || arx_ == address(0)) {
            revert ZeroAddress();
        }

        __Ownable_init(owner_);

        treasury = treasury_;
        usdt = usdt_;
        arx = arx_;
        packageUnit = MIN_PACKAGE_USDT * 10 ** IERC20Metadata(usdt_).decimals();

        // The owner is the root of the referral tree: registered, with no referrer.
        _users[owner_].registered = true;
        totalUsers = 1;
        emit UserRegistered(owner_, address(0));
    }

    // -------------------------------------------------------------------------
    // Owner configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the Treasury address. USDT and ARX are fixed and cannot be changed.
    /// @param newTreasury The new Treasury address (non-zero).
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    /// @notice Updates the InvestmentLifecycleEngine every investment event is routed through.
    /// @param newLifecycleEngine The new lifecycle engine address (non-zero).
    function setLifecycleEngine(address newLifecycleEngine) external onlyOwner {
        if (newLifecycleEngine == address(0)) revert ZeroAddress();
        address previous = lifecycleEngine;
        lifecycleEngine = newLifecycleEngine;
        emit LifecycleEngineUpdated(previous, newLifecycleEngine);
    }

    /// @notice Updates the ProtocolConfig read for automatic-reinvestment bounds and the toggle.
    /// @param newProtocolConfig The new ProtocolConfig address (non-zero).
    function setProtocolConfig(address newProtocolConfig) external onlyOwner {
        if (newProtocolConfig == address(0)) revert ZeroAddress();
        protocolConfig = newProtocolConfig;
    }

    /// @notice Updates the RankEngine consulted for rank-scaled daily deposit limits.
    /// @param newRankEngine The new RankEngine address (non-zero).
    function setRankEngine(address newRankEngine) external onlyOwner {
        if (newRankEngine == address(0)) revert ZeroAddress();
        address previous = rankEngine;
        rankEngine = newRankEngine;
        emit RankEngineUpdated(previous, newRankEngine);
    }

    /// @notice Updates the company/creator wallet paid the treasury share of every deposit
    ///         instantly. Zero disables the instant split (the share stays in the Treasury).
    /// @param newCompanyWallet The company wallet (zero allowed = disabled).
    function setCompanyWallet(address newCompanyWallet) external onlyOwner {
        address previous = companyWallet;
        companyWallet = newCompanyWallet;
        emit CompanyWalletUpdated(previous, newCompanyWallet);
    }

    /// @notice Updates the LiquidityManager that runs the deposit-funded buyback.
    /// @dev Zero disables the buyback leg: deposits then split company/Treasury exactly as they did
    ///      before the buyback existed, so this doubles as the kill switch if the DEX side misbehaves.
    /// @param newLiquidityManager The LiquidityManager (zero allowed = buyback disabled).
    function setLiquidityManager(address newLiquidityManager) external onlyOwner {
        address previous = liquidityManager;
        liquidityManager = newLiquidityManager;
        emit LiquidityManagerUpdated(previous, newLiquidityManager);
    }

    /// @notice Grants `account` authorization to record ROI / execute automatic reinvestment.
    /// @param account The address to authorize (non-zero).
    function authorizeContract(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedContracts[account] = true;
        emit AuthorizedContractAdded(account);
    }

    /// @notice Revokes `account`'s authorization.
    /// @param account The address to de-authorize (non-zero).
    function removeAuthorizedContract(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedContracts[account] = false;
        emit AuthorizedContractRemoved(account);
    }

    /// @notice Pauses new investments, re-topups and auto-reinvestments at the module level.
    function pauseInvestments() external onlyOwner {
        if (investmentsPaused) revert AlreadyPaused();
        investmentsPaused = true;
        emit InvestmentsPaused(msg.sender);
    }

    /// @notice Resumes investments at the module level.
    function resumeInvestments() external onlyOwner {
        if (!investmentsPaused) revert NotPaused();
        investmentsPaused = false;
        emit InvestmentsResumed(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Investment & packages
    // -------------------------------------------------------------------------

    /// @notice Registers the caller (first call only) and purchases their first package.
    /// @dev The caller must have approved this contract for at least `amount` USDT. Funds are
    ///      transferred straight to the Treasury, a first {Investment} record is appended, and the
    ///      post-investment lifecycle is run when the lifecycle engine is wired. No rewards, ROI or
    ///      payouts are computed here.
    /// @param amount The package amount, in USDT base units (>= the configured minimum, a whole
    ///        multiple of the configured step — 100 USDT and 50 USDT respectively).
    /// @param referrer The referring account (must already be registered).
    function invest(uint256 amount, address referrer) external override nonReentrant {
        User storage user = _users[msg.sender];
        if (user.registered) revert AlreadyRegistered();
        _requireNotPaused();
        _validatePackage(amount);
        _recordDailyDeposit(msg.sender, amount);
        if (referrer == msg.sender) revert SelfReferral();
        if (!_users[referrer].registered) revert InvalidReferral();

        totalPackages += 1;
        uint256 packageId = totalPackages;

        user.registered = true;
        user.active = true;
        user.referrer = referrer;
        user.packageAmount = amount;
        user.totalInvested = amount;
        user.packageStart = block.timestamp;
        user.packageId = packageId;
        totalUsers += 1;
        _allUsers.push(msg.sender);
        _directReferrals[referrer].push(msg.sender);

        uint256 index = _pushInvestment(msg.sender, amount, packageId);

        _collectDeposit(msg.sender, amount);

        emit UserRegistered(msg.sender, referrer);
        emit PackagePurchased(msg.sender, packageId, amount);
        emit InvestmentCreated(msg.sender, index, packageId, amount, block.timestamp);
        emit InvestmentActivated(msg.sender, index, packageId);

        _runLifecycle(msg.sender, amount);
    }

    /// @notice Upgrades the caller's active package to a larger amount, paying the difference.
    /// @dev Replaces the current package: it opens a new package id with a fresh timestamp, transfers
    ///      only the difference to the Treasury, and updates the current (latest) investment stream in
    ///      place so ROI accrues on the new amount from the upgrade time. Investment history for prior
    ///      streams is untouched. A zero-difference upgrade (`newAmount == previousAmount`) is a true
    ///      no-op: no state changes, no funds move, no events are emitted, and no lifecycle runs.
    ///
    ///      When the latest stream has already **completed**, it is left untouched — `Completed` is a
    ///      terminal state — and the incremental capital is appended as a new independent stream
    ///      instead, so a finished stream is never reactivated. Each stream therefore always pays
    ///      exactly its own frozen entitlement, and the caller's total remains bound by the global
    ///      earnings cap either way.
    /// @param newAmount The new package amount, in USDT base units (>= current, a whole multiple of
    ///        the configured step).
    function upgradePackage(uint256 newAmount) external override nonReentrant {
        User storage user = _users[msg.sender];
        if (!user.registered) revert UserNotRegistered();
        _requireNotPaused();
        _validatePackage(newAmount);

        uint256 previousAmount = user.packageAmount;
        if (newAmount < previousAmount) revert PackageNotUpgradeable();

        uint256 difference = newAmount - previousAmount;
        // A zero-difference upgrade (newAmount == previousAmount) is a TRUE no-op: no state changes,
        // no funds move, no events, no lifecycle. Return before any write to preserve that semantics.
        if (difference == 0) return;
        // Only the incremental difference is new capital, so only it counts toward the daily limit.
        _recordDailyDeposit(msg.sender, difference);

        totalPackages += 1;
        uint256 packageId = totalPackages;

        user.packageAmount = newAmount;
        user.totalInvested += difference;
        user.active = true;
        user.packageStart = block.timestamp;
        user.packageId = packageId;
        user.upgradeCount += 1;

        // Reflect the upgrade in the current (latest) investment stream so ROI accrues on the new
        // amount from the upgrade timestamp, mirroring the package-summary replacement. The frozen
        // economics are re-snapshotted (the stream's clock resets) so this renewed stream uses the
        // economics in force at the upgrade — never a stale or future config.
        //
        // A COMPLETED stream is exempt: `Completed` is terminal. That stream has already paid out
        // its own frozen entitlement, so rewriting it would reactivate a finished stream with a
        // fresh clock and a cap re-based on the larger amount — breaking the "history is immutable,
        // streams are independent" model, and (whenever `dailyBps * durationDays < maxBps`) paying
        // out headroom the expired stream had already forfeited. The incremental capital is appended
        // as its own independent stream instead, exactly as {reTopup} does.
        Investment[] storage list = _investments[msg.sender];
        if (list.length != 0) {
            Investment storage current = list[list.length - 1];
            if (current.status == InvestmentStatus.Completed) {
                uint256 index = _pushInvestment(msg.sender, difference, packageId);
                emit InvestmentCreated(msg.sender, index, packageId, difference, block.timestamp);
                emit InvestmentActivated(msg.sender, index, packageId);
            } else {
                current.amount = newAmount;
                current.startTime = block.timestamp;
                current.packageId = packageId;
                current.status = InvestmentStatus.Active;
                (uint256 roiPct, uint256 roiDur, uint256 maxRoi, uint256 price) = _frozenEconomics();
                current.roiPercentage = roiPct;
                current.roiDurationDays = roiDur;
                current.maxRoiPercentage = maxRoi;
                current.oraclePrice = price;
            }
        }

        _collectDeposit(msg.sender, difference);

        emit PackageUpgraded(msg.sender, packageId, previousAmount, newAmount);

        // An upgrade is new capital entering the protocol: run the **complete** investment lifecycle
        // on the incremental `difference` only (never the full package), exactly like any other
        // investment — direct referral, infinity, the liquidity/protocol split and reserve
        // accounting. Basing it on the difference means the portion already invested at the previous
        // package is never re-counted, so no reward or allocation is duplicated.
        // `difference` is guaranteed non-zero here (a zero-difference upgrade returned early above).
        _runLifecycle(msg.sender, difference);
    }

    /// @inheritdoc IInvestmentManager
    /// @dev A re-topup is simply another investment event by an existing active user: it validates
    ///      the package, appends a brand-new independent {Investment} stream (existing history stays
    ///      immutable), transfers the funds to the Treasury and runs the same post-investment
    ///      lifecycle as a first investment. `nonReentrant`.
    function reTopup(uint256 amount) external override nonReentrant {
        User storage user = _users[msg.sender];
        if (!user.registered) revert UserNotRegistered();
        if (!user.active) revert UserNotActive();
        _requireNotPaused();

        emit ReTopupStarted(msg.sender, totalPackages + 1, amount);
        uint256 packageId = _investAgain(msg.sender, amount);
        emit ReTopupCompleted(msg.sender, packageId, amount);
    }

    // -------------------------------------------------------------------------
    // Automatic reinvestment
    // -------------------------------------------------------------------------

    /// @inheritdoc IInvestmentManager
    function setAutoReinvestment(bool enabled, uint256 amount) external override {
        if (!_users[msg.sender].registered) revert UserNotRegistered();

        AutoReinvestConfig storage cfg = _autoReinvest[msg.sender];
        if (enabled) {
            _validatePackage(amount);
            _validateReinvestBounds(amount);
            cfg.enabled = true;
            cfg.amount = amount;
            emit AutoReinvestmentEnabled(msg.sender, amount);
        } else {
            cfg.enabled = false;
            emit AutoReinvestmentDisabled(msg.sender);
        }
    }

    /// @inheritdoc IInvestmentManager
    /// @dev Authorized automation only. Reuses the manual re-topup core, so the reinvestment flows
    ///      through the same lifecycle. Funds are pulled from `user` (who opted in and approved this
    ///      contract). Enforces the per-user toggle, the global toggle, the reinvest cooldown and the
    ///      reinvest bounds — all read from the ProtocolConfig. `nonReentrant`.
    function executeAutoReinvestment(address user) external override nonReentrant onlyAuthorized {
        User storage u = _users[user];
        if (!u.registered) revert UserNotRegistered();
        if (!u.active) revert UserNotActive();
        _requireNotPaused();

        AutoReinvestConfig storage cfg = _autoReinvest[user];
        if (!cfg.enabled) revert AutoReinvestDisabled();

        address pc = protocolConfig;
        if (pc == address(0)) revert AutoReinvestDisabled();
        IProtocolConfig config = IProtocolConfig(pc);
        if (!config.autoReinvestEnabled()) revert AutoReinvestDisabled();

        uint256 cooldown = config.reinvestCooldown();
        // Cooldown timing: a validator's few-seconds timestamp leeway is immaterial to a cooldown.
        // forge-lint: disable-next-line(block-timestamp)
        if (cfg.lastExecuted != 0 && block.timestamp < cfg.lastExecuted + cooldown) {
            revert ReinvestCooldownActive();
        }

        uint256 amount = cfg.amount;
        _validateReinvestBounds(amount);

        cfg.lastExecuted = block.timestamp;
        uint256 packageId = _investAgain(user, amount);
        emit AutoReinvestmentExecuted(user, packageId, amount);
    }

    // -------------------------------------------------------------------------
    // ROI recording (authorized recorders only)
    // -------------------------------------------------------------------------

    /// @inheritdoc IInvestmentManager
    /// @dev Storage only: the ProtocolEngine computes the ROI and this contract records it. For each
    ///      index it adds `roiAmounts[i]` to that investment's `roiEarned` and, when `completedFlags[i]`
    ///      is set, flips the investment to {InvestmentStatus.Completed}. The array lengths must match
    ///      the user's investment count. `roiEarned` is only ever increased; history is never rewritten.
    function recordInvestmentROIBatch(address user, uint256[] calldata roiAmounts, bool[] calldata completedFlags)
        external
        override
        onlyAuthorized
    {
        Investment[] storage list = _investments[user];
        uint256 len = list.length;
        if (roiAmounts.length != len || completedFlags.length != len) revert InvalidInvestmentIndex();

        for (uint256 i = 0; i < len; i++) {
            uint256 addend = roiAmounts[i];
            bool complete = completedFlags[i];
            if (addend == 0 && !complete) continue;

            Investment storage inv = list[i];
            if (addend != 0) {
                inv.roiEarned += addend;
                emit InvestmentROIRecorded(user, i, addend, inv.roiEarned);
            }
            if (complete && inv.status != InvestmentStatus.Completed) {
                inv.status = InvestmentStatus.Completed;
                emit InvestmentCompleted(user, i, inv.roiEarned);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IInvestmentManager
    function isRegistered(address user) external view override returns (bool) {
        return _users[user].registered;
    }

    /// @inheritdoc IInvestmentManager
    function getUser(address user) external view override returns (User memory) {
        return _users[user];
    }

    /// @inheritdoc IInvestmentManager
    function getPackage(address user)
        external
        view
        override
        returns (uint256 packageId, uint256 packageAmount, uint256 packageStart, bool active)
    {
        User storage record = _users[user];
        return (record.packageId, record.packageAmount, record.packageStart, record.active);
    }

    /// @inheritdoc IInvestmentManager
    function getInvestments(address user) external view override returns (Investment[] memory) {
        return _investments[user];
    }

    /// @inheritdoc IInvestmentManager
    function getInvestment(address user, uint256 index) external view override returns (Investment memory) {
        Investment[] storage list = _investments[user];
        if (index >= list.length) revert InvalidInvestmentIndex();
        return list[index];
    }

    /// @inheritdoc IInvestmentManager
    function investmentCount(address user) external view override returns (uint256) {
        return _investments[user].length;
    }

    /// @inheritdoc IInvestmentManager
    function getAutoReinvestConfig(address user) external view override returns (AutoReinvestConfig memory) {
        return _autoReinvest[user];
    }

    /// @inheritdoc IInvestmentManager
    function dailyDepositedToday(address user) external view override returns (uint256) {
        // forge-lint: disable-next-line(block-timestamp)
        return _dailyDeposited[user][block.timestamp / 1 days];
    }

    /// @inheritdoc IInvestmentManager
    function registeredUserCount() external view override returns (uint256) {
        return _allUsers.length;
    }

    /// @inheritdoc IInvestmentManager
    function userAt(uint256 index) external view override returns (address) {
        return _allUsers[index];
    }

    /// @inheritdoc IInvestmentManager
    function directReferralCount(address referrer) external view override returns (uint256) {
        return _directReferrals[referrer].length;
    }

    /// @inheritdoc IInvestmentManager
    function getDirectReferrals(address referrer, uint256 offset, uint256 limit)
        external
        view
        override
        returns (address[] memory page)
    {
        address[] storage directs = _directReferrals[referrer];
        uint256 len = directs.length;
        if (offset >= len) return new address[](0);
        uint256 end = offset + limit;
        if (end > len || limit == 0) end = len;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = directs[i];
        }
    }

    /// @notice One-time repair for the registry length clobbered by the mis-ordered
    ///         company-wallet upgrade (see {companyWallet} dev note): that implementation's
    ///         `setCompanyWallet` wrote into the slot holding `_allUsers.length`. The array
    ///         CONTENTS were never touched, so restoring the length fully recovers the registry.
    /// @dev Owner-only and self-guarded: the new length must exactly equal `totalUsers - 1`
    ///      (every registration pushes once; the root is not in the registry), and every entry
    ///      up to it must be a registered user — so this can only restore truth, never invent it.
    /// @param newLength The correct registry length.
    function repairRegistryLength(uint256 newLength) external onlyOwner {
        if (newLength != totalUsers - 1) revert RegistryRepairMismatch();
        for (uint256 i = 0; i < newLength; i++) {
            address entry;
            address[] storage list = _allUsers;
            // forge-lint: disable-next-line(asm-keccak256)
            assembly {
                mstore(0x00, list.slot)
                entry := sload(add(keccak256(0x00, 0x20), i))
            }
            if (!_users[entry].registered) revert RegistryRepairMismatch();
        }
        address[] storage arr = _allUsers;
        assembly {
            sstore(arr.slot, newLength)
        }
        emit RegistryLengthRepaired(newLength);
    }

    /// @notice Backfills the network registry for a user registered BEFORE this registry existed.
    /// @dev Owner-only migration helper for upgraded deployments. Fail-safe by construction: the
    ///      relationship is verified against the canonical `referrer` field (set once at
    ///      registration, immutable), and a user already present in the registry is rejected —
    ///      so no relationship can ever be fabricated or duplicated.
    /// @param user The registered user to add to the registry.
    function backfillNetworkRegistry(address user) external onlyOwner {
        User storage record = _users[user];
        if (!record.registered) revert UserNotRegistered();
        address referrer = record.referrer;
        if (referrer == address(0) && user != owner()) revert InvalidReferral();

        // Reject duplicates (linear scan over the referrer's directs — a bounded, owner-only
        // migration path, never on the hot path).
        address[] storage directs = _directReferrals[referrer];
        for (uint256 i = 0; i < directs.length; i++) {
            if (directs[i] == user) revert AlreadyRegistered();
        }

        _allUsers.push(user);
        _directReferrals[referrer].push(user);
        emit NetworkRegistryBackfilled(user, referrer);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Shared core for re-topup and automatic reinvestment: validate, append a new independent
    ///      investment stream, update the user's package summary, pull funds from `user` to the
    ///      Treasury, and run the post-investment lifecycle. Returns the new package id.
    function _investAgain(address user, uint256 amount) private returns (uint256 packageId) {
        _validatePackage(amount);
        _recordDailyDeposit(user, amount);

        totalPackages += 1;
        packageId = totalPackages;

        User storage u = _users[user];
        u.packageAmount = amount;
        u.totalInvested += amount;
        u.packageStart = block.timestamp;
        u.packageId = packageId;
        u.active = true;

        uint256 index = _pushInvestment(user, amount, packageId);

        _collectDeposit(user, amount);

        emit InvestmentCreated(user, index, packageId, amount, block.timestamp);
        emit InvestmentActivated(user, index, packageId);

        _runLifecycle(user, amount);
    }

    /// @dev Appends a new active investment record for `user` and bumps the global counter. The ROI
    ///      economics are frozen at creation (see {_frozenEconomics}) so later ProtocolConfig changes
    ///      never retroactively alter this stream.
    /// @return index The zero-based index of the newly created record.
    function _pushInvestment(address user, uint256 amount, uint256 packageId) private returns (uint256 index) {
        Investment[] storage list = _investments[user];
        index = list.length;
        (uint256 roiPct, uint256 roiDur, uint256 maxRoi, uint256 price) = _frozenEconomics();
        list.push(
            Investment({
                amount: amount,
                startTime: block.timestamp,
                roiEarned: 0,
                packageId: packageId,
                status: InvestmentStatus.Active,
                roiPercentage: roiPct,
                roiDurationDays: roiDur,
                maxRoiPercentage: maxRoi,
                oraclePrice: price
            })
        );
        totalInvestments += 1;
    }

    /// @dev Snapshots the ROI economics to freeze into a new (or renewed-on-upgrade) investment from
    ///      the wired ProtocolConfig: the daily ROI rate, the accrual duration, the lifetime ROI cap
    ///      and the ARX/USDT oracle price. Returns zeros when no ProtocolConfig is wired, in which
    ///      case the ProtocolEngine falls back to the live config (backward-compatible).
    function _frozenEconomics()
        private
        view
        returns (uint256 roiPercentage, uint256 roiDurationDays_, uint256 maxRoiPercentage, uint256 oraclePrice)
    {
        address pc = protocolConfig;
        if (pc == address(0)) return (0, 0, 0, 0);
        IProtocolConfig config = IProtocolConfig(pc);
        roiPercentage = config.dailyROIPercentage();
        roiDurationDays_ = config.roiDurationDays();
        maxRoiPercentage = config.maximumROIPercentage();
        oraclePrice = config.arxPriceUSDT();
    }

    /// @dev Collects a deposit of `amount` from `payer`, splitting it at the source: the
    ///      treasury-allocation share (the company's 20% under the finalized business rule) goes
    ///      INSTANTLY to the configured {companyWallet}; the remainder goes to the Treasury
    ///      vault. With no company wallet or ProtocolConfig configured the entire deposit goes
    ///      to the Treasury (fail-safe, backward-compatible). The two legs always sum exactly to
    ///      `amount` — rounding dust stays with the vault, never the company.
    function _collectDeposit(address payer, uint256 amount) private {
        address pc = protocolConfig;
        uint256 companyShare;
        uint256 buybackShare;

        address wallet = companyWallet;
        if (wallet != address(0) && pc != address(0)) {
            companyShare = (amount * IProtocolConfig(pc).treasuryAllocationPercentage()) / 10_000;
        }

        address lm = liquidityManager;
        if (lm != address(0) && pc != address(0)) {
            buybackShare = (amount * IProtocolConfig(pc).buybackPercentage()) / 10_000;
        }

        if (companyShare != 0) {
            IERC20(usdt).safeTransferFrom(payer, wallet, companyShare);
            emit CompanyShareTransferred(payer, wallet, companyShare);
        }

        if (buybackShare != 0) {
            // Fund the LiquidityManager, then let it fold the share into the pool as one-sided
            // USDT (no ARX leaves the pool). A failed deepening must never revert a member's
            // deposit, so the manager reports rather than throws — and on failure the USDT it
            // still holds is swept back to the Treasury, where the share would have gone anyway.
            // Either way the deposit legs sum to `amount`.
            IERC20(usdt).safeTransferFrom(payer, lm, buybackShare);
            (bool executed,, uint256 liquidity) = ILiquidityManager(lm).executeBuyback(buybackShare);
            emit BuybackFunded(payer, buybackShare, executed, liquidity);
        }

        IERC20(usdt).safeTransferFrom(payer, treasury, amount - companyShare - buybackShare);
    }

    /// @dev Routes an investment event of `amount` for `user` through the wired lifecycle engine.
    ///      Skipped while the lifecycle engine is unwired, so the record and fund transfer still occur.
    function _runLifecycle(address user, uint256 amount) private {
        address engine = lifecycleEngine;
        if (engine != address(0)) {
            IInvestmentLifecycleEngine(engine).processInvestment(user, amount);
        }
    }

    /// @dev Reverts unless `amount` is at least the minimum, a whole multiple of the step, and at
    ///      most the maximum. All three bounds come from the wired ProtocolConfig
    ///      (`minimumInvestment` / `investmentStep` / `maximumInvestment`), so the owner can retune
    ///      the granularity — e.g. a $50 step, which makes $250 depositable — without an upgrade.
    ///      Each bound falls back to `packageUnit` (min/step) or "unbounded" (max) while unset, so
    ///      behaviour is unchanged until the config is wired and populated.
    ///
    ///      `maximumInvestment` is the absolute per-package ceiling; the operative day-to-day bound
    ///      is the rank-scaled daily limit enforced by {_recordDailyDeposit}.
    function _validatePackage(uint256 amount) private view {
        uint256 unit = packageUnit;
        uint256 minimum = unit;
        uint256 step = unit;

        address pc = protocolConfig;
        if (pc != address(0)) {
            IProtocolConfig config = IProtocolConfig(pc);
            uint256 configuredMinimum = config.minimumInvestment();
            uint256 configuredStep = config.investmentStep();
            if (configuredMinimum != 0) minimum = configuredMinimum;
            if (configuredStep != 0) step = configuredStep;

            uint256 max = config.maximumInvestment();
            if (max != 0 && amount > max) revert InvalidPackage();
        }

        if (amount < minimum || amount % step != 0) revert InvalidPackage();
    }

    /// @dev Accumulates `amount` into `user`'s deposits for the current UTC day and enforces the
    ///      rank-scaled daily deposit limit (spec v2.1: $1,000/day up to V7, scaling to
    ///      $25,000/day at V14). Skipped — backward-compatible — while the ProtocolConfig or its
    ///      limit table is unset; without a wired RankEngine every depositor uses the rank-0 limit.
    function _recordDailyDeposit(address user, uint256 amount) private {
        address pc = protocolConfig;
        if (pc == address(0)) return;
        IProtocolConfig config = IProtocolConfig(pc);
        if (config.rankDailyDepositLimitCount() == 0) return;

        address ranks = rankEngine;
        uint256 rank = ranks != address(0) ? IRankEngine(ranks).rankOf(user) : 0;
        uint256 limit = config.rankDailyDepositLimit(rank);
        if (limit == 0) return;

        // UTC-day bucketing; validator timestamp leeway is immaterial to a whole-day window.
        // forge-lint: disable-next-line(block-timestamp)
        uint256 day = block.timestamp / 1 days;
        uint256 newTotal = _dailyDeposited[user][day] + amount;
        if (newTotal > limit) revert DailyDepositLimitExceeded();
        _dailyDeposited[user][day] = newTotal;
    }

    /// @dev Reverts when investments are paused — at the module level ({ModuleIsPaused}) or, when a
    ///      ProtocolConfig is wired, protocol-wide ({ProtocolIsPaused}). No-op until the config is wired.
    function _requireNotPaused() private view {
        if (investmentsPaused) revert ModuleIsPaused();
        address pc = protocolConfig;
        if (pc != address(0) && IProtocolConfig(pc).protocolPaused()) revert ProtocolIsPaused();
    }

    /// @dev Enforces the configured reinvest bounds when a ProtocolConfig is wired (a zero bound is
    ///      treated as "unset"). No-op until the config is wired, so bounds are opt-in.
    function _validateReinvestBounds(uint256 amount) private view {
        address pc = protocolConfig;
        if (pc == address(0)) return;
        uint256 min = IProtocolConfig(pc).minimumReinvestAmount();
        uint256 max = IProtocolConfig(pc).maximumReinvestAmount();
        if (min != 0 && amount < min) revert ReinvestAmountOutOfBounds();
        if (max != 0 && amount > max) revert ReinvestAmountOutOfBounds();
    }

    /// @dev Reverts {UnauthorizedCaller} unless the caller is the owner or an authorized contract.
    function _requireAuthorized() private view {
        if (msg.sender != owner() && !authorizedContracts[msg.sender]) revert UnauthorizedCaller();
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
