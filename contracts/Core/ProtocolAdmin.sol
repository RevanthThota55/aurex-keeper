// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ZeroAddress, ZeroAmount} from "../Errors/CommonErrors.sol";
import {ProtectedToken, RecoveryFailed} from "../Errors/ProtocolAdminErrors.sol";
import {IInvestmentManager} from "../Interfaces/IInvestmentManager.sol";
import {ILiquidityManager} from "../Interfaces/ILiquidityManager.sol";
import {ILiquidityReserveEngine} from "../Interfaces/ILiquidityReserveEngine.sol";
import {IProtocolConfig} from "../Interfaces/IProtocolConfig.sol";
import {IProtocolEngine} from "../Interfaces/IProtocolEngine.sol";
import {IProtocolScheduler} from "../Interfaces/IProtocolScheduler.sol";
import {IRewardManager} from "../Interfaces/IRewardManager.sol";
import {ITreasury} from "../Interfaces/ITreasury.sol";

/// @title ProtocolAdmin
/// @author Aurex Protocol
/// @notice The protocol's operational hub: read-only monitoring/diagnostics, health checks,
///         configuration snapshots, upgrade verification, and safe recovery of stray tokens.
/// @dev
/// ## Role
/// This is a **peripheral operational (infrastructure) contract**, not a core business contract. It
/// holds **no** protocol funds, performs **no** reward/ROI/allocation calculation and changes **no**
/// business state. It only *reads* the other modules to aggregate status, and recovers non-protocol
/// tokens accidentally sent to itself. Pausing is enforced by the modules themselves (each reads
/// `ProtocolConfig.protocolPaused` and/or its own module flag); this contract simply aggregates and
/// reports.
///
/// ## Diagnostics are view/pure
/// Every dashboard/diagnostic/health/config function is `view` (or `pure`), so monitoring is free of
/// side effects. Thin non-view wrappers ({runHealthCheck}, {snapshotConfiguration}, {verifyUpgrade})
/// exist only to emit an on-chain audit event; they write no storage.
///
/// ## Recovery safety
/// {recoverERC20} / {recoverBNB} move only tokens/BNB held by **this** contract and hard-revert on the
/// protocol tokens (USDT, ARX, LP pair). The Treasury, user funds, liquidity reserve and LP tokens are
/// never reachable from here.
///
/// ## Upgradeability
/// UUPS (ERC-1967). Deploy behind an `ERC1967Proxy`; only the owner may authorize an upgrade. The
/// reentrancy guard is the storage-namespaced OpenZeppelin v5 `ReentrancyGuard` (no initializer).
contract ProtocolAdmin is Initializable, OwnableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Human-readable contract name (storage-verification helper).
    string private constant CONTRACT_NAME = "ProtocolAdmin";

    /// @notice Implementation version (storage-verification helper).
    uint256 private constant VERSION = 1;

    /// @notice Storage layout revision (storage-verification helper).
    uint256 private constant STORAGE_REVISION = 1;

    // --- Module references (set at initialization) ----------------------------

    address public protocolConfig;
    address public treasury;
    address public investmentManager;
    address public rewardManager;
    address public protocolEngine;
    address public protocolScheduler;
    address public liquidityReserveEngine;
    address public liquidityManager;

    /// @notice Reserved storage slots (8 used + 42 reserved = 50) for forward-compatible upgrades.
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[42] private __gap;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Aggregated operational status of the protocol.
    struct ProtocolStatus {
        bool protocolPaused;
        uint256 version;
        uint256 totalUsers;
        uint256 totalInvestments;
        uint256 totalRewardsRecorded;
        uint256 totalRewardsClaimed;
        uint256 totalLiquidityReserved;
        uint256 totalLiquidityRecorded;
        uint256 totalLiquidityExecuted;
        uint256 treasuryUsdt;
        uint256 treasuryArx;
        uint256 treasuryBnb;
        uint256 lpBalance;
        address router;
        address factory;
        uint256 arxPrice;
        bool schedulerPaused;
        uint256 currentDay;
        uint256 currentWeek;
    }

    /// @notice Read-only treasury balances and reward/liquidity totals.
    struct TreasuryDiagnostics {
        uint256 usdtBalance;
        uint256 arxBalance;
        uint256 bnbBalance;
        uint256 lpBalance;
        uint256 reservedLiquidity;
        uint256 allocatedLiquidity;
        uint256 rewardsClaimed;
        uint256 rewardsPending;
    }

    /// @notice Read-only reserve accounting.
    struct ReserveDiagnostics {
        uint256 currentReserve;
        uint256 totalReserve;
        uint256 consumedReserve;
        uint256 remainingReserve;
        uint256 executionCount;
    }

    /// @notice Snapshot of every configurable protocol parameter.
    struct Configuration {
        uint256 dailyROIPercentage;
        uint256 maximumROIPercentage;
        uint256 roiDurationDays;
        uint256 minimumInvestment;
        uint256 investmentStep;
        uint256 maximumInvestment;
        uint256 directReferralPercentage;
        uint256 maximumReferralDepth;
        bool weeklyRewardEnabled;
        uint256 weeklyRewardPercentage;
        bool infinityRewardEnabled;
        uint256 infinityRewardPercentage;
        uint256 liquidityAllocationPercentage;
        uint256 treasuryAllocationPercentage;
        uint256 rewardAllocationPercentage;
        bool autoReinvestEnabled;
        uint256 minimumReinvestAmount;
        uint256 maximumReinvestAmount;
        uint256 reinvestPercentage;
        uint256 reinvestCooldown;
        address dexRouter;
        address dexFactory;
        uint256 arxPriceUSDT;
        uint256 maxSlippageBps;
        bool protocolPaused;
    }

    /// @notice Detailed protocol health report.
    struct HealthReport {
        bool treasuryFunded;
        bool treasuryConfigured;
        bool reserveConsistent;
        bool rewardManagerReachable;
        bool investmentManagerReachable;
        bool schedulerActive;
        bool routerConfigured;
        bool factoryConfigured;
        bool priceConfigured;
        bool ownerConfigured;
        bool notPaused;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a configuration snapshot is logged on-chain.
    event ConfigurationSnapshot(address indexed by, uint256 arxPrice, bool protocolPaused);

    /// @notice Emitted when a health check is logged on-chain.
    event HealthChecked(address indexed by, bool healthy);

    /// @notice Emitted when an upgrade verification is logged on-chain.
    event UpgradeVerified(address indexed by, bool success);

    /// @notice Emitted when stray tokens/BNB are recovered.
    event RecoveryExecuted(address indexed token, address indexed to, uint256 amount);

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the operational hub and wires every module it monitors.
    /// @dev Callable exactly once, on the proxy. All addresses must be non-zero.
    function initialize(
        address owner_,
        address protocolConfig_,
        address treasury_,
        address investmentManager_,
        address rewardManager_,
        address protocolEngine_,
        address protocolScheduler_,
        address liquidityReserveEngine_,
        address liquidityManager_
    ) external initializer {
        if (
            owner_ == address(0) || protocolConfig_ == address(0) || treasury_ == address(0)
                || investmentManager_ == address(0) || rewardManager_ == address(0) || protocolEngine_ == address(0)
                || protocolScheduler_ == address(0) || liquidityReserveEngine_ == address(0)
                || liquidityManager_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __Ownable_init(owner_);

        protocolConfig = protocolConfig_;
        treasury = treasury_;
        investmentManager = investmentManager_;
        rewardManager = rewardManager_;
        protocolEngine = protocolEngine_;
        protocolScheduler = protocolScheduler_;
        liquidityReserveEngine = liquidityReserveEngine_;
        liquidityManager = liquidityManager_;
    }

    /// @notice Accepts native BNB so accidentally-sent BNB can be recovered.
    receive() external payable {}

    // -------------------------------------------------------------------------
    // Storage-verification helpers
    // -------------------------------------------------------------------------

    /// @notice The implementation version.
    function version() external pure returns (uint256) {
        return VERSION;
    }

    /// @notice The storage layout revision.
    function storageRevision() external pure returns (uint256) {
        return STORAGE_REVISION;
    }

    /// @notice The human-readable contract name.
    function contractName() external pure returns (string memory) {
        return CONTRACT_NAME;
    }

    // -------------------------------------------------------------------------
    // Operational dashboard (view)
    // -------------------------------------------------------------------------

    /// @notice Returns the aggregated operational status of the protocol.
    function getProtocolStatus() external view returns (ProtocolStatus memory s) {
        IProtocolConfig config = IProtocolConfig(protocolConfig);
        ITreasury t = ITreasury(treasury);
        ILiquidityReserveEngine reserve = ILiquidityReserveEngine(liquidityReserveEngine);
        IProtocolScheduler scheduler = IProtocolScheduler(protocolScheduler);
        address lp = ILiquidityManager(liquidityManager).pair();

        s.protocolPaused = config.protocolPaused();
        s.version = VERSION;
        s.totalUsers = IInvestmentManager(investmentManager).totalUsers();
        s.totalInvestments = IInvestmentManager(investmentManager).totalInvestments();
        s.totalRewardsRecorded = IRewardManager(rewardManager).totalRewardsRecorded();
        s.totalRewardsClaimed = IRewardManager(rewardManager).totalRewardsClaimed();
        s.totalLiquidityReserved = reserve.totalReservedLiquidity();
        s.totalLiquidityRecorded = reserve.totalRecordedLiquidity();
        s.totalLiquidityExecuted = reserve.totalConsumedLiquidity();
        s.treasuryUsdt = t.balanceOfToken(t.usdt());
        s.treasuryArx = t.balanceOfToken(t.arx());
        s.treasuryBnb = t.balanceBNB();
        s.lpBalance = lp == address(0) ? 0 : t.balanceOfToken(lp);
        s.router = config.dexRouter();
        s.factory = config.dexFactory();
        s.arxPrice = config.arxPriceUSDT();
        s.schedulerPaused = scheduler.schedulerPaused();
        s.currentDay = scheduler.currentDay();
        s.currentWeek = scheduler.currentWeek();
    }

    /// @notice Returns read-only treasury balances plus reward/liquidity totals.
    function getTreasuryDiagnostics() external view returns (TreasuryDiagnostics memory d) {
        ITreasury t = ITreasury(treasury);
        ILiquidityReserveEngine reserve = ILiquidityReserveEngine(liquidityReserveEngine);
        IRewardManager rm = IRewardManager(rewardManager);
        address lp = ILiquidityManager(liquidityManager).pair();

        d.usdtBalance = t.balanceOfToken(t.usdt());
        d.arxBalance = t.balanceOfToken(t.arx());
        d.bnbBalance = t.balanceBNB();
        d.lpBalance = lp == address(0) ? 0 : t.balanceOfToken(lp);
        d.reservedLiquidity = reserve.totalReservedLiquidity();
        d.allocatedLiquidity = reserve.totalRecordedLiquidity();
        d.rewardsClaimed = rm.totalRewardsClaimed();
        d.rewardsPending = rm.totalRewardsRecorded() - rm.totalRewardsClaimed();
    }

    /// @notice Returns read-only reserve accounting.
    function getReserveDiagnostics() external view returns (ReserveDiagnostics memory d) {
        ILiquidityReserveEngine reserve = ILiquidityReserveEngine(liquidityReserveEngine);
        d.currentReserve = reserve.totalReservedLiquidity();
        d.totalReserve = reserve.totalRecordedLiquidity();
        d.consumedReserve = reserve.totalConsumedLiquidity();
        d.remainingReserve = reserve.totalReservedLiquidity();
        d.executionCount = reserve.executionCount();
    }

    /// @notice Returns a snapshot of every configurable protocol parameter.
    function getConfiguration() external view returns (Configuration memory c) {
        IProtocolConfig config = IProtocolConfig(protocolConfig);
        c.dailyROIPercentage = config.dailyROIPercentage();
        c.maximumROIPercentage = config.maximumROIPercentage();
        c.roiDurationDays = config.roiDurationDays();
        c.minimumInvestment = config.minimumInvestment();
        c.investmentStep = config.investmentStep();
        c.maximumInvestment = config.maximumInvestment();
        c.directReferralPercentage = config.directReferralPercentage();
        c.maximumReferralDepth = config.maximumReferralDepth();
        c.weeklyRewardEnabled = config.weeklyRewardEnabled();
        c.weeklyRewardPercentage = config.weeklyRewardPercentage();
        c.infinityRewardEnabled = config.infinityRewardEnabled();
        c.infinityRewardPercentage = config.infinityRewardPercentage();
        c.liquidityAllocationPercentage = config.liquidityAllocationPercentage();
        c.treasuryAllocationPercentage = config.treasuryAllocationPercentage();
        c.rewardAllocationPercentage = config.rewardAllocationPercentage();
        c.autoReinvestEnabled = config.autoReinvestEnabled();
        c.minimumReinvestAmount = config.minimumReinvestAmount();
        c.maximumReinvestAmount = config.maximumReinvestAmount();
        c.reinvestPercentage = config.reinvestPercentage();
        c.reinvestCooldown = config.reinvestCooldown();
        c.dexRouter = config.dexRouter();
        c.dexFactory = config.dexFactory();
        c.arxPriceUSDT = config.arxPriceUSDT();
        c.maxSlippageBps = config.maxSlippageBps();
        c.protocolPaused = config.protocolPaused();
    }

    // -------------------------------------------------------------------------
    // Health & upgrade verification (view)
    // -------------------------------------------------------------------------

    /// @notice Returns whether the protocol is healthy plus a detailed per-check report.
    function healthCheck() public view returns (bool healthy, HealthReport memory report) {
        IProtocolConfig config = IProtocolConfig(protocolConfig);
        ITreasury t = ITreasury(treasury);
        ILiquidityReserveEngine reserve = ILiquidityReserveEngine(liquidityReserveEngine);

        report.treasuryConfigured = t.usdt() != address(0) && t.arx() != address(0);
        report.treasuryFunded = report.treasuryConfigured && t.balanceOfToken(t.usdt()) != 0;
        report.reserveConsistent =
            reserve.totalReservedLiquidity() == reserve.totalRecordedLiquidity() - reserve.totalConsumedLiquidity();
        report.rewardManagerReachable = IRewardManager(rewardManager).investmentManager() != address(0);
        report.investmentManagerReachable = IInvestmentManager(investmentManager).totalUsers() != 0;
        report.schedulerActive = !IProtocolScheduler(protocolScheduler).schedulerPaused();
        report.routerConfigured = config.dexRouter() != address(0);
        report.factoryConfigured = config.dexFactory() != address(0);
        report.priceConfigured = config.arxPriceUSDT() != 0;
        report.ownerConfigured = owner() != address(0);
        report.notPaused = !config.protocolPaused();

        healthy = report.treasuryConfigured && report.reserveConsistent && report.rewardManagerReachable
            && report.investmentManagerReachable && report.schedulerActive && report.routerConfigured
            && report.factoryConfigured && report.priceConfigured && report.ownerConfigured && report.notPaused;
    }

    /// @notice Verifies that storage and every critical address survived an upgrade.
    /// @return ok Whether all critical addresses and configuration are intact.
    function postUpgradeCheck() public view returns (bool ok) {
        ITreasury t = ITreasury(treasury);
        IProtocolConfig config = IProtocolConfig(protocolConfig);
        ok = owner() != address(0) && protocolConfig != address(0) && treasury != address(0)
            && investmentManager != address(0) && rewardManager != address(0) && protocolEngine != address(0)
            && protocolScheduler != address(0) && liquidityReserveEngine != address(0) && liquidityManager != address(0)
            && t.usdt() != address(0) && t.arx() != address(0) && config.dexRouter() != address(0)
            && config.dexFactory() != address(0) && config.arxPriceUSDT() != 0;
    }

    // -------------------------------------------------------------------------
    // On-chain audit logging (emit only; no storage writes)
    // -------------------------------------------------------------------------

    /// @notice Logs a configuration snapshot on-chain for audit trails.
    function snapshotConfiguration() external {
        IProtocolConfig config = IProtocolConfig(protocolConfig);
        emit ConfigurationSnapshot(msg.sender, config.arxPriceUSDT(), config.protocolPaused());
    }

    /// @notice Runs and logs a health check on-chain.
    /// @return healthy Whether the protocol is healthy.
    function runHealthCheck() external returns (bool healthy) {
        (healthy,) = healthCheck();
        emit HealthChecked(msg.sender, healthy);
    }

    /// @notice Runs and logs an upgrade verification on-chain.
    /// @return ok Whether the upgrade verification passed.
    function verifyUpgrade() external returns (bool ok) {
        ok = postUpgradeCheck();
        emit UpgradeVerified(msg.sender, ok);
    }

    // -------------------------------------------------------------------------
    // Administrative recovery (owner only; excludes protocol assets)
    // -------------------------------------------------------------------------

    /// @notice Recovers stray ERC-20 tokens sent to this contract.
    /// @dev Reverts {ProtectedToken} for USDT, ARX or the LP pair, so protocol assets and user funds
    ///      (which live in the Treasury / pair, never here) can never be recovered.
    /// @param token The ERC-20 token to recover (non-zero, not a protocol token).
    /// @param to The recipient (non-zero).
    /// @param amount The amount to recover (non-zero).
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _requireRecoverable(token);
        IERC20(token).safeTransfer(to, amount);
        emit RecoveryExecuted(token, to, amount);
    }

    /// @notice Recovers stray native BNB sent to this contract.
    /// @param to The recipient (non-zero).
    /// @param amount The amount to recover (non-zero).
    function recoverBNB(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert RecoveryFailed();
        emit RecoveryExecuted(address(0), to, amount);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Reverts {ProtectedToken} when `token` is a protocol asset (USDT, ARX or the LP pair).
    function _requireRecoverable(address token) private view {
        ITreasury t = ITreasury(treasury);
        if (token == t.usdt() || token == t.arx()) revert ProtectedToken();
        address lp = ILiquidityManager(liquidityManager).pair();
        if (lp != address(0) && token == lp) revert ProtectedToken();
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
