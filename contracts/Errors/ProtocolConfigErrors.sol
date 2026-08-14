// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ProtocolConfigErrors
/// @author Aurex Protocol
/// @notice Custom errors specific to the {ProtocolConfig}.
/// @dev Declared at file level so the contract can `import` each error by name.

/// @notice Thrown when a percentage exceeds 100% (the basis-point denominator) or is
///         otherwise out of its accepted range.
error InvalidPercentage();

/// @notice Thrown when the liquidity/treasury/reward allocation percentages do not sum to
///         exactly 100%.
error InvalidAllocation();

/// @notice Thrown when a configuration value is otherwise invalid (a required value is zero,
///         or an ordering constraint such as `max >= min` is violated).
error InvalidConfiguration();

/// @notice Thrown when an account that is neither the owner nor the designated price updater
///         calls the delegated ARX price feed.
error UnauthorizedPriceUpdater();

/// @notice Thrown when a delegated ARX price update moves the price further than
///         `arxPriceMaxDeviationBps` away from the current value. Guards the hot updater key:
///         a single manipulated or fat-fingered feed cannot reprice the ROI conversion.
error ArxPriceDeviationExceeded();
