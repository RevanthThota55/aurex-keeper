// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IRewardManager
/// @author Aurex Protocol
/// @notice Types, events and integration surface for the protocol {RewardManager}.
/// @dev The Reward Manager maintains reward accounting and processes reward claims. It never
///      manages registrations, packages or user investments, never custodies funds, and
///      contains no ROI/MLM calculation formulas — callers supply the amounts to record.
interface IRewardManager {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Per-user reward accounting. Amounts are in USDT base units unless noted; the
    ///         daily-ROI stream is *valued* in USDT (for the earnings cap) but *paid* in ARX.
    /// @param dailyROIReward Lifetime daily-ROI reward VALUE recorded for the user (USDT terms).
    /// @param referralReward Lifetime direct-referral (level-1) rewards recorded for the user.
    /// @param weeklyReward Lifetime weekly rank-bonus rewards recorded for the user.
    /// @param infinityReward Lifetime infinity rewards recorded for the user.
    /// @param levelReward Lifetime level-income (levels 2–15) rewards recorded for the user.
    /// @param claimedReward Total USDT rewards the user has claimed.
    /// @param totalRewardEarned Total reward VALUE ever recorded (sum of all buckets, USDT terms).
    /// @param pendingReward Currently claimable USDT balance.
    /// @param claimedArxReward Total ARX the user has claimed (ARX base units).
    /// @param pendingArxReward Currently claimable ARX balance (ARX base units).
    struct RewardInfo {
        uint256 dailyROIReward;
        uint256 referralReward;
        uint256 weeklyReward;
        uint256 infinityReward;
        uint256 levelReward;
        uint256 claimedReward;
        uint256 totalRewardEarned;
        uint256 pendingReward;
        uint256 claimedArxReward;
        uint256 pendingArxReward;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a daily-ROI reward is recorded for `user`.
    event DailyRewardRecorded(address indexed user, uint256 amount);

    /// @notice Emitted when a referral reward is recorded for `user`.
    event ReferralRewardRecorded(address indexed user, uint256 amount);

    /// @notice Emitted when a weekly reward is recorded for `user`.
    event WeeklyRewardRecorded(address indexed user, uint256 amount);

    /// @notice Emitted when an infinity reward is recorded for `user`.
    event InfinityRewardRecorded(address indexed user, uint256 amount);

    /// @notice Emitted when a level-income reward is recorded for `user`.
    event LevelRewardRecorded(address indexed user, uint256 amount);

    /// @notice Emitted when `user` claims `amount` of pending USDT rewards.
    event RewardClaimed(address indexed user, uint256 amount);

    /// @notice Emitted when `user` claims `amount` of pending ARX rewards (ARX base units).
    event ArxRewardClaimed(address indexed user, uint256 amount);

    /// @notice Emitted when a daily-ROI reward accrues in ARX for `user`.
    /// @param user The credited user.
    /// @param usdtValue The USDT-denominated value recorded (feeds the earnings cap).
    /// @param arxAmount The ARX credited to the pending ARX balance (ARX base units).
    event ArxRewardAccrued(address indexed user, uint256 usdtValue, uint256 arxAmount);

    /// @notice Emitted when the owner updates the RankEngine address.
    event RankEngineUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when a contract is authorized to record rewards.
    event AuthorizedContractAdded(address indexed account);

    /// @notice Emitted when a contract's reward-recording authorization is revoked.
    event AuthorizedContractRemoved(address indexed account);

    /// @notice Emitted when the owner updates the Treasury address.
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    /// @notice Emitted when the owner updates the InvestmentManager address.
    event InvestmentManagerUpdated(address indexed previousInvestmentManager, address indexed newInvestmentManager);

    /// @notice DEPRECATED — no longer emitted. The total-earnings cap moved from accrual to
    ///         withdrawal, so rewards are never clamped when recorded. Retained so historical
    ///         logs remain decodable; see {RewardWithdrawalCapped} for the live equivalent.
    /// @param user The user whose reward was clamped.
    /// @param requested The uncapped reward the caller attempted to record.
    /// @param credited The amount actually recorded after applying the cap.
    event EarningsCapApplied(address indexed user, uint256 requested, uint256 credited);

    /// @notice Emitted on every claim, recording how much of the pending value the cap released.
    /// @dev `paid < pendingValue` means the cap held the remainder back. It stays in the user's
    ///      pending balance and becomes claimable when a re-topup raises their cap — it is not
    ///      forfeited. Emitted even when nothing is withheld, so a claim's cap position is always
    ///      on-chain rather than inferable only from a missing event.
    /// @param user The claiming user.
    /// @param pendingValue The total pending value at claim time, in USDT base units.
    /// @param paid The value actually released, in USDT base units.
    event RewardWithdrawalCapped(address indexed user, uint256 pendingValue, uint256 paid);

    /// @notice Emitted by {checkSolvency} with the protocol's current solvency position.
    /// @param outstanding The unclaimed recorded liabilities, in USDT base units.
    /// @param backing The Treasury's USDT balance, in USDT base units.
    /// @param solvent Whether backing currently covers the outstanding liabilities.
    event SolvencyChecked(uint256 outstanding, uint256 backing, bool solvent);

    // -------------------------------------------------------------------------
    // Reward recording (authorized contracts only)
    // -------------------------------------------------------------------------

    /// @notice Records a daily-ROI reward for `user`: `amount` is the USDT-denominated value
    ///         (clamped by the earnings cap) and `arxAmount` the corresponding ARX payout
    ///         (scaled proportionally if the value is clamped). A zero `arxAmount` falls back
    ///         to the legacy USDT-payable path (no oracle price available).
    function recordDailyReward(address user, uint256 amount, uint256 arxAmount) external;

    /// @notice Records a referral reward of `amount` for `user`.
    function recordReferralReward(address user, uint256 amount) external;

    /// @notice Records a weekly reward of `amount` for `user`.
    function recordWeeklyReward(address user, uint256 amount) external;

    /// @notice Records an infinity reward of `amount` for `user`.
    function recordInfinityReward(address user, uint256 amount) external;

    /// @notice Records a level-income reward of `amount` for `user`.
    function recordLevelReward(address user, uint256 amount) external;

    // -------------------------------------------------------------------------
    // Claiming
    // -------------------------------------------------------------------------

    /// @notice Claims the caller's entire pending reward balance via the Treasury.
    function claimRewards() external;

    /// @notice Processes `user`'s pending reward claim, paying them via the Treasury.
    /// @dev Authorized-contract entrypoint used by the ProtocolEngine to coordinate withdrawals
    ///      without moving tokens itself. Mirrors {claimRewards} for a specified user.
    /// @param user The registered user whose pending balance is claimed and paid.
    /// @return amount The amount claimed and transferred, in USDT base units.
    function processClaim(address user) external returns (uint256 amount);

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Returns the full {RewardInfo} accounting for `user`.
    function getRewardInfo(address user) external view returns (RewardInfo memory);

    /// @notice Returns the currently claimable USDT balance for `user`.
    function pendingRewards(address user) external view returns (uint256);

    /// @notice Returns the currently claimable ARX balance for `user` (ARX base units).
    function pendingArxRewards(address user) external view returns (uint256);

    /// @notice Returns the total rewards `user` has claimed.
    function claimedRewards(address user) external view returns (uint256);

    /// @notice Returns the total rewards ever recorded for `user`.
    function totalEarned(address user) external view returns (uint256);

    // -------------------------------------------------------------------------
    // Business-rule earnings cap
    // -------------------------------------------------------------------------

    /// @notice The lifetime total-earnings cap for `user`, in USDT base units
    ///         (`totalInvested * maxTotalEarningsPercentage / 10000`). Returns `type(uint256).max`
    ///         when the cap is disabled (no ProtocolConfig wired, or the percentage is zero).
    function earningsCap(address user) external view returns (uint256);

    /// @notice The remaining earnings headroom for `user` before the cap binds, in USDT base units.
    ///         Returns `type(uint256).max` when the cap is disabled.
    function remainingEarningsCap(address user) external view returns (uint256);

    // -------------------------------------------------------------------------
    // Treasury solvency (accounting invariants & monitoring)
    // -------------------------------------------------------------------------

    /// @notice Unclaimed recorded reward liabilities (`totalRewardsRecorded - totalRewardsClaimed`).
    function outstandingLiabilities() external view returns (uint256);

    /// @notice The Treasury's USDT balance backing the recorded liabilities, in USDT base units.
    function treasuryBacking() external view returns (uint256);

    /// @notice Whether the Treasury's USDT backing currently covers the outstanding liabilities.
    function isTreasurySolvent() external view returns (bool);

    /// @notice Reads and emits the current solvency position for monitoring. Permissionless.
    /// @return outstanding The unclaimed recorded liabilities, in USDT base units.
    /// @return backing The Treasury's USDT balance, in USDT base units.
    /// @return solvent Whether backing currently covers the outstanding liabilities.
    function checkSolvency() external returns (uint256 outstanding, uint256 backing, bool solvent);

    // -------------------------------------------------------------------------
    // Configuration views
    // -------------------------------------------------------------------------

    /// @notice The configured Treasury address (owner-updatable).
    function treasury() external view returns (address);

    /// @notice The configured InvestmentManager address (owner-updatable).
    function investmentManager() external view returns (address);

    /// @notice The configured USDT token address (fixed after initialization).
    function usdt() external view returns (address);

    /// @notice The configured ARX token address (fixed after initialization).
    function arx() external view returns (address);

    /// @notice Whether `account` is authorized to record rewards.
    function authorizedContracts(address account) external view returns (bool);

    /// @notice Whether reward claims are paused at the module level.
    function rewardsPaused() external view returns (bool);

    /// @notice Cumulative reward VALUE ever recorded across all users and buckets (USDT terms —
    ///         includes the USDT-valued ARX ROI).
    function totalRewardsRecorded() external view returns (uint256);

    /// @notice Cumulative USDT rewards ever claimed across all users, in USDT base units.
    function totalRewardsClaimed() external view returns (uint256);

    /// @notice Cumulative USDT-claimable rewards ever recorded (excludes ARX-payable ROI).
    function totalUsdtRewardsRecorded() external view returns (uint256);

    /// @notice Cumulative ARX rewards ever recorded, in ARX base units.
    function totalArxRewardsRecorded() external view returns (uint256);

    /// @notice Cumulative ARX rewards ever claimed, in ARX base units.
    function totalArxRewardsClaimed() external view returns (uint256);

    /// @notice Unclaimed ARX reward liabilities (`totalArxRewardsRecorded - totalArxRewardsClaimed`).
    function arxOutstandingLiabilities() external view returns (uint256);

    /// @notice The RankEngine consulted for the rank-based earnings-cap boost (owner-updatable;
    ///         zero = boost inactive).
    function rankEngine() external view returns (address);
}
