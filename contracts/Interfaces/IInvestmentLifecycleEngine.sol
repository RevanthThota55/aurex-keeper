// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IInvestmentLifecycleEngine
/// @author Aurex Protocol
/// @notice Events and integration surface for the {InvestmentLifecycleEngine} — the protocol
///         orchestrator that runs the post-investment pipeline.
/// @dev The engine coordinates the protocol modules (calculation in the ProtocolEngine,
///      accounting in the RewardManager, custody in the Treasury) but performs no reward
///      calculation, holds no funds and keeps no accounting of its own.
interface IInvestmentLifecycleEngine {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when the post-investment pipeline completes for `investor`.
    /// @param investor The investor whose investment/upgrade was processed.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    /// @param timestamp The block timestamp at which processing completed.
    event InvestmentProcessed(address indexed investor, uint256 investmentAmount, uint256 timestamp);

    /// @notice Emitted with the liquidity share of `investor`'s investment (accounting only — no
    ///         funds move this phase).
    /// @param investor The investor whose investment was split.
    /// @param amount The liquidity allocation, in USDT base units.
    event LiquidityAllocated(address indexed investor, uint256 amount);

    /// @notice Emitted with the protocol share of `investor`'s investment (accounting only — no
    ///         funds move this phase).
    /// @param investor The investor whose investment was split.
    /// @param amount The protocol allocation (the remainder after the liquidity share), in USDT base units.
    event ProtocolAllocated(address indexed investor, uint256 amount);

    /// @notice Emitted when `investor` is marked eligible for the weekly reward.
    /// @dev Eligibility itself comes from the active package the InvestmentManager created; this
    ///      signals the lifecycle stage for off-chain coordination.
    event WeeklyEligibilityMarked(address indexed investor);

    /// @notice Emitted when `investor`'s daily-ROI lifecycle is activated.
    /// @dev Accrual runs from the package start the InvestmentManager recorded; this signals the
    ///      lifecycle stage for off-chain coordination.
    event DailyROIActivated(address indexed investor);

    /// @notice Emitted when the owner updates the ProtocolEngine address.
    event ProtocolEngineUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the LiquidityReserveEngine address.
    event LiquidityReserveEngineUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the authorized InvestmentManager.
    event InvestmentManagerUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the RankEngine address.
    event RankEngineUpdated(address indexed previous, address indexed current);

    // -------------------------------------------------------------------------
    // Orchestration
    // -------------------------------------------------------------------------

    /// @notice Runs the post-investment pipeline for `investor`: split the investment into its
    ///         liquidity and protocol allocations, validate, record the deposit's network effects
    ///         with the RankEngine (volumes / qualification / ranks), trigger the direct referral,
    ///         level-income and infinity rewards (via the ProtocolEngine), signal weekly
    ///         eligibility and daily-ROI activation, and emit {InvestmentProcessed}.
    /// @param investor The registered user whose investment/upgrade is being processed.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    function processInvestment(address investor, uint256 investmentAmount) external;

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Returns the allocation split of `investmentAmount` into its liquidity and protocol
    ///         shares. Changes no state.
    /// @dev The liquidity share uses `liquidityAllocationPercentage` from the ProtocolConfig; the
    ///      protocol share is the remainder, so `liquidityAmount + protocolAmount` always equals
    ///      `investmentAmount`.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    /// @return liquidityAmount The liquidity allocation, in USDT base units.
    /// @return protocolAmount The protocol allocation, in USDT base units.
    function previewAllocation(uint256 investmentAmount)
        external
        view
        returns (uint256 liquidityAmount, uint256 protocolAmount);

    // -------------------------------------------------------------------------
    // Configuration views
    // -------------------------------------------------------------------------

    /// @notice The configured ProtocolEngine address (owner-updatable).
    function protocolEngine() external view returns (address);

    /// @notice The configured LiquidityReserveEngine that liquidity allocations are forwarded to
    ///         (owner-updatable; zero until wired, in which case forwarding is skipped).
    function liquidityReserveEngine() external view returns (address);

    /// @notice The InvestmentManager authorized to drive {processInvestment} (owner-updatable; zero
    ///         until wired, in which case the restriction is inactive).
    function investmentManager() external view returns (address);

    /// @notice The RankEngine that deposit network effects are recorded with (owner-updatable;
    ///         zero until wired, in which case the rank stage is skipped).
    function rankEngine() external view returns (address);
}
