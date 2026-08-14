// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IRankEngine
/// @author Aurex Protocol
/// @notice Types, events and integration surface for the protocol {RankEngine} — the network
///         topology tracker behind the spec-v2 level-income, rank (V1–V14) and weekly
///         rank-bonus mechanics.
/// @dev The Rank Engine owns team-volume accounting (per-leg), matching-business derivation,
///      rank achievement, level-income unlock qualification and the rank-bonus installment
///      ledger. It performs **no** reward payments and holds **no** funds — the
///      {ProtocolEngine} reads qualification/rank state to compute rewards and collects due
///      rank-bonus amounts for recording with the {RewardManager}.
interface IRankEngine {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Per-user level-income qualification counters. Members are counted **once** per
    ///         deposit band, on the first single deposit that reaches the band's threshold.
    /// @param directs100 Direct referrals with at least one deposit >= the band-1 threshold ($100).
    /// @param directs250 Direct referrals with at least one deposit >= the band-2 threshold ($250).
    /// @param directs500 Direct referrals with at least one deposit >= the band-3 threshold ($500).
    /// @param level2At250 Level-2 team members with at least one deposit >= the band-2 threshold.
    /// @param level2At500 Level-2 team members with at least one deposit >= the band-3 threshold.
    struct QualificationCounts {
        uint32 directs100;
        uint32 directs250;
        uint32 directs500;
        uint32 level2At250;
        uint32 level2At500;
    }

    /// @notice One rank-achievement bonus, paid in equal installments on a fixed interval.
    /// @param rankId The 1-based rank (V1..V14) whose achievement created this bonus.
    /// @param remaining Installments still unpaid.
    /// @param nextPayTime The timestamp the next installment becomes due.
    /// @param interval The payment interval frozen at achievement, in seconds.
    /// @param amountPerPayment The USDT base-unit amount of each installment.
    struct RankBonus {
        uint8 rankId;
        uint32 remaining;
        uint64 nextPayTime;
        uint64 interval;
        uint256 amountPerPayment;
    }

    /// @notice Aggregate rank/qualification snapshot for a user (dashboard / integration view).
    /// @param rank The user's current rank (0 = none, 1..14 = V1..V14).
    /// @param matchingVolume The user's matching business, in USDT base units.
    /// @param strongestLegVolume The user's strongest-leg team volume, in USDT base units.
    /// @param totalTeamVolume The user's total team volume across all legs, in USDT base units.
    /// @param unlockedLevels How many level-income levels (0..15) the user has unlocked.
    /// @param dueBonus The rank-bonus amount currently collectable, in USDT base units.
    struct RankInfo {
        uint8 rank;
        uint256 matchingVolume;
        uint256 strongestLegVolume;
        uint256 totalTeamVolume;
        uint256 unlockedLevels;
        uint256 dueBonus;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted after a deposit's network effects (volumes, qualification, ranks) are recorded.
    /// @param investor The depositing user.
    /// @param amount The deposit amount, in USDT base units.
    /// @param ancestorsUpdated How many upline ancestors received the volume credit.
    event DepositRecorded(address indexed investor, uint256 amount, uint256 ancestorsUpdated);

    /// @notice Emitted when a user achieves a new rank.
    /// @param user The achieving user.
    /// @param rank The 1-based rank achieved (V1..V14).
    event RankAchieved(address indexed user, uint8 indexed rank);

    /// @notice Emitted when a rank achievement enqueues its bonus installments.
    /// @param user The achieving user.
    /// @param rank The 1-based rank achieved.
    /// @param totalBonus The total bonus for the rank, in USDT base units.
    /// @param amountPerPayment The per-installment amount, in USDT base units.
    /// @param installments The number of installments.
    event RankBonusEnqueued(
        address indexed user, uint8 indexed rank, uint256 totalBonus, uint256 amountPerPayment, uint256 installments
    );

    /// @notice Emitted when due rank-bonus installments are collected for payment.
    /// @param user The user whose installments were collected.
    /// @param amount The total collected, in USDT base units.
    event RankBonusCollected(address indexed user, uint256 amount);

    /// @notice Emitted when a rank-bonus cycle renews (the renewal requirement was met after the
    ///         previous cycle exhausted).
    /// @param user The renewing user.
    /// @param rank The rank whose bonus cycle restarted.
    event RankCycleRenewed(address indexed user, uint8 indexed rank);

    /// @notice Emitted when the owner updates the InvestmentManager address.
    event InvestmentManagerUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the ProtocolConfig address.
    event ProtocolConfigUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the authorized lifecycle engine.
    event LifecycleEngineUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the authorized ProtocolEngine collector.
    event ProtocolEngineUpdated(address indexed previous, address indexed current);

    // -------------------------------------------------------------------------
    // Recording (authorized callers only)
    // -------------------------------------------------------------------------

    /// @notice Records the network effects of a deposit: credits team volume up the referral
    ///         chain (per-leg), updates level-income qualification counters, and evaluates rank
    ///         promotions (enqueuing rank bonuses on achievement).
    /// @dev Restricted to the wired InvestmentLifecycleEngine (fail-closed while unwired).
    /// @param investor The depositing (registered) user.
    /// @param amount The deposit amount, in USDT base units.
    function recordDeposit(address investor, uint256 amount) external;

    /// @notice Collects every currently-due rank-bonus installment for `user`, advancing the
    ///         installment ledger, and returns the total due for the caller to record/pay.
    /// @dev Restricted to the wired ProtocolEngine (fail-closed while unwired). The engine
    ///      records the returned amount with the RewardManager; this contract moves no funds.
    /// @param user The user whose due installments are collected.
    /// @return due The total amount collected, in USDT base units (zero when nothing is due).
    function collectDueRankBonus(address user) external returns (uint256 due);

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice The user's current rank (0 = none, 1..14 = V1..V14).
    function rankOf(address user) external view returns (uint8);

    /// @notice The user's matching business: `min(strongest leg, total volume - strongest leg)`.
    function matchingVolume(address user) external view returns (uint256);

    /// @notice The number of level-income levels (0..15) `user` has unlocked.
    /// @dev Levels 1–5 unlock one per band-1-qualified direct; levels 6–10 need the configured
    ///      L1/L2 team counts at the band-2 threshold; levels 11–15 the same at band-3.
    function unlockedLevels(address user) external view returns (uint256);

    /// @notice The user's qualification counters.
    function qualificationOf(address user) external view returns (QualificationCounts memory);

    /// @notice The user's rank-bonus installment ledger.
    function rankBonusesOf(address user) external view returns (RankBonus[] memory);

    /// @notice The rank-bonus amount currently due for `user` (what {collectDueRankBonus} would return).
    function previewDueRankBonus(address user) external view returns (uint256 due);

    /// @notice Aggregate rank/qualification snapshot for `user`.
    function getRankInfo(address user) external view returns (RankInfo memory);

    /// @notice The cumulative team volume `user` has received through direct leg `leg`.
    function legVolume(address user, address leg) external view returns (uint256);

    /// @notice The user's total team volume across all legs, in USDT base units.
    function totalTeamVolume(address user) external view returns (uint256);

    /// @notice The user's strongest-leg volume, in USDT base units.
    function strongestLegVolume(address user) external view returns (uint256);

    /// @notice The number of `user`'s direct legs whose subtree contains at least one member of
    ///         rank >= `rank`.
    function legsAtRank(address user, uint8 rank) external view returns (uint32);

    /// @notice The configured InvestmentManager (referral-tree source of truth).
    function investmentManager() external view returns (address);

    /// @notice The configured ProtocolConfig (thresholds / tables).
    function protocolConfig() external view returns (address);

    /// @notice The InvestmentLifecycleEngine authorized to record deposits.
    function lifecycleEngine() external view returns (address);

    /// @notice The ProtocolEngine authorized to collect rank bonuses.
    function protocolEngine() external view returns (address);
}
