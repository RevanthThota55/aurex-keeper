// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ZeroAddress} from "../Errors/CommonErrors.sol";
import {InvalidUser, UnauthorizedCaller} from "../Errors/RankEngineErrors.sol";
import {IInvestmentManager} from "../Interfaces/IInvestmentManager.sol";
import {IProtocolConfig} from "../Interfaces/IProtocolConfig.sol";
import {IRankEngine} from "../Interfaces/IRankEngine.sol";

/// @title RankEngine
/// @author Aurex Protocol
/// @notice Network-topology state engine for the spec-v2 mechanics: per-leg team volumes,
///         matching business, ranks V1–V14, level-income unlock qualification and the weekly
///         rank-bonus installment ledger.
/// @dev
/// ## Responsibilities
/// On every deposit (routed by the InvestmentLifecycleEngine) this engine:
///   1. Updates the level-income qualification counters — a member is counted once per deposit
///      band ($100 / $250 / $500 thresholds, from the ProtocolConfig) on the first single
///      deposit reaching the band; counts credit the direct referrer (L1) and grandparent (L2).
///   2. Walks the upline (bounded by `maxUplineTraversalDepth` from the ProtocolConfig)
///      crediting the deposit to each ancestor's **leg** — the ancestor's direct child through
///      which the deposit arrived. Matching business is `min(strongest leg, other legs)`.
///   3. Evaluates rank promotions. Ranks V1–V10 require a matching-business threshold; ranks
///      V11–V14 require N legs each containing a member of a required lower rank (both from the
///      ProtocolConfig). Each achievement enqueues the rank's bonus, split into equal
///      installments paid on a fixed interval (both frozen at achievement).
///   4. Propagates new rank achievements up the tree so ancestors' per-leg best-rank counters
///      (the V11–V14 criteria inputs) stay current.
///
/// ## Explicit non-responsibilities
/// This engine pays **no** rewards and holds **no** funds. The ProtocolEngine reads
/// qualification/rank state for the level-income and infinity calculations, and collects due
/// rank-bonus amounts via {collectDueRankBonus} for recording with the RewardManager. The
/// referral tree is read **only** from the InvestmentManager — never duplicated here.
///
/// ## Bounded traversal
/// Upline walks are bounded by `maxUplineTraversalDepth` (ProtocolConfig) as a gas-safety cap.
/// Volume contributions and rank propagation beyond the cap are not credited; the business
/// plan's "unlimited depth" is honoured up to this operational bound.
///
/// ## Upgradeability
/// UUPS (ERC-1967). Deploy behind an `ERC1967Proxy`; only the owner may authorize an upgrade
/// or rewire addresses.
contract RankEngine is Initializable, OwnableUpgradeable, UUPSUpgradeable, IRankEngine {
    /// @notice The highest rank in the ladder (V14).
    uint8 public constant MAX_RANK = 14;

    /// @notice Level-income band boundaries: band 1 unlocks levels 1–5, band 2 levels 6–10,
    ///         band 3 levels 11–15. Each band opens as a whole once its criteria are met.
    uint256 public constant BAND1_LEVELS = 5;
    /// @notice The level ceiling unlocked by band 2.
    uint256 public constant BAND2_LEVELS = 10;
    /// @notice The level ceiling unlocked by band 3.
    uint256 public constant BAND3_LEVELS = 15;

    /// @notice Qualified directs needed to open band 1, used only while ProtocolConfig is unwired.
    /// @dev Deliberately separate from {BAND1_LEVELS} even though both are 5. One is a REQUIREMENT
    ///      (how many directs you must sponsor), the other a PAYOUT DEPTH (how many levels open).
    ///      Sharing a symbol for the two is what let the requirement silently ignore
    ///      `levelUnlockL1Count`; keeping them distinct means retuning either cannot disturb the
    ///      other. The live threshold is always the configured value — this is the fallback only.
    uint256 public constant DEFAULT_BAND1_DIRECTS = 5;

    // --- Wiring ---------------------------------------------------------------

    /// @inheritdoc IRankEngine
    address public override investmentManager;
    /// @inheritdoc IRankEngine
    address public override protocolConfig;
    /// @inheritdoc IRankEngine
    address public override lifecycleEngine;
    /// @inheritdoc IRankEngine
    address public override protocolEngine;

    // --- Qualification (level income) ----------------------------------------

    /// @notice Per-user qualification counters.
    mapping(address user => QualificationCounts counts) private _counts;

    /// @notice Deposit bands each user has already been counted at (bit 0 = band 1, bit 1 =
    ///         band 2, bit 2 = band 3), so a member is never double-counted per band.
    mapping(address user => uint8 bands) private _countedBands;

    // --- Team volumes ---------------------------------------------------------

    /// @inheritdoc IRankEngine
    mapping(address user => mapping(address leg => uint256 volume)) public override legVolume;
    /// @inheritdoc IRankEngine
    mapping(address user => uint256 volume) public override strongestLegVolume;
    /// @notice The direct child whose leg currently holds the user's strongest volume.
    mapping(address user => address leg) public strongestLeg;
    /// @inheritdoc IRankEngine
    mapping(address user => uint256 volume) public override totalTeamVolume;

    // --- Ranks ----------------------------------------------------------------

    /// @notice Current rank per user (0 = none, 1..14 = V1..V14).
    mapping(address user => uint8 rank) private _rank;

    /// @notice The best rank achieved by any member inside each of the user's direct legs.
    mapping(address user => mapping(address leg => uint8 rank)) public legMaxRank;

    /// @inheritdoc IRankEngine
    mapping(address user => mapping(uint8 rank => uint32 count)) public override legsAtRank;

    // --- Rank-bonus installments ---------------------------------------------

    /// @notice Per-user rank-bonus installment ledger (append-only; entries deplete in place).
    mapping(address user => RankBonus[] bonuses) private _bonuses;

    // --- Cycle renewal (appended in the spec-v2.1 phase) -----------------------

    /// @notice Leg-volume snapshot taken when a bonus cycle starts, against which the renewal
    ///         requirement (new business per leg) is measured.
    /// @param strongVolume The strongest-leg volume at cycle start.
    /// @param otherVolume The combined other-leg volume at cycle start.
    struct CycleSnapshot {
        uint256 strongVolume;
        uint256 otherVolume;
    }

    /// @notice Per-user snapshot for the current (latest) bonus cycle.
    mapping(address user => CycleSnapshot snapshot) private _cycleSnapshot;

    /// @notice Reserved storage slots (13 used + 37 reserved = 50) for forward-compatible upgrades.
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[37] private __gap;

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the engine and wires the read-side addresses.
    /// @dev Callable exactly once, on the proxy. The authorized callers (lifecycle engine,
    ///      protocol engine) are wired post-deployment via their setters; both guards are
    ///      fail-closed while unset.
    /// @param owner_ Protocol administrator.
    /// @param investmentManager_ InvestmentManager (referral-tree source of truth).
    /// @param protocolConfig_ ProtocolConfig (thresholds and tables).
    function initialize(address owner_, address investmentManager_, address protocolConfig_) external initializer {
        if (owner_ == address(0) || investmentManager_ == address(0) || protocolConfig_ == address(0)) {
            revert ZeroAddress();
        }
        __Ownable_init(owner_);
        investmentManager = investmentManager_;
        protocolConfig = protocolConfig_;
    }

    // -------------------------------------------------------------------------
    // Owner configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the InvestmentManager address.
    /// @param newInvestmentManager The new InvestmentManager address (non-zero).
    function setInvestmentManager(address newInvestmentManager) external onlyOwner {
        if (newInvestmentManager == address(0)) revert ZeroAddress();
        address previous = investmentManager;
        investmentManager = newInvestmentManager;
        emit InvestmentManagerUpdated(previous, newInvestmentManager);
    }

    /// @notice Updates the ProtocolConfig address.
    /// @param newProtocolConfig The new ProtocolConfig address (non-zero).
    function setProtocolConfig(address newProtocolConfig) external onlyOwner {
        if (newProtocolConfig == address(0)) revert ZeroAddress();
        address previous = protocolConfig;
        protocolConfig = newProtocolConfig;
        emit ProtocolConfigUpdated(previous, newProtocolConfig);
    }

    /// @notice Updates the InvestmentLifecycleEngine authorized to record deposits.
    /// @param newLifecycleEngine The new lifecycle engine address (non-zero).
    function setLifecycleEngine(address newLifecycleEngine) external onlyOwner {
        if (newLifecycleEngine == address(0)) revert ZeroAddress();
        address previous = lifecycleEngine;
        lifecycleEngine = newLifecycleEngine;
        emit LifecycleEngineUpdated(previous, newLifecycleEngine);
    }

    /// @notice Updates the ProtocolEngine authorized to collect rank bonuses.
    /// @param newProtocolEngine The new ProtocolEngine address (non-zero).
    function setProtocolEngine(address newProtocolEngine) external onlyOwner {
        if (newProtocolEngine == address(0)) revert ZeroAddress();
        address previous = protocolEngine;
        protocolEngine = newProtocolEngine;
        emit ProtocolEngineUpdated(previous, newProtocolEngine);
    }

    // -------------------------------------------------------------------------
    // Recording (authorized callers only)
    // -------------------------------------------------------------------------

    /// @inheritdoc IRankEngine
    function recordDeposit(address investor, uint256 amount) external override {
        // Fail-closed: while the lifecycle engine is unwired nobody may record (the amount is
        // caller-supplied, so it must be backed by a real, funded investment).
        if (msg.sender != lifecycleEngine) revert UnauthorizedCaller();
        IInvestmentManager manager = IInvestmentManager(investmentManager);
        if (!manager.isRegistered(investor)) revert InvalidUser();
        if (amount == 0) return;

        IProtocolConfig config = IProtocolConfig(protocolConfig);

        _updateQualification(manager, config, investor, amount);
        uint256 ancestors = _creditVolumes(manager, config, investor, amount);

        emit DepositRecorded(investor, amount, ancestors);
    }

    /// @inheritdoc IRankEngine
    function collectDueRankBonus(address user) external override returns (uint256 due) {
        // Fail-closed: only the wired ProtocolEngine may deplete the ledger (it records the
        // returned amount with the RewardManager).
        if (msg.sender != protocolEngine) revert UnauthorizedCaller();

        RankBonus[] storage list = _bonuses[user];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            RankBonus storage bonus = list[i];
            uint32 remaining = bonus.remaining;
            // Installment due-times are multi-day boundaries; validator timestamp leeway is immaterial.
            // forge-lint: disable-next-line(block-timestamp)
            if (remaining == 0 || block.timestamp < bonus.nextPayTime) continue;

            uint64 interval = bonus.interval;
            // How many installment boundaries have elapsed (>= 1 given the guard above); a zero
            // interval degenerates to "all remaining due at once".
            uint256 payable_ = interval == 0 ? remaining : ((block.timestamp - bonus.nextPayTime) / interval + 1);
            if (payable_ > remaining) payable_ = remaining;

            due += bonus.amountPerPayment * payable_;
            // Safe: `payable_ <= remaining` (uint32) by the clamp above.
            // forge-lint: disable-next-line(unsafe-typecast)
            bonus.remaining = remaining - uint32(payable_);
            // Safe: `payable_ <= remaining <= 10k` (config-bounded) and `interval <= 10 years`.
            // forge-lint: disable-next-line(unsafe-typecast)
            bonus.nextPayTime += uint64(payable_ * interval);
        }

        if (due != 0) emit RankBonusCollected(user, due);

        // Cycle renewal: once the current rank's latest cycle is exhausted, a fresh cycle starts
        // when BOTH the power leg and the weaker legs have added the required new business.
        _tryRenewCycle(user);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IRankEngine
    function rankOf(address user) external view override returns (uint8) {
        return _rank[user];
    }

    /// @inheritdoc IRankEngine
    function matchingVolume(address user) public view override returns (uint256) {
        uint256 strongest = strongestLegVolume[user];
        uint256 others = totalTeamVolume[user] - strongest;
        return strongest < others ? strongest : others;
    }

    /// @inheritdoc IRankEngine
    function unlockedLevels(address user) public view override returns (uint256) {
        IProtocolConfig config = IProtocolConfig(protocolConfig);
        QualificationCounts storage counts = _counts[user];
        uint256 l1Need = config.levelUnlockL1Count();
        uint256 l2Need = config.levelUnlockL2Count();
        if (l1Need != 0 && l2Need != 0) {
            if (counts.directs500 >= l1Need && counts.level2At500 >= l2Need) return BAND3_LEVELS;
            if (counts.directs250 >= l1Need && counts.level2At250 >= l2Need) return BAND2_LEVELS;
        }
        // Band 1 is all-or-nothing, like bands 2 and 3: the five levels unlock together once the
        // member has `levelUnlockL1Count` qualified directs, and nothing unlocks before that.
        //
        // This replaces a per-direct ramp that returned `directs` below the threshold, so a member
        // with four qualified directs held four unlocked levels and earned level-2 income — which
        // read as a bug against the stated "$100 x 5 directs unlocks level income" rule.
        //
        // The threshold is the CONFIGURED direct count, never the level ceiling. Bands 2 and 3
        // already read `levelUnlockL1Count`; band 1 reusing BAND1_LEVELS meant the requirement
        // silently ignored config and would not have followed a retune. While ProtocolConfig is
        // unwired the fallback is {DEFAULT_BAND1_DIRECTS} — a requirement constant of its own, so
        // the two concepts never share a symbol again.
        uint256 need = l1Need == 0 ? DEFAULT_BAND1_DIRECTS : l1Need;
        return counts.directs100 >= need ? BAND1_LEVELS : 0;
    }

    /// @inheritdoc IRankEngine
    function qualificationOf(address user) external view override returns (QualificationCounts memory) {
        return _counts[user];
    }

    /// @inheritdoc IRankEngine
    function rankBonusesOf(address user) external view override returns (RankBonus[] memory) {
        return _bonuses[user];
    }

    /// @inheritdoc IRankEngine
    function previewDueRankBonus(address user) public view override returns (uint256 due) {
        RankBonus[] storage list = _bonuses[user];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            RankBonus storage bonus = list[i];
            uint32 remaining = bonus.remaining;
            // forge-lint: disable-next-line(block-timestamp)
            if (remaining == 0 || block.timestamp < bonus.nextPayTime) continue;
            uint64 interval = bonus.interval;
            uint256 payable_ = interval == 0 ? remaining : ((block.timestamp - bonus.nextPayTime) / interval + 1);
            if (payable_ > remaining) payable_ = remaining;
            due += bonus.amountPerPayment * payable_;
        }
    }

    /// @inheritdoc IRankEngine
    function getRankInfo(address user) external view override returns (RankInfo memory info) {
        info = RankInfo({
            rank: _rank[user],
            matchingVolume: matchingVolume(user),
            strongestLegVolume: strongestLegVolume[user],
            totalTeamVolume: totalTeamVolume[user],
            unlockedLevels: unlockedLevels(user),
            dueBonus: previewDueRankBonus(user)
        });
    }

    // -------------------------------------------------------------------------
    // Internal — qualification
    // -------------------------------------------------------------------------

    /// @dev Marks the deposit bands this single deposit reaches (once per band per user) and
    ///      credits the newly reached bands to the direct referrer's L1 counters and the
    ///      grandparent's L2 counters. A band with a zero configured threshold is ignored.
    function _updateQualification(IInvestmentManager manager, IProtocolConfig config, address investor, uint256 amount)
        private
    {
        uint8 counted = _countedBands[investor];
        uint8 newly;

        uint256 band1 = config.levelUnlockBand1Deposit();
        uint256 band2 = config.levelUnlockBand2Deposit();
        uint256 band3 = config.levelUnlockBand3Deposit();
        if (band1 != 0 && amount >= band1 && counted & 1 == 0) newly |= 1;
        if (band2 != 0 && amount >= band2 && counted & 2 == 0) newly |= 2;
        if (band3 != 0 && amount >= band3 && counted & 4 == 0) newly |= 4;
        if (newly == 0) return;

        _countedBands[investor] = counted | newly;

        address referrer = manager.getUser(investor).referrer;
        if (referrer == address(0)) return;
        QualificationCounts storage direct = _counts[referrer];
        if (newly & 1 != 0) direct.directs100 += 1;
        if (newly & 2 != 0) direct.directs250 += 1;
        if (newly & 4 != 0) direct.directs500 += 1;

        address grandparent = manager.getUser(referrer).referrer;
        if (grandparent == address(0)) return;
        QualificationCounts storage level2 = _counts[grandparent];
        if (newly & 2 != 0) level2.level2At250 += 1;
        if (newly & 4 != 0) level2.level2At500 += 1;
    }

    // -------------------------------------------------------------------------
    // Internal — volumes & ranks
    // -------------------------------------------------------------------------

    /// @dev Credits `amount` to every ancestor's leg on the path from `investor` to the root
    ///      (bounded by the configured traversal depth), evaluating rank promotions as volumes
    ///      change. Returns the number of ancestors credited.
    function _creditVolumes(IInvestmentManager manager, IProtocolConfig config, address investor, uint256 amount)
        private
        returns (uint256 ancestors)
    {
        uint256 maxDepth = config.maxUplineTraversalDepth();
        address child = investor;
        for (uint256 depth = 0; depth < maxDepth; depth++) {
            address parent = manager.getUser(child).referrer;
            if (parent == address(0)) break;

            uint256 updated = legVolume[parent][child] + amount;
            legVolume[parent][child] = updated;
            totalTeamVolume[parent] += amount;
            if (updated > strongestLegVolume[parent]) {
                strongestLegVolume[parent] = updated;
                strongestLeg[parent] = child;
            }

            _tryPromote(manager, config, parent);

            child = parent;
            ancestors++;
        }
    }

    /// @dev Promotes `user` through every consecutively-satisfied rank. V1–V10 criteria are
    ///      matching-business thresholds; V11–V14 criteria require `rankLegCount` legs each
    ///      containing a member of the required lower rank. Each achievement enqueues the rank
    ///      bonus and, after the ladder settles, the new best rank is propagated up the tree.
    function _tryPromote(IInvestmentManager manager, IProtocolConfig config, address user) private {
        uint8 current = _rank[user];
        uint8 achieved = current;

        while (achieved < MAX_RANK) {
            if (!_meetsCriteria(config, user, achieved + 1)) break;
            achieved++;
            _rank[user] = achieved;
            emit RankAchieved(user, achieved);
            _enqueueBonus(config, user, achieved);
        }

        if (achieved != current) {
            _propagateLegRank(manager, config, user, achieved);
        }
    }

    /// @dev Whether `user` currently satisfies the criteria for `targetRank` (1-based). Exactly
    ///      one criterion applies per rank: a non-zero matching threshold, else a leg-rank
    ///      requirement. An unconfigured rank is never satisfied (fail-closed).
    function _meetsCriteria(IProtocolConfig config, address user, uint8 targetRank) private view returns (bool) {
        uint256 threshold = config.rankMatchingThreshold(targetRank);
        if (threshold != 0) return matchingVolume(user) >= threshold;

        uint256 requiredRank = config.rankLegRequirement(targetRank);
        if (requiredRank == 0 || requiredRank > MAX_RANK) return false;
        uint256 legCount = config.rankLegCount();
        if (legCount == 0) return false;
        // Safe: `requiredRank <= MAX_RANK (14)` by the guard above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return legsAtRank[user][uint8(requiredRank)] >= legCount;
    }

    /// @dev Enqueues the bonus for `user`'s achievement of `achievedRank`: the configured total,
    ///      split into equal installments on the configured interval, both frozen at achievement.
    ///      A zero-configured bonus or installment count enqueues nothing. Every enqueue starts a
    ///      new cycle, so the renewal snapshot resets to the current leg volumes.
    function _enqueueBonus(IProtocolConfig config, address user, uint8 achievedRank) private {
        uint256 total = config.rankBonusTotal(achievedRank);
        uint256 installments = config.rankBonusInstallments();
        if (total == 0 || installments == 0) return;

        uint256 interval = config.rankBonusInterval();
        uint256 perPayment = total / installments;
        if (perPayment == 0) return;

        _bonuses[user].push(
            RankBonus({
                rankId: achievedRank,
                // Safe: the ProtocolConfig bounds installments at 10,000 and the interval at 10
                // years, so every packed field fits its width.
                // forge-lint: disable-next-line(unsafe-typecast)
                remaining: uint32(installments),
                // First installment falls one interval after achievement (7 days under the
                // configured schedule; the interval is whatever ProtocolConfig held at achievement).
                // forge-lint: disable-next-line(block-timestamp,unsafe-typecast)
                nextPayTime: uint64(block.timestamp + interval),
                // forge-lint: disable-next-line(unsafe-typecast)
                interval: uint64(interval),
                amountPerPayment: perPayment
            })
        );

        uint256 strong = strongestLegVolume[user];
        _cycleSnapshot[user] = CycleSnapshot({strongVolume: strong, otherVolume: totalTeamVolume[user] - strong});

        emit RankBonusEnqueued(user, achievedRank, total, perPayment, installments);
    }

    /// @dev Renews the current rank's bonus cycle when the latest cycle is exhausted and the
    ///      renewal requirement is met: since the cycle started, the power (strongest) leg AND
    ///      the weaker legs must EACH have added `rankRenewalLegBps` of the rank's matching base
    ///      in new business (15% + 15% = 30% combined under the finalized rule). The base is the
    ///      rank's matching threshold, falling back to the nearest lower configured threshold for
    ///      the leg-criteria ranks (V11–V14). A zero `rankRenewalLegBps` disables renewal.
    function _tryRenewCycle(address user) private {
        uint8 rank = _rank[user];
        if (rank == 0) return;
        RankBonus[] storage list = _bonuses[user];
        uint256 len = list.length;
        if (len == 0 || list[len - 1].remaining != 0) return; // no cycle, or still paying

        IProtocolConfig config = IProtocolConfig(protocolConfig);
        uint256 legBps = config.rankRenewalLegBps();
        if (legBps == 0) return;
        uint256 base = _renewalBase(config, rank);
        if (base == 0) return;

        uint256 required = (base * legBps) / 10_000;
        CycleSnapshot storage snapshot = _cycleSnapshot[user];
        uint256 strong = strongestLegVolume[user];
        uint256 others = totalTeamVolume[user] - strong;
        if (strong < snapshot.strongVolume + required || others < snapshot.otherVolume + required) return;

        _enqueueBonus(config, user, rank); // starts the next cycle and resets the snapshot
        emit RankCycleRenewed(user, rank);
    }

    /// @dev The renewal base for `rank`: its matching threshold, or — for leg-criteria ranks with
    ///      a zero threshold (V11–V14) — the nearest lower rank's non-zero threshold (V10's).
    function _renewalBase(IProtocolConfig config, uint8 rank) private view returns (uint256) {
        for (uint256 r = rank; r >= 1; r--) {
            uint256 threshold = config.rankMatchingThreshold(r);
            if (threshold != 0) return threshold;
        }
        return 0;
    }

    /// @dev Propagates `user`'s new best rank up the referral chain (bounded by the configured
    ///      traversal depth): each ancestor's per-leg best-rank record for the path leg is
    ///      raised, its `legsAtRank` counters updated, and the ancestor re-evaluated for the
    ///      leg-criteria ranks (V11–V14). Stops early once an ancestor's path leg already knows
    ///      an equal-or-better rank — a prior propagation already carried it further up.
    function _propagateLegRank(IInvestmentManager manager, IProtocolConfig config, address user, uint8 newRank)
        private
    {
        uint256 maxDepth = config.maxUplineTraversalDepth();
        address child = user;
        uint8 carried = newRank;

        for (uint256 depth = 0; depth < maxDepth; depth++) {
            address parent = manager.getUser(child).referrer;
            if (parent == address(0)) break;

            uint8 known = legMaxRank[parent][child];
            if (carried <= known) break; // already propagated at least this far up

            legMaxRank[parent][child] = carried;
            for (uint8 r = known + 1; r <= carried; r++) {
                legsAtRank[parent][r] += 1;
            }

            uint8 before = _rank[parent];
            _tryPromote(manager, config, parent);
            uint8 after_ = _rank[parent];

            // Carry the best rank on the path upward: the parent's own (possibly new) rank also
            // lives inside the grandparent's leg.
            if (after_ != before && after_ > carried) carried = after_;

            child = parent;
        }
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
