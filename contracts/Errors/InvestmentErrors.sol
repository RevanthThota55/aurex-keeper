// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title InvestmentErrors
/// @author Aurex Protocol
/// @notice Custom errors specific to the {InvestmentManager}.
/// @dev Declared at file level so the contract can `import` each error by name. Generic
///      validations (zero address) reuse the shared errors in `Errors/CommonErrors.sol`.

/// @notice Thrown when a wallet that already has an account attempts to register again.
error AlreadyRegistered();

/// @notice Thrown when the supplied referrer does not exist (is not a registered account).
error InvalidReferral();

/// @notice Thrown when a wallet supplies itself as its own referrer.
error SelfReferral();

/// @notice Thrown when an investment amount is below the minimum or not a whole multiple
///         of the package unit (100 USDT).
error InvalidPackage();

/// @notice Thrown when an action requires a registered account but the caller has none.
error UserNotRegistered();

/// @notice Thrown when an upgrade target is lower than the caller's current package.
error PackageNotUpgradeable();

/// @notice Thrown when an operation requires an active package but the user holds none.
error UserNotActive();

/// @notice Thrown when a caller is not authorized for a privileged operation (ROI recording,
///         automatic-reinvestment execution).
error UnauthorizedCaller();

/// @notice Thrown when automatic reinvestment is not enabled — globally or for the target user.
error AutoReinvestDisabled();

/// @notice Thrown when the reinvest cooldown has not yet elapsed since the last execution.
error ReinvestCooldownActive();

/// @notice Thrown when a reinvest amount is outside the configured minimum/maximum bounds.
error ReinvestAmountOutOfBounds();

/// @notice Thrown when an investment index is out of range, or a batch length does not match the
///         user's investment count.
error InvalidInvestmentIndex();

/// @notice The deposit would exceed the user's rank-based daily deposit limit.
error DailyDepositLimitExceeded();

/// @notice A registry repair was attempted with a length that does not match the canonical
///         registration count, or with entries that are not registered users.
error RegistryRepairMismatch();
