// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IDexFactory
/// @author Aurex Protocol
/// @notice Minimal, DEX-agnostic factory interface for the subset of the Uniswap V2 / PancakeSwap V2
///         factory ABI the protocol uses to look up and create the ARX/USDT pair.
/// @dev DEX-agnostic by design (Phase 18, Feature 11): any Uniswap V2-compatible factory satisfies it.
interface IDexFactory {
    /// @notice Returns the pair address for `tokenA`/`tokenB`, or the zero address if none exists.
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    /// @notice Creates the `tokenA`/`tokenB` pair and returns its address.
    /// @dev Reverts in the underlying DEX if the pair already exists; callers should check
    ///      {getPair} first and reuse an existing pair.
    function createPair(address tokenA, address tokenB) external returns (address pair);
}
