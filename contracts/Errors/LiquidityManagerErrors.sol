// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LiquidityManagerErrors
/// @author Aurex Protocol
/// @notice Custom errors specific to the {LiquidityManager} DEX integration adapter.
/// @dev Declared at file level so the contract can `import` each error by name. Generic
///      validations (zero address / zero amount) reuse the shared errors in `CommonErrors`.

/// @notice Thrown when liquidity execution is attempted while it is paused.
error LiquidityExecutionIsPaused();

/// @notice Thrown when a caller is not the owner or an authorized liquidity executor.
error UnauthorizedExecutor();

/// @notice Thrown when the requested USDT amount exceeds the reserved liquidity available.
error InsufficientReserveBalance();

/// @notice Thrown when the supplied minimum amounts tolerate more than the configured max slippage.
error ExcessiveSlippage();

/// @notice Thrown when the supplied deadline has already passed.
error DeadlineExpired();

/// @notice Thrown when the DEX router is not configured in the ProtocolConfig.
error RouterNotConfigured();

/// @notice Thrown when the DEX factory is not configured in the ProtocolConfig.
error FactoryNotConfigured();

/// @notice Thrown when the ARX price is not configured in the ProtocolConfig.
error PriceNotConfigured();
