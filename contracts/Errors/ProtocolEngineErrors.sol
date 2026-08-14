// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ProtocolEngineErrors
/// @author Aurex Protocol
/// @notice Custom errors specific to the {ProtocolEngine}.
/// @dev Declared at file level so the contract can `import` each error by name. Generic
///      validations (zero address) reuse the shared errors in `Errors/CommonErrors.sol`.

/// @notice Thrown when a processing/preview target is not a registered protocol user.
error InvalidUser();

/// @notice Thrown when an investment-triggered reward (referral / infinity) is invoked by a caller
///         other than the wired InvestmentLifecycleEngine. These rewards take a caller-supplied
///         amount, so they must only be driven by the orchestrator on a real investment — never
///         directly, which would let an arbitrary caller inflate rewards.
error UnauthorizedCaller();

/// @notice Thrown when submitting a calculated reward to the accounting layer fails.
error CalculationFailed();

/// @notice Thrown when a withdrawal is requested but the user has no pending reward to withdraw.
error NothingToWithdraw();

/// @notice Thrown when the RewardManager fails to process the withdrawal claim.
error WithdrawalFailed();

/// @notice Names the terminal state in which a package's ROI accrual window has fully elapsed.
/// @dev Per the protocol specification, an expired package generates **no** further ROI: the
///      accrual window is day indexes `[1, roiDurationDays]` from the package start (day 0 is the
///      24-hour maturation day, which never pays), so the daily-ROI calculation yields zero once
///      `daysSincePackageStart > roiDurationDays`, and
///      processing records nothing for that day. This declaration documents that terminal state
///      as part of the engine's error vocabulary; the calculation returns zero rather than
///      reverting so that previews stay non-reverting and processing degrades gracefully.
error PackageExpired();

/// @notice Names the state in which an investor has no valid direct referrer.
/// @dev Per the protocol specification, direct-referral processing generates **no** reward when
///      the investor has no referrer (the referral tree root) and must return successfully
///      without reverting. This declaration documents that state as part of the engine's error
///      vocabulary; the calculation returns a zero reward rather than reverting so that previews
///      stay non-reverting and processing degrades gracefully.
error InvalidReferrer();

/// @notice Names the terminal state in which a package has reached its lifetime maximum ROI.
/// @dev Per the protocol specification, cumulative ROI is capped at
///      `packageAmount * maximumROIPercentage / 10000`. Once `claimed + pending` reaches that
///      cap the daily-ROI calculation yields zero, and before the cap it is reduced so the cap
///      is never exceeded. This declaration documents that terminal state; the calculation caps
///      (or returns zero) rather than reverting, mirroring {PackageExpired}.
error MaximumROIReached();
