// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IDexPair
/// @author Aurex Protocol
/// @notice Minimal, DEX-agnostic pair interface for the subset of the Uniswap V2 / PancakeSwap V2
///         pair ABI the protocol reads.
/// @dev Used by {AurexTokenImmutable} to derive the live ARX/USDT spot price for its drawdown-scaled
///      sell tax. Spot reserves are manipulable within a single transaction, so this is deliberately
///      **not** used anywhere a manipulated value could move funds — only to select a tax tier, where
///      the worst case for an attacker is paying a higher tax than they otherwise would.
interface IDexPair {
    /// @notice The pair's first token, sorted ascending by address.
    function token0() external view returns (address);

    /// @notice The pair's second token, sorted ascending by address.
    function token1() external view returns (address);

    /// @notice Current reserves and the timestamp of the last reserve-changing interaction.
    /// @return reserve0 Reserve of {token0}.
    /// @return reserve1 Reserve of {token1}.
    /// @return blockTimestampLast Timestamp of the last block in which reserves changed.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice Forces the pair's cached reserves to match its actual token balances.
    /// @dev Used by the {LiquidityManager}'s deposit-funded pool deepening: USDT is transferred to
    ///      the pair and `sync()` folds it into the reserves within the same transaction, so no
    ///      window exists for a third party to `skim()` the donation.
    function sync() external;
}
