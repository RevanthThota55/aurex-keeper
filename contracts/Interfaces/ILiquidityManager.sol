// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILiquidityManager
/// @author Aurex Protocol
/// @notice Events and integration surface for the {LiquidityManager} — the protocol's DEX
///         integration adapter that converts reserved liquidity into real PancakeSwap V2
///         (Uniswap V2-compatible) liquidity.
/// @dev The adapter performs **no** allocation or business calculations. It consumes the reserve
///      recorded by the {LiquidityReserveEngine}, sizes the ARX side from the ProtocolConfig price,
///      moves assets from and returns LP tokens to the {Treasury}, and holds no funds of its own.
interface ILiquidityManager {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted at the start of a liquidity execution.
    /// @param executor The authorized caller.
    /// @param usdtAmount The USDT amount being deployed, in USDT base units.
    /// @param requiredArx The ARX amount sized from the configured price, in ARX base units.
    event LiquidityExecutionStarted(address indexed executor, uint256 usdtAmount, uint256 requiredArx);

    /// @notice Emitted when a liquidity execution completes.
    /// @param executor The authorized caller.
    /// @param arxUsed The ARX actually deposited into the pool, in ARX base units.
    /// @param usdtUsed The USDT actually deposited into the pool, in USDT base units.
    /// @param liquidity The LP tokens minted to the Treasury.
    /// @param pair The ARX/USDT pair the liquidity was added to.
    event LiquidityExecuted(
        address indexed executor, uint256 arxUsed, uint256 usdtUsed, uint256 liquidity, address indexed pair
    );

    /// @notice Emitted when the ARX/USDT liquidity pair is created or first cached (reused).
    /// @param pair The pair address.
    /// @param arx The ARX token address.
    /// @param usdt The USDT token address.
    event LiquidityPairCreated(address indexed pair, address indexed arx, address indexed usdt);

    /// @notice Emitted when liquidity execution is paused.
    event LiquidityExecutionPaused(address indexed account);

    /// @notice Emitted when liquidity execution is resumed.
    event LiquidityExecutionResumed(address indexed account);

    /// @notice Emitted when an address is authorized to execute liquidity.
    event ExecutorAuthorized(address indexed executor);

    /// @notice Emitted when an address's execution authorization is revoked.
    event ExecutorRemoved(address indexed executor);

    /// @notice Emitted when the owner updates the ProtocolConfig address.
    event ProtocolConfigUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the LiquidityReserveEngine address.
    event LiquidityReserveEngineUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the Treasury address.
    event TreasuryUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when a deposit's buyback share is folded into the pool as one-sided USDT.
    /// @param usdtAdded The USDT transferred into the pair, in USDT base units.
    /// @param arxReserve The pool's ARX reserve after the sync — unchanged by the deepening.
    /// @param usdtReserve The pool's USDT reserve after the sync.
    event PoolDeepened(uint256 usdtAdded, uint256 arxReserve, uint256 usdtReserve);

    /// @notice Emitted when the deepening could not run; the USDT is returned rather than the
    ///         deposit being reverted.
    event BuybackSkipped(uint256 usdtAmount, string reason);

    // -------------------------------------------------------------------------
    // Liquidity execution
    // -------------------------------------------------------------------------

    /// @notice Creates (or reuses and caches) the ARX/USDT pair via the configured factory.
    /// @return pairAddress The pair address.
    function createPair() external returns (address pairAddress);

    /// @notice Converts `usdtAmount` of reserved liquidity into a real DEX liquidity position.
    /// @dev Consumes the reserve, sizes the ARX side from the configured price, pulls both assets
    ///      from the Treasury, adds liquidity via the configured router (LP tokens minted to the
    ///      Treasury) and returns any residual to the Treasury. Performs no allocation calculations.
    /// @param usdtAmount The USDT amount to deploy, in USDT base units (`<=` reserved liquidity).
    /// @param amountArxMin The minimum ARX to deposit (slippage bound), in ARX base units.
    /// @param amountUsdtMin The minimum USDT to deposit (slippage bound), in USDT base units.
    /// @param deadline Unix timestamp after which the execution reverts.
    /// @return arxUsed The ARX actually deposited.
    /// @return usdtUsed The USDT actually deposited.
    /// @return liquidity The LP tokens minted to the Treasury.
    function executeLiquidity(uint256 usdtAmount, uint256 amountArxMin, uint256 amountUsdtMin, uint256 deadline)
        external
        returns (uint256 arxUsed, uint256 usdtUsed, uint256 liquidity);

    /// @notice Folds `usdtAmount` of deposit USDT into the ARX/USDT pool as a one-sided deepening.
    /// @dev The deposit-funded pool feed. Historically this BOUGHT ARX with the deposit share,
    ///      which pulled ARX out of the pool and into the Treasury float — a structural drain on
    ///      the pool's ARX side. It now transfers the USDT straight to the pair and calls
    ///      `sync()`: the pool only ever gets deeper, no ARX leaves it, and the spot price steps
    ///      up with each deposit. The donated value accrues to the LP holders — the Treasury,
    ///      which owns the protocol's LP tokens.
    ///      Called on the deposit path, so it never reverts on a DEX-side problem — it returns
    ///      `false` and sweeps the USDT to the Treasury instead. The caller must transfer
    ///      `usdtAmount` to the LiquidityManager before calling.
    /// @param usdtAmount The USDT to fold into the pool, already held by the LiquidityManager.
    /// @return executed True when the pool was deepened.
    /// @return arxBought Always zero — kept for ABI compatibility with the buyback-era signature.
    /// @return liquidity Always zero — a one-sided deepening mints no LP tokens.
    function executeBuyback(uint256 usdtAmount) external returns (bool executed, uint256 arxBought, uint256 liquidity);

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice The cached ARX/USDT pair address (zero until created).
    function pair() external view returns (address);

    /// @notice Whether liquidity execution is currently paused.
    function liquidityExecutionPaused() external view returns (bool);

    /// @notice Whether `account` is authorized to execute liquidity.
    function authorizedExecutors(address account) external view returns (bool);

    /// @notice The configured ProtocolConfig address.
    function protocolConfig() external view returns (address);

    /// @notice The configured LiquidityReserveEngine address.
    function liquidityReserveEngine() external view returns (address);

    /// @notice The configured Treasury address.
    function treasury() external view returns (address);

    /// @notice The ARX token address.
    function arx() external view returns (address);

    /// @notice The USDT token address.
    function usdt() external view returns (address);
}
