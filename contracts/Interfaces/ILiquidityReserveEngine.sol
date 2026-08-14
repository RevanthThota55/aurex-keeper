// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILiquidityReserveEngine
/// @author Aurex Protocol
/// @notice Events and integration surface for the {LiquidityReserveEngine} — the protocol's
///         liquidity reserve accounting layer.
/// @dev The reserve engine receives the liquidity allocation produced by the
///      InvestmentLifecycleEngine and tracks the accumulated liquidity. It is **pure accounting**:
///      it performs no swaps, creates no LP and interacts with no DEX. A future DEX integration
///      consumes this reserve through the same clean interface.
interface ILiquidityReserveEngine {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a liquidity allocation is added to the reserve.
    /// @param amount The liquidity amount recorded, in USDT base units.
    /// @param totalReserved The new cumulative reserved liquidity, in USDT base units.
    event LiquidityReserved(uint256 amount, uint256 totalReserved);

    /// @notice Emitted when reserved liquidity is consumed. Reserved for a future DEX integration;
    ///         not emitted in this phase.
    /// @param amount The liquidity amount consumed, in USDT base units.
    /// @param totalReserved The remaining cumulative reserved liquidity, in USDT base units.
    event LiquidityReserveConsumed(uint256 amount, uint256 totalReserved);

    /// @notice Emitted when the owner updates the authorized InvestmentLifecycleEngine.
    event LifecycleEngineUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the authorized LiquidityManager (reserve consumer).
    event LiquidityManagerUpdated(address indexed previous, address indexed current);

    // -------------------------------------------------------------------------
    // Reserve accounting (lifecycle engine only)
    // -------------------------------------------------------------------------

    /// @notice Records a liquidity allocation of `amount` into the reserve.
    /// @dev Callable only by the wired InvestmentLifecycleEngine. Adds `amount` to the cumulative
    ///      reserve and emits {LiquidityReserved}. No funds move — this is pure accounting.
    /// @param amount The liquidity allocation to record, in USDT base units.
    /// @return totalReserved The new cumulative reserved liquidity, in USDT base units.
    function recordLiquidityAllocation(uint256 amount) external returns (uint256 totalReserved);

    /// @notice Consumes `amount` of reserved liquidity as it is deployed into a real DEX position.
    /// @dev Callable only by the wired LiquidityManager. Decrements the cumulative reserve and emits
    ///      {LiquidityReserveConsumed}. No funds move — this is pure accounting; the LiquidityManager
    ///      moves the actual assets from the Treasury. Reverts if `amount` exceeds the reserve.
    /// @param amount The reserved liquidity to consume, in USDT base units.
    /// @return totalReserved The new cumulative reserved liquidity, in USDT base units.
    function consumeReservedLiquidity(uint256 amount) external returns (uint256 totalReserved);

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice The cumulative liquidity reserved so far, in USDT base units.
    function totalReservedLiquidity() external view returns (uint256);

    /// @notice Returns what {totalReservedLiquidity} would be after recording `amount`. No state change.
    /// @param amount The prospective liquidity allocation, in USDT base units.
    /// @return The reserve total after `amount` would be recorded, in USDT base units.
    function previewReserveAfter(uint256 amount) external view returns (uint256);

    /// @notice The authorized InvestmentLifecycleEngine allowed to record allocations (owner-updatable).
    function lifecycleEngine() external view returns (address);

    /// @notice The authorized LiquidityManager allowed to consume the reserve (owner-updatable).
    function liquidityManager() external view returns (address);

    /// @notice Cumulative liquidity ever recorded into the reserve, in USDT base units.
    function totalRecordedLiquidity() external view returns (uint256);

    /// @notice Cumulative liquidity ever consumed from the reserve, in USDT base units.
    function totalConsumedLiquidity() external view returns (uint256);

    /// @notice Number of consumption (liquidity execution) operations performed.
    function executionCount() external view returns (uint256);
}
