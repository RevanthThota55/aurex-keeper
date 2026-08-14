// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ZeroAddress} from "../Errors/CommonErrors.sol";
import {InsufficientReserve, NotLifecycleEngine, NotLiquidityManager} from "../Errors/LiquidityReserveErrors.sol";
import {ILiquidityReserveEngine} from "../Interfaces/ILiquidityReserveEngine.sol";

/// @title LiquidityReserveEngine
/// @author Aurex Protocol
/// @notice The protocol's liquidity reserve accounting layer. It receives the liquidity allocation
///         produced by the {InvestmentLifecycleEngine} and maintains the accumulated reserve until
///         a future DEX integration consumes it.
/// @dev
/// ## Purpose
/// This engine is **pure accounting**. It only:
/// - receives liquidity allocations (from the authorized InvestmentLifecycleEngine),
/// - tracks the cumulative reserved liquidity,
/// - exposes the reserve status.
///
/// It performs **no** swaps, creates **no** LP, holds **no** tokens and interacts with **no** DEX.
/// The actual funds remain in the Treasury; this contract records how much liquidity has been
/// allocated so a later phase can consume it.
///
/// ## Future compatibility
/// The interface is deliberately DEX-agnostic (no PancakeSwap, router or LP-token concepts). A
/// future integration consumes the reserve — decrementing it and emitting {LiquidityReserveConsumed}
/// — without changing how allocations are recorded here.
///
/// ## Upgradeability
/// UUPS (ERC-1967). Deploy behind an `ERC1967Proxy`; only the owner may authorize an upgrade or
/// update the authorized lifecycle engine. No reentrancy guard is required — {recordLiquidityAllocation}
/// makes no external calls.
contract LiquidityReserveEngine is Initializable, OwnableUpgradeable, UUPSUpgradeable, ILiquidityReserveEngine {
    /// @notice The InvestmentLifecycleEngine authorized to record allocations. Owner-updatable.
    address public override lifecycleEngine;

    /// @notice The cumulative liquidity reserved so far, in USDT base units.
    uint256 public override totalReservedLiquidity;

    /// @notice The LiquidityManager authorized to consume the reserve. Owner-updatable.
    /// @dev Zero until wired; while zero, {consumeReservedLiquidity} always reverts (secure default).
    address public override liquidityManager;

    /// @notice Cumulative liquidity ever recorded into the reserve, in USDT base units. Appended in
    ///         the operational phase for diagnostics (`remaining == recorded - consumed`).
    uint256 public totalRecordedLiquidity;

    /// @notice Cumulative liquidity ever consumed from the reserve, in USDT base units.
    uint256 public totalConsumedLiquidity;

    /// @notice Number of consumption (liquidity execution) operations performed.
    uint256 public executionCount;

    /// @notice Reserved storage slots (6 used + 44 reserved = 50) for forward-compatible upgrades.
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[44] private __gap;

    /// @notice Restricts a function to the wired InvestmentLifecycleEngine.
    modifier onlyLifecycleEngine() {
        _requireLifecycleEngine();
        _;
    }

    /// @notice Restricts a function to the wired LiquidityManager.
    modifier onlyLiquidityManager() {
        _requireLiquidityManager();
        _;
    }

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the reserve engine and assigns ownership.
    /// @dev Callable exactly once, on the proxy. The lifecycle engine is wired afterwards by the
    ///      owner via {setLifecycleEngine} (avoids a circular deployment dependency).
    /// @param owner_ Protocol administrator; may update the lifecycle engine and authorize upgrades.
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
    }

    // -------------------------------------------------------------------------
    // Owner configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the authorized InvestmentLifecycleEngine.
    /// @param newLifecycleEngine The new lifecycle engine address (non-zero).
    function setLifecycleEngine(address newLifecycleEngine) external onlyOwner {
        if (newLifecycleEngine == address(0)) revert ZeroAddress();
        address previous = lifecycleEngine;
        lifecycleEngine = newLifecycleEngine;
        emit LifecycleEngineUpdated(previous, newLifecycleEngine);
    }

    /// @notice Updates the authorized LiquidityManager (reserve consumer).
    /// @param newLiquidityManager The new LiquidityManager address (non-zero).
    function setLiquidityManager(address newLiquidityManager) external onlyOwner {
        if (newLiquidityManager == address(0)) revert ZeroAddress();
        address previous = liquidityManager;
        liquidityManager = newLiquidityManager;
        emit LiquidityManagerUpdated(previous, newLiquidityManager);
    }

    // -------------------------------------------------------------------------
    // Reserve accounting
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityReserveEngine
    /// @dev Pure accounting: adds `amount` to the cumulative reserve and emits {LiquidityReserved}.
    ///      No funds move. Restricted to the wired InvestmentLifecycleEngine.
    function recordLiquidityAllocation(uint256 amount)
        external
        override
        onlyLifecycleEngine
        returns (uint256 totalReserved)
    {
        totalReserved = totalReservedLiquidity + amount;
        totalReservedLiquidity = totalReserved;
        totalRecordedLiquidity += amount;
        emit LiquidityReserved(amount, totalReserved);
    }

    /// @inheritdoc ILiquidityReserveEngine
    /// @dev Pure accounting: subtracts `amount` from the cumulative reserve and emits
    ///      {LiquidityReserveConsumed}. No funds move — the LiquidityManager moves the actual assets
    ///      from the Treasury. Restricted to the wired LiquidityManager; reverts {InsufficientReserve}
    ///      when `amount` exceeds the available reserve.
    function consumeReservedLiquidity(uint256 amount)
        external
        override
        onlyLiquidityManager
        returns (uint256 totalReserved)
    {
        uint256 current = totalReservedLiquidity;
        if (amount > current) revert InsufficientReserve();
        totalReserved = current - amount;
        totalReservedLiquidity = totalReserved;
        totalConsumedLiquidity += amount;
        executionCount += 1;
        emit LiquidityReserveConsumed(amount, totalReserved);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityReserveEngine
    function previewReserveAfter(uint256 amount) external view override returns (uint256) {
        return totalReservedLiquidity + amount;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Reverts {NotLifecycleEngine} unless the caller is the wired lifecycle engine. When the
    ///      lifecycle engine is unset (zero) this always reverts, so nothing can be recorded until
    ///      the owner wires it.
    function _requireLifecycleEngine() private view {
        if (msg.sender != lifecycleEngine) revert NotLifecycleEngine();
    }

    /// @dev Reverts {NotLiquidityManager} unless the caller is the wired LiquidityManager. When the
    ///      LiquidityManager is unset (zero) this always reverts, so nothing can be consumed until
    ///      the owner wires it.
    function _requireLiquidityManager() private view {
        if (msg.sender != liquidityManager) revert NotLiquidityManager();
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
