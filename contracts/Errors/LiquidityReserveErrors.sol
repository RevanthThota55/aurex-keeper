// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LiquidityReserveErrors
/// @author Aurex Protocol
/// @notice Custom errors specific to the {LiquidityReserveEngine}.
/// @dev Declared at file level so the contract can `import` each error by name. Generic
///      validations (zero address) reuse the shared errors in `Errors/CommonErrors.sol`.

/// @notice Thrown when a caller other than the wired InvestmentLifecycleEngine records a reserve.
error NotLifecycleEngine();

/// @notice Thrown when a caller other than the wired LiquidityManager consumes the reserve.
error NotLiquidityManager();

/// @notice Thrown when a consumption exceeds the available reserved liquidity.
error InsufficientReserve();
