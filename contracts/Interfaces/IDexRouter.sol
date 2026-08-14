// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IDexRouter
/// @author Aurex Protocol
/// @notice Minimal, DEX-agnostic router interface for the subset of the Uniswap V2 / PancakeSwap V2
///         router ABI the protocol uses to add liquidity.
/// @dev Deliberately not tied to PancakeSwap: any Uniswap V2-compatible router (PancakeSwap,
///      ApeSwap, Biswap, …) satisfies this interface, so switching DEX requires only replacing the
///      configured router address — no code change (Phase 18, Feature 11).
interface IDexRouter {
    /// @notice The factory this router creates and looks up pairs through.
    function factory() external view returns (address);

    /// @notice Adds liquidity to the `tokenA`/`tokenB` pair, minting LP tokens to `to`.
    /// @dev The router pulls up to `amountADesired`/`amountBDesired` from the caller (`msg.sender`)
    ///      via `transferFrom`, deposits the optimal amounts respecting the current pool ratio, and
    ///      reverts unless at least `amountAMin`/`amountBMin` are deposited (slippage bound) and the
    ///      transaction is mined at or before `deadline`.
    /// @param tokenA First token of the pair.
    /// @param tokenB Second token of the pair.
    /// @param amountADesired Maximum amount of `tokenA` to deposit.
    /// @param amountBDesired Maximum amount of `tokenB` to deposit.
    /// @param amountAMin Minimum amount of `tokenA` to deposit (slippage bound).
    /// @param amountBMin Minimum amount of `tokenB` to deposit (slippage bound).
    /// @param to Recipient of the minted LP tokens.
    /// @param deadline Unix timestamp after which the transaction reverts.
    /// @return amountA Amount of `tokenA` actually deposited.
    /// @return amountB Amount of `tokenB` actually deposited.
    /// @return liquidity Amount of LP tokens minted to `to`.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Swaps an exact `amountIn` of `path[0]` for as much `path[path.length - 1]` as possible.
    /// @dev Used by the deposit-funded buyback: the protocol converts a slice of every deposit's USDT
    ///      into ARX on the open market before pairing the remainder into liquidity. `amountOutMin`
    ///      is the slippage bound and must never be left at zero on a live pool — a zero bound makes
    ///      the swap unconditionally sandwichable.
    /// @param amountIn Exact amount of the input token to spend.
    /// @param amountOutMin Minimum acceptable output (slippage bound); reverts below it.
    /// @param path Swap route; `path[0]` is the input token, the last entry the output token.
    /// @param to Recipient of the output token.
    /// @param deadline Unix timestamp after which the transaction reverts.
    /// @return amounts Input and output amounts for each hop along `path`.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Quotes the output amounts for swapping `amountIn` along `path`, at current reserves.
    /// @dev A spot quote, read in the same transaction it is used in, so it cannot be trusted as an
    ///      oracle. The protocol uses it only to derive a slippage floor from a value it is about to
    ///      trade against in the same call.
    /// @param amountIn Amount of `path[0]` to price.
    /// @param path Swap route.
    /// @return amounts Input and output amounts for each hop along `path`.
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}
