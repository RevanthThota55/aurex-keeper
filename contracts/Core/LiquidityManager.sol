// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ProtocolIsPaused, ZeroAddress, ZeroAmount} from "../Errors/CommonErrors.sol";
import {
    DeadlineExpired,
    ExcessiveSlippage,
    FactoryNotConfigured,
    InsufficientReserveBalance,
    LiquidityExecutionIsPaused,
    PriceNotConfigured,
    RouterNotConfigured,
    UnauthorizedExecutor
} from "../Errors/LiquidityManagerErrors.sol";
import {IDexFactory} from "../Interfaces/IDexFactory.sol";
import {IDexPair} from "../Interfaces/IDexPair.sol";
import {IDexRouter} from "../Interfaces/IDexRouter.sol";
import {ILiquidityManager} from "../Interfaces/ILiquidityManager.sol";
import {ILiquidityReserveEngine} from "../Interfaces/ILiquidityReserveEngine.sol";
import {IProtocolConfig} from "../Interfaces/IProtocolConfig.sol";
import {ITreasury} from "../Interfaces/ITreasury.sol";

/// @title LiquidityManager
/// @author Aurex Protocol
/// @notice The protocol's DEX integration adapter: it converts accumulated **reserved liquidity**
///         into real PancakeSwap V2 (Uniswap V2-compatible) liquidity.
/// @dev
/// ## Role
/// This is a **peripheral execution adapter**, not one of the frozen core business contracts and
/// not a place for business logic. It performs **no** allocation or reward calculation. The
/// {InvestmentLifecycleEngine} already allocates and the {LiquidityReserveEngine} already records the
/// reserve (the single source of truth); this adapter only **consumes** that reserve and executes the
/// swap-free `addLiquidity` on a configurable router.
///
/// ## Fund flow (Treasury stays sole custodian)
/// The adapter holds **no** funds across calls. Within a single {executeLiquidity} it pulls the exact
/// ARX and USDT from the Treasury, approves the router, calls `addLiquidity` with the **Treasury** as
/// the LP-token recipient, returns any residual to the Treasury and resets the router allowance — so
/// its persistent balance is always zero and the Treasury owns every asset and all LP tokens.
///
/// ## Pricing (reused, never recalculated)
/// The ARX side is sized from the ProtocolConfig price: `requiredArx = usdtAmount * 1e18 /
/// arxPriceUSDT`. No pricing formula is duplicated here.
///
/// ## Router abstraction
/// The router and factory are addresses read from the ProtocolConfig and used through the
/// DEX-agnostic {IDexRouter} / {IDexFactory} interfaces, so switching to another Uniswap
/// V2-compatible DEX (ApeSwap, Biswap, …) needs only a configuration change.
///
/// ## Security
/// `nonReentrant` on the fund-moving path; execution is gated to the owner or authorized executors
/// and can be paused independently of protocol investments; slippage (min amounts vs. the configured
/// maximum), the deadline, reserve sufficiency and Treasury balance are all enforced.
///
/// ## Upgradeability
/// UUPS (ERC-1967). Deploy behind an `ERC1967Proxy`; only the owner may authorize an upgrade. The
/// reentrancy guard is the storage-namespaced OpenZeppelin v5 `ReentrancyGuard` (no initializer).
contract LiquidityManager is Initializable, OwnableUpgradeable, ReentrancyGuard, UUPSUpgradeable, ILiquidityManager {
    using SafeERC20 for IERC20;

    /// @notice Basis-point denominator: 10,000 basis points == 100%.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice One whole ARX in base units (ARX is an 18-decimal token). Used to size the ARX side.
    uint256 private constant ARX_ONE = 1e18;

    /// @notice The ProtocolConfig read for the router, factory, ARX price and max slippage. Owner-updatable.
    address public override protocolConfig;

    /// @notice The LiquidityReserveEngine whose reserve this adapter consumes. Owner-updatable.
    address public override liquidityReserveEngine;

    /// @notice The Treasury that provides assets and owns the LP tokens. Owner-updatable.
    address public override treasury;

    /// @notice The ARX token address. Fixed after initialization.
    address public override arx;

    /// @notice The USDT token address. Fixed after initialization.
    address public override usdt;

    /// @notice The cached ARX/USDT pair address (zero until created).
    address public override pair;

    /// @notice Whether liquidity execution is currently paused (independent of protocol investments).
    bool public override liquidityExecutionPaused;

    /// @notice Whether an address is authorized to execute liquidity.
    mapping(address account => bool authorized) public override authorizedExecutors;

    /// @notice Reserved storage slots (8 used + 42 reserved = 50) for forward-compatible upgrades.
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[42] private __gap;

    /// @notice Restricts a function to the owner or an authorized executor.
    modifier onlyExecutor() {
        _requireExecutor();
        _;
    }

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the adapter and wires the protocol addresses.
    /// @dev Callable exactly once, on the proxy. All addresses must be non-zero.
    /// @param owner_ Protocol administrator.
    /// @param protocolConfig_ ProtocolConfig read for router/factory/price/slippage.
    /// @param liquidityReserveEngine_ LiquidityReserveEngine whose reserve is consumed.
    /// @param treasury_ Treasury that provides assets and owns the LP tokens.
    /// @param arx_ ARX token address.
    /// @param usdt_ USDT token address.
    function initialize(
        address owner_,
        address protocolConfig_,
        address liquidityReserveEngine_,
        address treasury_,
        address arx_,
        address usdt_
    ) external initializer {
        if (
            owner_ == address(0) || protocolConfig_ == address(0) || liquidityReserveEngine_ == address(0)
                || treasury_ == address(0) || arx_ == address(0) || usdt_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __Ownable_init(owner_);

        protocolConfig = protocolConfig_;
        liquidityReserveEngine = liquidityReserveEngine_;
        treasury = treasury_;
        arx = arx_;
        usdt = usdt_;
    }

    // -------------------------------------------------------------------------
    // Owner configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the ProtocolConfig address.
    /// @param newProtocolConfig The new ProtocolConfig address (non-zero).
    function setProtocolConfig(address newProtocolConfig) external onlyOwner {
        if (newProtocolConfig == address(0)) revert ZeroAddress();
        address previous = protocolConfig;
        protocolConfig = newProtocolConfig;
        emit ProtocolConfigUpdated(previous, newProtocolConfig);
    }

    /// @notice Updates the LiquidityReserveEngine address.
    /// @param newReserveEngine The new LiquidityReserveEngine address (non-zero).
    function setLiquidityReserveEngine(address newReserveEngine) external onlyOwner {
        if (newReserveEngine == address(0)) revert ZeroAddress();
        address previous = liquidityReserveEngine;
        liquidityReserveEngine = newReserveEngine;
        emit LiquidityReserveEngineUpdated(previous, newReserveEngine);
    }

    /// @notice Updates the Treasury address.
    /// @param newTreasury The new Treasury address (non-zero).
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    /// @notice Grants `account` authorization to execute liquidity.
    /// @param account The address to authorize (non-zero).
    function authorizeExecutor(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedExecutors[account] = true;
        emit ExecutorAuthorized(account);
    }

    /// @notice Revokes `account`'s authorization to execute liquidity.
    /// @param account The address to de-authorize (non-zero).
    function removeExecutor(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedExecutors[account] = false;
        emit ExecutorRemoved(account);
    }

    // -------------------------------------------------------------------------
    // Emergency controls (liquidity execution only)
    // -------------------------------------------------------------------------

    /// @notice Pauses liquidity execution. Protocol investments are unaffected.
    function pauseLiquidityExecution() external onlyOwner {
        liquidityExecutionPaused = true;
        emit LiquidityExecutionPaused(msg.sender);
    }

    /// @notice Resumes liquidity execution.
    function resumeLiquidityExecution() external onlyOwner {
        liquidityExecutionPaused = false;
        emit LiquidityExecutionResumed(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Pair
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityManager
    /// @dev Reuses an existing on-chain pair when the factory already has one, otherwise creates it,
    ///      then caches and returns it. Emits {LiquidityPairCreated} on the first cache. Restricted to
    ///      the owner. `nonReentrant` as defense-in-depth around the external factory call.
    function createPair() external override onlyOwner nonReentrant returns (address) {
        return _ensurePair();
    }

    // -------------------------------------------------------------------------
    // Liquidity execution
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityManager
    /// @dev No allocation or business calculation happens here — the reserve (source of truth) and
    ///      the ARX price are consumed as given. Flow:
    ///      1. Guard: not paused, authorized executor, non-zero amount, live deadline, router and
    ///         price configured, and the reserve covers `usdtAmount`.
    ///      2. Size the ARX side from the ProtocolConfig price and enforce the slippage bounds
    ///         against the configured maximum.
    ///      3. Ensure the pair exists, pull the exact ARX and USDT from the Treasury and approve the
    ///         router.
    ///      4. `addLiquidity` with the Treasury as the LP recipient.
    ///      5. Consume the actual USDT deployed from the reserve, return any residual to the Treasury
    ///         and reset the router allowance.
    function executeLiquidity(uint256 usdtAmount, uint256 amountArxMin, uint256 amountUsdtMin, uint256 deadline)
        external
        override
        nonReentrant
        onlyExecutor
        returns (uint256 arxUsed, uint256 usdtUsed, uint256 liquidity)
    {
        if (liquidityExecutionPaused) revert LiquidityExecutionIsPaused();
        if (IProtocolConfig(protocolConfig).protocolPaused()) revert ProtocolIsPaused();
        if (usdtAmount == 0) revert ZeroAmount();
        // forge-lint: disable-next-line(block-timestamp)
        if (deadline < block.timestamp) revert DeadlineExpired();

        (address router, uint256 requiredArx) = _prepare(usdtAmount, amountArxMin, amountUsdtMin);

        emit LiquidityExecutionStarted(msg.sender, usdtAmount, requiredArx);

        (arxUsed, usdtUsed, liquidity) =
            _provideLiquidity(router, requiredArx, usdtAmount, amountArxMin, amountUsdtMin, deadline);
    }

    /// @notice Folds `usdtAmount` of deposit USDT into the ARX/USDT pool as a one-sided deepening.
    /// @dev The deposit-funded pool feed. Historically this leg BOUGHT ARX with the deposit share
    ///      — a float leg swapping for the Treasury's reward float and an LP leg pairing half —
    ///      and every swap pulled ARX out of the pool. On a small pool that is a structural drain:
    ///      each joining member removed another slice of the ARX reserve. The owner's directive
    ///      (2026-08-08) replaced both legs with a donation: transfer the USDT straight to the
    ///      pair and `sync()` it into the reserves.
    ///
    ///      Properties of the one-sided deepening:
    ///
    ///      - **The pool's ARX side is never touched.** No swap happens, so no ARX leaves. Only
    ///        the USDT reserve grows — every deposit makes the pool deeper and steps the spot
    ///        price up, and the keeper then writes that price into the on-chain oracle.
    ///      - **No LP tokens are minted.** A donation raises the value of the existing LP supply
    ///        instead; the Treasury holds the protocol's LP tokens, so the value lands there.
    ///      - **No skim window.** The transfer and the `sync()` happen inside one transaction, so
    ///        a third party can never `skim()` the donation out.
    ///
    ///      It is called on the deposit path, so it must never revert a member's deposit: every
    ///      failure mode returns `false` rather than bubbling, and the USDT falls through to the
    ///      Treasury where it would have gone anyway. The deepening needs a live pool on the other
    ///      side — an uncreated pair has nowhere to send the USDT and an empty one would swallow
    ///      it without a price — so both states abort-and-sweep rather than donate.
    ///
    ///      The caller must have transferred `usdtAmount` to this contract before calling.
    /// @param usdtAmount The USDT to fold into the pool. Must already be held by this contract.
    /// @return executed True when the pool was deepened.
    /// @return arxBought Always zero — kept for ABI compatibility with the buyback-era signature.
    /// @return liquidity Always zero — a one-sided deepening mints no LP tokens.
    function executeBuyback(uint256 usdtAmount)
        external
        override
        nonReentrant
        onlyExecutor
        returns (bool executed, uint256 arxBought, uint256 liquidity)
    {
        if (usdtAmount == 0) return (false, 0, 0);

        // Every abort below sweeps before returning. The caller has already parted with the USDT, so
        // an early return that skipped the sweep would strand a member's deposit in this contract.
        if (liquidityExecutionPaused) return _abortBuyback(usdtAmount, "execution paused");
        if (IProtocolConfig(protocolConfig).protocolPaused()) return _abortBuyback(usdtAmount, "protocol paused");
        if (IERC20(usdt).balanceOf(address(this)) < usdtAmount) return _abortBuyback(usdtAmount, "not funded");

        address lpPair = _findPair();
        if (lpPair == address(0)) return _abortBuyback(usdtAmount, "pair not created");
        (uint256 arxReserve, uint256 usdtReserve) = _pairReserves(lpPair);
        if (arxReserve == 0 || usdtReserve == 0) return _abortBuyback(usdtAmount, "pool empty");

        // The donation joins the reserves within this same transaction — no skim window.
        IERC20(usdt).safeTransfer(lpPair, usdtAmount);
        IDexPair(lpPair).sync();

        (arxReserve, usdtReserve) = _pairReserves(lpPair);
        emit PoolDeepened(usdtAmount, arxReserve, usdtReserve);

        // Anything this contract still holds belongs to the Treasury.
        _sweepToTreasury();
        return (true, 0, 0);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Reports a skipped deepening and returns the funds to the Treasury. Factored out so
    ///      every abort path is guaranteed to sweep — the deposit then lands exactly where it
    ///      would have had the deepening been switched off, and nothing is left in this contract.
    function _abortBuyback(uint256 usdtAmount, string memory reason)
        private
        returns (bool executed, uint256 arxBought, uint256 liquidity)
    {
        emit BuybackSkipped(usdtAmount, reason);
        _sweepToTreasury();
        return (false, 0, 0);
    }

    /// @dev The cached pair, or a read-only factory lookup while the cache is cold. Never creates
    ///      a pair — that is {createPair}'s owner-gated job, and the deposit path must stay
    ///      read-only against the factory. Returns zero when neither source knows the pair.
    function _findPair() private view returns (address lpPair) {
        lpPair = pair;
        if (lpPair != address(0)) return lpPair;

        address factory = IProtocolConfig(protocolConfig).dexFactory();
        if (factory == address(0)) return address(0);
        return IDexFactory(factory).getPair(arx, usdt);
    }

    /// @dev Reserves ordered as (ARX, USDT) regardless of the pair's internal token sorting.
    function _pairReserves(address lpPair) private view returns (uint256 arxReserve, uint256 usdtReserve) {
        (uint112 reserve0, uint112 reserve1,) = IDexPair(lpPair).getReserves();
        (arxReserve, usdtReserve) = IDexPair(lpPair).token0() == arx
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
    }

    /// @dev Moves every ARX and USDT this contract holds to the Treasury, the protocol's sole
    ///      custodian between calls. This is the deposit path's fail-safe: when the deepening
    ///      aborts, the untouched USDT lands in the Treasury, exactly where it would have gone
    ///      had the deepening been disabled.
    function _sweepToTreasury() private {
        uint256 arxResidual = IERC20(arx).balanceOf(address(this));
        if (arxResidual != 0) IERC20(arx).safeTransfer(treasury, arxResidual);

        uint256 usdtResidual = IERC20(usdt).balanceOf(address(this));
        if (usdtResidual != 0) IERC20(usdt).safeTransfer(treasury, usdtResidual);
    }

    /// @dev Validates configuration, reserve sufficiency and slippage, and sizes the ARX side from
    ///      the configured price. Reads only — no state changes, no allocation calculation.
    /// @return router The configured DEX router.
    /// @return requiredArx The ARX amount to pair with `usdtAmount`, in ARX base units.
    function _prepare(uint256 usdtAmount, uint256 amountArxMin, uint256 amountUsdtMin)
        private
        view
        returns (address router, uint256 requiredArx)
    {
        IProtocolConfig config = IProtocolConfig(protocolConfig);
        router = config.dexRouter();
        if (router == address(0)) revert RouterNotConfigured();
        uint256 price = config.arxPriceUSDT();
        if (price == 0) revert PriceNotConfigured();

        if (usdtAmount > ILiquidityReserveEngine(liquidityReserveEngine).totalReservedLiquidity()) {
            revert InsufficientReserveBalance();
        }

        requiredArx = (usdtAmount * ARX_ONE) / price;
        if (requiredArx == 0) revert ZeroAmount();
        _requireWithinSlippage(requiredArx, usdtAmount, amountArxMin, amountUsdtMin, config.maxSlippageBps());
    }

    /// @dev Executes the liquidity add: ensure the pair, pull the exact assets from the Treasury,
    ///      approve the router, `addLiquidity` (LP to the Treasury), consume the actual USDT from the
    ///      reserve, return any residual to the Treasury and clear the allowances.
    function _provideLiquidity(
        address router,
        uint256 requiredArx,
        uint256 usdtAmount,
        uint256 amountArxMin,
        uint256 amountUsdtMin,
        uint256 deadline
    ) private returns (uint256 arxUsed, uint256 usdtUsed, uint256 liquidity) {
        address lpPair = _ensurePair();

        // Pull the exact assets from the Treasury (Treasury remains sole custodian between calls).
        ITreasury(treasury).transferToken(arx, address(this), requiredArx);
        ITreasury(treasury).transferToken(usdt, address(this), usdtAmount);

        (arxUsed, usdtUsed, liquidity) =
            _callAddLiquidity(router, requiredArx, usdtAmount, amountArxMin, amountUsdtMin, deadline);

        // Consume the actual USDT deployed from the reserve (accounting source of truth).
        ILiquidityReserveEngine(liquidityReserveEngine).consumeReservedLiquidity(usdtUsed);

        // Return any residual to the Treasury and clear the allowances (adapter holds no funds).
        _sweep(arx, requiredArx - arxUsed);
        _sweep(usdt, usdtAmount - usdtUsed);
        IERC20(arx).forceApprove(router, 0);
        IERC20(usdt).forceApprove(router, 0);

        emit LiquidityExecuted(msg.sender, arxUsed, usdtUsed, liquidity, lpPair);
    }

    /// @dev Approves the router for the exact desired amounts and performs the `addLiquidity` call,
    ///      minting the LP tokens directly to the Treasury. Isolated to bound stack usage.
    function _callAddLiquidity(
        address router,
        uint256 requiredArx,
        uint256 usdtAmount,
        uint256 amountArxMin,
        uint256 amountUsdtMin,
        uint256 deadline
    ) private returns (uint256 arxUsed, uint256 usdtUsed, uint256 liquidity) {
        address arx_ = arx;
        address usdt_ = usdt;
        IERC20(arx_).forceApprove(router, requiredArx);
        IERC20(usdt_).forceApprove(router, usdtAmount);
        return IDexRouter(router)
            .addLiquidity(arx_, usdt_, requiredArx, usdtAmount, amountArxMin, amountUsdtMin, treasury, deadline);
    }

    /// @dev Returns the cached pair, creating (or reusing an existing on-chain) pair via the
    ///      configured factory on first use. Emits {LiquidityPairCreated} when it caches the pair.
    function _ensurePair() private returns (address lpPair) {
        lpPair = pair;
        if (lpPair != address(0)) return lpPair;

        address factory = IProtocolConfig(protocolConfig).dexFactory();
        if (factory == address(0)) revert FactoryNotConfigured();

        lpPair = IDexFactory(factory).getPair(arx, usdt);
        if (lpPair == address(0)) lpPair = IDexFactory(factory).createPair(arx, usdt);

        pair = lpPair;
        emit LiquidityPairCreated(lpPair, arx, usdt);
    }

    /// @dev Reverts {ExcessiveSlippage} unless both minimum amounts are within `maxSlippageBps` of
    ///      the desired amounts, i.e. the caller cannot tolerate more slippage than the configured
    ///      maximum. A zero maximum requires the minimums to equal the desired amounts.
    function _requireWithinSlippage(
        uint256 desiredArx,
        uint256 desiredUsdt,
        uint256 minArx,
        uint256 minUsdt,
        uint256 maxSlippageBps
    ) private pure {
        uint256 floorArx = (desiredArx * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        uint256 floorUsdt = (desiredUsdt * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        if (minArx < floorArx || minUsdt < floorUsdt) revert ExcessiveSlippage();
    }

    /// @dev Transfers any residual `amount` of `token` back to the Treasury. No-op when zero.
    function _sweep(address token, uint256 amount) private {
        if (amount != 0) IERC20(token).safeTransfer(treasury, amount);
    }

    /// @dev Reverts {UnauthorizedExecutor} unless the caller is the owner or an authorized executor.
    function _requireExecutor() private view {
        if (msg.sender != owner() && !authorizedExecutors[msg.sender]) revert UnauthorizedExecutor();
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
