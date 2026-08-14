// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title InvestmentLifecycleErrors
/// @author Aurex Protocol
/// @notice Custom errors specific to the {InvestmentLifecycleEngine}.
/// @dev Declared at file level so the contract can `import` each error by name. Generic
///      validations (zero address) reuse the shared errors in `Errors/CommonErrors.sol`.

/// @notice Thrown when the investor passed to the lifecycle is not a registered protocol user.
error InvalidInvestor();

/// @notice Thrown when {processInvestment} is invoked by a caller other than the wired
///         InvestmentManager. The pipeline takes a caller-supplied amount, so it must only be
///         driven by the manager on a real, funded investment — never directly.
error UnauthorizedCaller();
