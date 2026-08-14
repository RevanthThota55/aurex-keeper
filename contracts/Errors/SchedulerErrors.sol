// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SchedulerErrors
/// @author Aurex Protocol
/// @notice Custom errors specific to the {ProtocolScheduler}.
/// @dev Declared at file level so the contract can `import` each error by name.

/// @notice Thrown when a period has already been processed for a user (duplicate execution).
error AlreadyProcessed();

/// @notice Thrown when an execution is attempted while the scheduler is paused.
/// @dev Named `SchedulerIsPaused` (rather than `SchedulerPaused`) to avoid colliding with the
///      `SchedulerPaused` event, which shares the identifier namespace in Solidity.
error SchedulerIsPaused();

/// @notice Thrown when the target user is invalid (the zero address).
error InvalidUser();

/// @notice Thrown when a non-authorized account attempts to mark processing.
/// @dev Marking is restricted to the owner and authorized callers (the ProtocolEngine); this
///      prevents an arbitrary caller from consuming a victim's period slot to deny their rewards.
error UnauthorizedCaller();
