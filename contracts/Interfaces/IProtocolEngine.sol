// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IProtocolEngine
/// @author Aurex Protocol
/// @notice Events and integration surface for the {ProtocolEngine}, the protocol's
///         business-logic layer.
/// @dev The engine performs every protocol calculation (daily ROI, direct referral, weekly
///      reward, infinity reward and reward withdrawals) and submits the results to the
///      RewardManager. It stores no user investments, no reward balances and holds no funds.
///      Rank / leadership qualification, liquidity and DEX behaviour arrive in later phases.
interface IProtocolEngine {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when daily-ROI processing runs for `user`.
    /// @param user The processed user.
    /// @param packageAmount The user's active package amount at processing time, in USDT base units.
    /// @param reward The daily-ROI reward recorded (zero when expired or capped out), in USDT base units.
    /// @param protocolDay The protocol day (from the scheduler) the processing was accounted to.
    event DailyROIProcessed(address indexed user, uint256 packageAmount, uint256 reward, uint256 protocolDay);

    /// @notice Emitted for each investment that accrues ROI during daily-ROI processing.
    /// @dev Daily-ROI processing iterates a user's active investments (independent ROI streams);
    ///      this reports the per-investment detail behind the aggregate {DailyROIProcessed}.
    /// @param user The processed user.
    /// @param investmentIndex The zero-based index of the credited investment.
    /// @param amount The investment principal, in USDT base units.
    /// @param reward The ROI recorded for this investment on this day, in USDT base units.
    event InvestmentROIProcessed(address indexed user, uint256 indexed investmentIndex, uint256 amount, uint256 reward);

    /// @notice Emitted when direct-referral processing runs for an investment or upgrade.
    /// @param investor The user whose investment/upgrade triggered the reward.
    /// @param referrer The investor's direct referrer credited with the reward (zero if none).
    /// @param investmentAmount The investment (or upgrade) amount the reward was computed from.
    /// @param rewardAmount The referral reward recorded for `referrer` (zero when there is no
    ///        referrer or the configured percentage yields zero), in USDT base units.
    event ReferralRewardProcessed(
        address indexed investor, address indexed referrer, uint256 investmentAmount, uint256 rewardAmount
    );

    /// @notice Emitted when a user's reward withdrawal completes.
    /// @param user The user who withdrew.
    /// @param grossAmount The pending reward claimed before any withdrawal fee, in USDT base units.
    /// @param netAmount The amount paid to the user after the withdrawal fee, in USDT base units.
    /// @param protocolDay The protocol day (from the scheduler) the withdrawal was accounted to.
    event WithdrawalCompleted(address indexed user, uint256 grossAmount, uint256 netAmount, uint256 protocolDay);

    /// @notice Emitted when weekly rank-bonus processing pays due installments to `user`.
    /// @param user The processed user.
    /// @param reward The total due installments recorded, in USDT base units.
    event WeeklyRankBonusProcessed(address indexed user, uint256 reward);

    /// @notice Emitted for each qualified ancestor credited during level-income processing.
    /// @param investor The user whose investment/upgrade triggered the distribution.
    /// @param receiver The qualified ancestor credited with this reward.
    /// @param level The receiver's level above the investor (2..15; level 1 is the direct
    ///        referral, paid by the referral module).
    /// @param investmentAmount The investment (or upgrade) amount the reward was computed from.
    /// @param rewardAmount The level-income reward recorded for `receiver`, in USDT base units.
    event LevelRewardProcessed(
        address indexed investor,
        address indexed receiver,
        uint256 indexed level,
        uint256 investmentAmount,
        uint256 rewardAmount
    );

    /// @notice Emitted for each ancestor credited during infinity-reward processing.
    /// @param investor The user whose investment/upgrade triggered the distribution.
    /// @param receiver The ancestor (upline) credited with this reward.
    /// @param investmentAmount The investment (or upgrade) amount the reward was computed from.
    /// @param rewardAmount The infinity reward recorded for `receiver` (may be zero), in USDT base units.
    /// @param depth The receiver's depth above the investor (1 = direct referrer).
    event InfinityRewardProcessed(
        address indexed investor,
        address indexed receiver,
        uint256 investmentAmount,
        uint256 rewardAmount,
        uint256 depth
    );

    /// @notice Emitted when the owner updates the InvestmentManager address.
    event InvestmentManagerUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the RewardManager address.
    event RewardManagerUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the Treasury address.
    event TreasuryUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the ProtocolConfig address.
    event ProtocolConfigUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the ProtocolScheduler address.
    event ProtocolSchedulerUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the authorized InvestmentLifecycleEngine.
    event InvestmentLifecycleEngineUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the RankEngine address.
    event RankEngineUpdated(address indexed previous, address indexed current);

    // -------------------------------------------------------------------------
    // Processing
    // -------------------------------------------------------------------------

    /// @notice Calculates and submits `user`'s daily-ROI reward to the RewardManager.
    function processDailyROI(address user) external;

    /// @notice Calculates the direct-referral reward for `investor`'s investment/upgrade and
    ///         submits it to the RewardManager, crediting `investor`'s direct referrer.
    /// @dev Intended to be called when a new investment or package upgrade occurs. Returns
    ///      successfully without recording anything when `investor` has no referrer or the
    ///      computed reward is zero. Daily-ROI processing never calls this.
    /// @param investor The registered user whose investment/upgrade triggers the reward.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    function processReferralReward(address investor, uint256 investmentAmount) external;

    /// @notice Pays `user`'s currently-due weekly rank-bonus installments: collects the due
    ///         amount from the RankEngine ledger and records it with the RewardManager.
    /// @dev Permissionless (keeper-friendly): due amounts are self-gated by each installment's
    ///      schedule, so repeated calls never double-pay. Returns without recording when the
    ///      weekly reward is disabled, no RankEngine is wired, or nothing is due.
    function processWeeklyReward(address user) external;

    /// @notice Distributes the infinity bonus for `investor`'s investment/upgrade: the nearest
    ///         upline achiever at or above the configured rank gate receives the bonus, and the
    ///         next achiever above them receives the configured upline share of it.
    /// @dev Intended to be called when a new investment or package upgrade occurs (never by daily
    ///      ROI). Traverses upward (bounded by `maxUplineTraversalDepth`) consulting the
    ///      RankEngine for each ancestor's rank. Returns without recording when the infinity
    ///      reward is disabled, the rank gate is unset, no RankEngine is wired, or no achiever
    ///      exists within the bound. Never reverts for a missing referrer or zero reward.
    /// @param investor The registered user whose investment/upgrade triggers the distribution.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    function processInfinityReward(address investor, uint256 investmentAmount) external;

    /// @notice Distributes level income for `investor`'s investment/upgrade: walks the upline and
    ///         credits each *qualified* ancestor at levels 2..N with the configured level rate.
    /// @dev Level 1 is the direct referral, paid by {processReferralReward} — the walk starts
    ///      paying at level 2. Qualification (unlocked levels) is read from the RankEngine.
    ///      Returns without recording when level income is disabled or no RankEngine is wired.
    /// @param investor The registered user whose investment/upgrade triggers the distribution.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    function processLevelReward(address investor, uint256 investmentAmount) external;

    // -------------------------------------------------------------------------
    // Withdrawal
    // -------------------------------------------------------------------------

    /// @notice Withdraws the caller's entire pending reward balance.
    /// @dev The engine coordinates the flow but never moves tokens itself: it validates the
    ///      caller, reads the pending reward from the RewardManager, applies the withdrawal
    ///      rules, and asks the RewardManager to process the claim (which pays the caller out of
    ///      the Treasury). Reverts {NothingToWithdraw} when nothing is pending and
    ///      {WithdrawalFailed} if the RewardManager claim fails.
    function withdrawRewards() external;

    // -------------------------------------------------------------------------
    // Previews (read-only calculation results)
    // -------------------------------------------------------------------------

    /// @notice Returns `user`'s currently calculated daily-ROI reward.
    function previewDailyROI(address user) external view returns (uint256);

    /// @notice Returns the direct-referral reward that an investment/upgrade of `investmentAmount`
    ///         by `user` would generate for `user`'s referrer (zero when there is no referrer).
    function previewReferralReward(address user, uint256 investmentAmount) external view returns (uint256);

    /// @notice Returns the weekly rank-bonus amount currently due for `user` (what
    ///         {processWeeklyReward} would record if run now).
    function previewWeeklyReward(address user) external view returns (uint256);

    /// @notice Returns the infinity distribution an investment/upgrade of `investmentAmount` by
    ///         `user` would generate: the nearest upline achiever and their bonus, and the next
    ///         achiever above them and their share.
    /// @dev All-zero when the infinity reward is disabled, the rank gate is unset, no RankEngine
    ///      is wired, or no achiever exists within the traversal bound.
    /// @param user The investor whose upline is inspected.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    /// @return achiever The nearest upline achiever at or above the rank gate (zero when none).
    /// @return achieverReward The achiever's bonus, in USDT base units.
    /// @return uplineAchiever The next achiever above `achiever` (zero when none).
    /// @return uplineReward The upline achiever's share, in USDT base units.
    function previewInfinityReward(address user, uint256 investmentAmount)
        external
        view
        returns (address achiever, uint256 achieverReward, address uplineAchiever, uint256 uplineReward);

    /// @notice Returns a withdrawal quote for `user`: the gross pending reward, the withdrawal
    ///         fee, and the net payout (`gross - fee`). Changes no state.
    /// @param user The user to quote.
    /// @return grossReward The user's total pending reward, in USDT base units.
    /// @return fee The withdrawal fee that would be applied, in USDT base units.
    /// @return netReward The amount the user would receive after the fee, in USDT base units.
    function previewWithdrawal(address user) external view returns (uint256 grossReward, uint256 fee, uint256 netReward);

    // -------------------------------------------------------------------------
    // Configuration views
    // -------------------------------------------------------------------------

    /// @notice The configured InvestmentManager address (owner-updatable).
    function investmentManager() external view returns (address);

    /// @notice The configured RewardManager address (owner-updatable).
    function rewardManager() external view returns (address);

    /// @notice The configured Treasury address (owner-updatable).
    function treasury() external view returns (address);

    /// @notice The configured ProtocolConfig address — source of every ROI parameter (owner-updatable).
    function protocolConfig() external view returns (address);

    /// @notice The configured ProtocolScheduler address — timing source and duplicate guard (owner-updatable).
    function protocolScheduler() external view returns (address);

    /// @notice Whether reward/ROI processing is paused at the module level.
    function processingPaused() external view returns (bool);

    /// @notice The InvestmentLifecycleEngine authorized to trigger investment-driven rewards
    ///         (referral / infinity / level) (owner-updatable; zero until wired, restriction inactive).
    function investmentLifecycleEngine() external view returns (address);

    /// @notice The RankEngine consulted for ranks, level qualification and the rank-bonus ledger
    ///         (owner-updatable; zero until wired — rank-driven rewards are then skipped).
    function rankEngine() external view returns (address);
}
