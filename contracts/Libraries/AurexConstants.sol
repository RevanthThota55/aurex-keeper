// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AurexConstants
/// @author Aurex Protocol
/// @notice Protocol-wide constants describing the Aurex (ARX) token economics.
/// @dev Centralises the token configuration so every contract, script and test
///      references a single source of truth. This library contains data only and
///      no executable protocol logic. USDT-denominated values assume a 6-decimal
///      USDT; adjust for chains where USDT uses 18 decimals.
library AurexConstants {
    /// @notice Human-readable name of the token.
    string internal constant TOKEN_NAME = "Aurex";

    /// @notice Ticker symbol of the token.
    string internal constant TOKEN_SYMBOL = "ARX";

    /// @notice Number of decimals the token uses (ERC-20 standard).
    uint8 internal constant TOKEN_DECIMALS = 18;

    /// @notice Fixed total supply: 2,000,000 ARX, scaled by 1e18.
    uint256 internal constant TOTAL_SUPPLY = 2_000_000 * 10 ** 18;

    /// @notice Supply earmarked to seed the initial DEX liquidity pool: 100,000 ARX.
    uint256 internal constant INITIAL_LIQUIDITY_ARX = 100_000 * 10 ** 18;

    /// @notice Remaining supply sent to the owner wallet at initialization: 1,900,000 ARX.
    uint256 internal constant OWNER_ALLOCATION = TOTAL_SUPPLY - INITIAL_LIQUIDITY_ARX;

    /// @notice Initial launch price in USDT base units (6 decimals): 0.001 USDT per ARX.
    uint256 internal constant INITIAL_PRICE_USDT = 1000;

    /// @notice Recommended USDT to pair with `INITIAL_LIQUIDITY_ARX` when seeding the pool, in WHOLE
    ///         USDT — scale it by the live token's `decimals()` at the call site.
    /// @dev Previously declared as `100 * 10 ** 6`, which was wrong twice over: it assumed 6-decimal
    ///      USDT (BSC USDT has 18) and it described a pool with roughly one hundred dollars of depth.
    ///      A pool that thin cannot absorb a single member cashing out their ROI — the first real
    ///      withdrawal would move the price by more than the withdrawal is worth.
    ///
    ///      This is guidance, not an enforced value: the pool is seeded by a deployment transaction,
    ///      and the operator should size it against expected early deposit volume. Treat this as the
    ///      floor, not the target.
    uint256 internal constant INITIAL_LIQUIDITY_USDT_WHOLE = 25_000;
}
