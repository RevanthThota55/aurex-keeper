// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title RewardErrors
/// @author Aurex Protocol
/// @notice Custom errors specific to the {RewardManager}.
/// @dev Declared at file level so the contract can `import` each error by name. Generic
///      validations (zero address) reuse the shared errors in `Errors/CommonErrors.sol`.

/// @notice Thrown when a caller that is not an authorized recorder attempts to record a reward.
error UnauthorizedContract();

/// @notice Thrown when a claim is attempted but the caller has no pending rewards.
error NothingToClaim();

/// @notice Thrown when a reward amount is zero.
error InvalidRewardAmount();

/// @notice Thrown when the target of a reward is not a registered protocol user.
error InvalidUser();

/// @notice Thrown when the Treasury fails to transfer the claimed rewards.
error TransferFailed();

/// @notice Thrown when a claim is attempted but the caller has already withdrawn their full
///         total-earnings cap. Rewards keep accruing and stay claimable once the cap rises
///         (via a re-topup), so this is a "locked, not lost" condition — distinct from
///         {NothingToClaim}, which means no balance has accrued at all.
error EarningsCapReached();
