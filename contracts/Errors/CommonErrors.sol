// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CommonErrors
/// @author Aurex Protocol
/// @notice Reusable, protocol-wide custom errors shared by every contract.
/// @dev Declared at file level so any contract can `import` an individual error by
///      name. Domain-specific errors (investment, reward, referral) will live in
///      their own files as those modules are implemented in later phases.

/// @notice Thrown when the zero address is supplied where a non-zero address is required.
error ZeroAddress();

/// @notice Thrown when a zero amount is supplied where a non-zero amount is required.
error ZeroAmount();

/// @notice Thrown when a supplied parameter is outside its accepted range or otherwise invalid.
error InvalidParameter();

/// @notice Thrown when an operation is attempted while the whole protocol is paused.
error ProtocolIsPaused();

/// @notice Thrown when an operation is attempted while its owning module is paused.
error ModuleIsPaused();

/// @notice Thrown when a pause is requested but the target is already paused.
error AlreadyPaused();

/// @notice Thrown when a resume is requested but the target is not paused.
error NotPaused();
