// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ProtocolAdminErrors
/// @author Aurex Protocol
/// @notice Custom errors specific to the {ProtocolAdmin} operational contract.
/// @dev Declared at file level so the contract can `import` each error by name. Generic
///      validations (zero address / zero amount) reuse the shared errors in `CommonErrors`.

/// @notice Thrown when a recovery targets a protocol-owned token (USDT, ARX or the LP pair).
error ProtectedToken();

/// @notice Thrown when a native BNB recovery transfer fails.
error RecoveryFailed();
