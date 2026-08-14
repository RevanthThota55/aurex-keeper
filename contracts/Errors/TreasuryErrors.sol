// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TreasuryErrors
/// @author Aurex Protocol
/// @notice Custom errors specific to the {Treasury} vault.
/// @dev Declared at file level so the contract can `import` each error by name. Generic
///      validations (zero address / zero amount) reuse the shared errors in
///      `Errors/CommonErrors.sol`.

/// @notice Thrown when a caller that is not an authorized protocol contract attempts a
///         protocol-only action (deposit or transfer of funds).
error UnauthorizedContract();

/// @notice Thrown when configuring a token address (USDT or ARX) that has already been set.
///         Token addresses are write-once.
error TokenAlreadyConfigured();

/// @notice Thrown when a token address is invalid (e.g. the zero address) for the operation.
error InvalidToken();

/// @notice Thrown when a native-BNB transfer fails.
error TransferFailed();

/// @notice Thrown when the treasury holds less than the requested amount of a token or BNB.
error InsufficientTreasuryBalance();
