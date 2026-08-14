// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AlreadyPaused, ModuleIsPaused, NotPaused, ProtocolIsPaused, ZeroAddress} from "../Errors/CommonErrors.sol";
import {
    CalculationFailed,
    InvalidUser,
    NothingToWithdraw,
    UnauthorizedCaller,
    WithdrawalFailed
} from "../Errors/ProtocolEngineErrors.sol";
import {IInvestmentManager} from "../Interfaces/IInvestmentManager.sol";
import {IProtocolConfig} from "../Interfaces/IProtocolConfig.sol";
import {IProtocolEngine} from "../Interfaces/IProtocolEngine.sol";
import {IProtocolScheduler} from "../Interfaces/IProtocolScheduler.sol";
import {IRankEngine} from "../Interfaces/IRankEngine.sol";
import {IRewardManager} from "../Interfaces/IRewardManager.sol";

/// @title ProtocolEngine
/// @author Aurex Protocol
/// @notice Upgradeable business-logic layer for the Aurex protocol.
/// @dev
/// ## Purpose
/// The ProtocolEngine is the **only** contract that contains protocol business logic. It
/// performs every protocol calculation (daily ROI, direct referral, weekly reward, infinity
/// reward, reward withdrawals, and — in later phases — rank / leadership bonuses) and submits the
/// results to the RewardManager for accounting.
///
/// ## Strict boundaries
/// It **never** stores user investments (that is the InvestmentManager), **never** stores
/// reward balances (that is the RewardManager), **never** holds protocol funds (that is the
/// Treasury), **never** hardcodes parameters (they come from the ProtocolConfig) and **never**
/// tracks time (that is the ProtocolScheduler). It only reads state, computes amounts and
/// records them; withdrawals are paid by the RewardManager out of the Treasury.
///
/// ## Current phase
/// Daily ROI, direct referral, the weekly reward, the infinity reward and reward withdrawals are
/// fully implemented and production-ready. Every parameter is read from the ProtocolConfig, and
/// the ProtocolScheduler gates duplicate daily/weekly processing and supplies the protocol
/// day/week. Weekly is the first reward built on the generic periodic-reward framework
/// ({_processPeriodicReward} / {_calculatePeriodicReward}), which future periodic rewards
/// (monthly / seasonal / campaign) reuse without redesign; infinity is a referral-tree traversal
/// reward triggered on investment/upgrade. Rank / leadership qualification, liquidity and DEX
/// behaviour arrive in later phases without changing this structure.
///
/// ## Upgradeability
/// UUPS (ERC-1967). Deploy behind an `ERC1967Proxy`; only the owner may authorize an
/// upgrade. The reentrancy guard is the storage-namespaced OpenZeppelin v5 `ReentrancyGuard`
/// (no initializer required).
contract ProtocolEngine is Initializable, OwnableUpgradeable, ReentrancyGuard, UUPSUpgradeable, IProtocolEngine {
    /// @notice Basis-point denominator: 10,000 basis points == 100%. ROI percentages are in BPS.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Length of one ROI day, in seconds. Used to age a package from its start timestamp.
    uint256 private constant ROI_DAY = 1 days;

    /// @notice One whole ARX in base units, used for USDT-value -> ARX conversion
    ///         (`arx = usdtValue * ARX_UNIT / arxPriceUSDT`).
    uint256 private constant ARX_UNIT = 1e18;

    /// @notice The InvestmentManager consulted for user validation and package data. Owner-updatable.
    address public override investmentManager;

    /// @notice The RewardManager that rewards are submitted to. Owner-updatable.
    address public override rewardManager;

    /// @notice The Treasury address (stored for use by future calculations). Owner-updatable.
    address public override treasury;

    /// @notice The ProtocolConfig read for every ROI parameter (rate, cap, duration). Owner-updatable.
    address public override protocolConfig;

    /// @notice The ProtocolScheduler that gates duplicate processing and supplies the protocol day. Owner-updatable.
    address public override protocolScheduler;

    /// @notice Whether reward/ROI processing is paused at the module level (independent of the protocol
    ///         pause). Gates daily ROI, direct referral, weekly, infinity and withdrawals. Appended in
    ///         the operational phase.
    bool public processingPaused;

    /// @notice The InvestmentLifecycleEngine authorized to trigger investment-driven rewards
    ///         (referral / infinity / level). Owner-updatable. Appended in the security-hardening phase.
    /// @dev These triggers take a caller-supplied `investmentAmount`, so restricting them to the
    ///      orchestrator prevents an arbitrary caller from inflating rewards. Zero until wired; while
    ///      zero the restriction is inactive (see {_requireLifecycleCaller}). Deployment MUST wire it.
    address public override investmentLifecycleEngine;

    /// @notice The RankEngine consulted for ranks, level-income qualification and the rank-bonus
    ///         ledger. Owner-updatable. Appended in the spec-v2 phase.
    /// @dev Zero until wired; while zero every rank-driven reward (level income, infinity v2,
    ///      weekly rank bonus) is skipped — never computed from stale state.
    address public override rankEngine;

    /// @notice Reserved storage slots (8 used + 42 reserved = 50) for forward-compatible upgrades.
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[42] private __gap;

    /// @notice Emitted when reward/ROI processing is paused at the module level.
    event ProcessingPaused(address indexed account);

    /// @notice Emitted when reward/ROI processing is resumed at the module level.
    event ProcessingResumed(address indexed account);

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the engine and wires the protocol addresses.
    /// @dev Callable exactly once, on the proxy. All addresses must be non-zero.
    /// @param owner_ Protocol administrator.
    /// @param investmentManager_ InvestmentManager used for user validation and package data.
    /// @param rewardManager_ RewardManager that rewards are submitted to.
    /// @param treasury_ Treasury address (reserved for future calculations).
    /// @param protocolConfig_ ProtocolConfig read for every ROI parameter.
    /// @param protocolScheduler_ ProtocolScheduler that gates duplicate processing and supplies the protocol day.
    function initialize(
        address owner_,
        address investmentManager_,
        address rewardManager_,
        address treasury_,
        address protocolConfig_,
        address protocolScheduler_
    ) external initializer {
        if (
            owner_ == address(0) || investmentManager_ == address(0) || rewardManager_ == address(0)
                || treasury_ == address(0) || protocolConfig_ == address(0) || protocolScheduler_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __Ownable_init(owner_);

        investmentManager = investmentManager_;
        rewardManager = rewardManager_;
        treasury = treasury_;
        protocolConfig = protocolConfig_;
        protocolScheduler = protocolScheduler_;
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

    /// @notice Updates the RewardManager address.
    /// @param newRewardManager The new RewardManager address (non-zero).
    function setRewardManager(address newRewardManager) external onlyOwner {
        if (newRewardManager == address(0)) revert ZeroAddress();
        address previous = rewardManager;
        rewardManager = newRewardManager;
        emit RewardManagerUpdated(previous, newRewardManager);
    }

    /// @notice Updates the Treasury address.
    /// @param newTreasury The new Treasury address (non-zero).
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    /// @notice Updates the ProtocolConfig address.
    /// @param newProtocolConfig The new ProtocolConfig address (non-zero).
    function setProtocolConfig(address newProtocolConfig) external onlyOwner {
        if (newProtocolConfig == address(0)) revert ZeroAddress();
        address previous = protocolConfig;
        protocolConfig = newProtocolConfig;
        emit ProtocolConfigUpdated(previous, newProtocolConfig);
    }

    /// @notice Updates the ProtocolScheduler address.
    /// @param newProtocolScheduler The new ProtocolScheduler address (non-zero).
    function setProtocolScheduler(address newProtocolScheduler) external onlyOwner {
        if (newProtocolScheduler == address(0)) revert ZeroAddress();
        address previous = protocolScheduler;
        protocolScheduler = newProtocolScheduler;
        emit ProtocolSchedulerUpdated(previous, newProtocolScheduler);
    }

    /// @notice Updates the authorized InvestmentLifecycleEngine that may trigger investment-driven
    ///         rewards (referral / infinity / level).
    /// @param newLifecycleEngine The new lifecycle engine address (non-zero).
    function setInvestmentLifecycleEngine(address newLifecycleEngine) external onlyOwner {
        if (newLifecycleEngine == address(0)) revert ZeroAddress();
        address previous = investmentLifecycleEngine;
        investmentLifecycleEngine = newLifecycleEngine;
        emit InvestmentLifecycleEngineUpdated(previous, newLifecycleEngine);
    }

    /// @notice Updates the RankEngine consulted for ranks, level qualification and rank bonuses.
    /// @param newRankEngine The new RankEngine address (non-zero).
    function setRankEngine(address newRankEngine) external onlyOwner {
        if (newRankEngine == address(0)) revert ZeroAddress();
        address previous = rankEngine;
        rankEngine = newRankEngine;
        emit RankEngineUpdated(previous, newRankEngine);
    }

    /// @notice Pauses reward/ROI processing (daily ROI, referral, weekly, infinity, withdrawals) at
    ///         the module level.
    function pauseProcessing() external onlyOwner {
        if (processingPaused) revert AlreadyPaused();
        processingPaused = true;
        emit ProcessingPaused(msg.sender);
    }

    /// @notice Resumes reward/ROI processing at the module level.
    function resumeProcessing() external onlyOwner {
        if (!processingPaused) revert NotPaused();
        processingPaused = false;
        emit ProcessingResumed(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Processing
    // -------------------------------------------------------------------------

    /// @notice Calculates and submits `user`'s daily-ROI reward to the RewardManager, summed across
    ///         every one of the user's active investments (independent ROI streams).
    /// @dev Full daily-ROI flow:
    ///      1. Validate `user` is a registered protocol user (else revert {InvalidUser}).
    ///      2. Ask the ProtocolScheduler whether `user` may be processed for the current day; if not
    ///         (already processed today, or the scheduler is paused) return immediately so a day is
    ///         never processed twice. Gating is per-user-per-day, so one call processes all of the
    ///         user's investments together.
    ///      3. Iterate the user's investments. For each **active** one, compute its daily ROI —
    ///         capped by the per-investment maximum-ROI limit and aged from that investment's own
    ///         start time, all read from the ProtocolConfig; the result is zero for an expired or
    ///         capped-out stream, which is then marked completed, and zero (but still active) for a
    ///         stream younger than 24 hours — a stream's first payable day starts a full day after
    ///         its purchase. Streams are never merged: each has its own `roiEarned` accounting.
    ///      4. Persist the per-investment ROI and completion back to the InvestmentManager (storage
    ///         only) in a single batch, and record the summed reward with the RewardManager (only
    ///         when non-zero).
    ///      5. Mark the day processed on the ProtocolScheduler.
    ///      6. Emit a per-investment {InvestmentROIProcessed} for each accruing stream and the
    ///         aggregate {DailyROIProcessed} with the current package amount, total reward and day.
    /// @param user The registered user to process.
    function processDailyROI(address user) external override nonReentrant {
        _requireUser(user);
        _requireProcessingEnabled();

        IProtocolScheduler scheduler = IProtocolScheduler(protocolScheduler);
        if (!scheduler.canProcessDaily(user)) return;

        IInvestmentManager investment = IInvestmentManager(investmentManager);
        IInvestmentManager.Investment[] memory list = investment.getInvestments(user);
        uint256 len = list.length;

        uint256[] memory roiAmounts = new uint256[](len);
        bool[] memory completedFlags = new bool[](len);
        // ROI is paid in ARX, converted at the LIVE oracle price read once per run (a stream's
        // frozen price survives only as a fallback). Streams with no price at all stay
        // USDT-payable (legacy). The accumulators live in one memory struct to stay within the
        // EVM stack budget.
        RoiTotals memory totals;
        bool dirty;

        (uint256 dailyBps, uint256 maxBps, uint256 durationDays) = _roiParameters();
        totals.livePrice = IProtocolConfig(protocolConfig).arxPriceUSDT();

        for (uint256 i = 0; i < len; i++) {
            if (list[i].status != IInvestmentManager.InvestmentStatus.Active) continue;

            // Use this stream's frozen economics; fall back to the live config only when unset.
            // Rate, duration and cap stay frozen per stream — only the ARX conversion is live.
            (uint256 reward, bool completed) = _investmentROI(list[i], dailyBps, maxBps, durationDays);

            roiAmounts[i] = reward;
            completedFlags[i] = completed;
            _accumulateRoi(totals, reward, list[i].oraclePrice);
            if (reward != 0 || completed) dirty = true;
        }

        // Persist per-investment ROI/status (storage only) before recording the aggregate reward.
        if (dirty) {
            investment.recordInvestmentROIBatch(user, roiAmounts, completedFlags);
            for (uint256 i = 0; i < len; i++) {
                if (roiAmounts[i] != 0) emit InvestmentROIProcessed(user, i, list[i].amount, roiAmounts[i]);
            }
        }

        _submitDailyReward(user, totals.pricedValue, totals.pricedArx);
        _submitDailyReward(user, totals.unpricedValue, 0);
        scheduler.markDailyProcessed(user);

        (, uint256 packageAmount,,) = investment.getPackage(user);
        emit DailyROIProcessed(user, packageAmount, totals.pricedValue + totals.unpricedValue, scheduler.currentDay());
    }

    /// @notice Daily-ROI aggregation state (one memory struct keeps {processDailyROI} within the
    ///         EVM stack budget).
    /// @param livePrice The live ARX/USDT oracle price, read once per run. This is the conversion
    ///        rate applied to every priced stream.
    /// @param pricedValue Summed USDT value of streams with a price (paid in ARX).
    /// @param pricedArx Summed ARX payout for the priced streams.
    /// @param unpricedValue Summed USDT value of streams with no price (legacy USDT-payable).
    struct RoiTotals {
        uint256 livePrice;
        uint256 pricedValue;
        uint256 pricedArx;
        uint256 unpricedValue;
    }

    /// @dev Buckets one stream's reward into the priced (ARX-payable, converted at the LIVE oracle
    ///      price with the stream's frozen price as fallback) or unpriced (legacy USDT) totals.
    ///
    ///      Live-first pricing is deliberate. What the protocol owes a user is denominated in USDT
    ///      ("$1 of yield today"); the ARX price is only the unit conversion applied at payment
    ///      time, never a term of the deal. Converting at the frozen join-day price let an early
    ///      stream keep minting ARX at its original rate forever — after a 100x price move that
    ///      pays out 100x the credited USDT value from the treasury float, and it shortchanges the
    ///      user by the same factor when the price falls. The frozen price survives only as a
    ///      fallback for an unset live price, so a cleared config can never silently reprice a
    ///      stream to zero.
    function _accumulateRoi(RoiTotals memory totals, uint256 reward, uint256 frozenPrice) internal pure {
        if (reward == 0) return;
        uint256 price = totals.livePrice != 0 ? totals.livePrice : frozenPrice;
        if (price != 0) {
            totals.pricedValue += reward;
            totals.pricedArx += (reward * ARX_UNIT) / price;
        } else {
            totals.unpricedValue += reward;
        }
    }

    /// @notice Calculates the direct-referral reward for `investor`'s investment/upgrade and
    ///         credits it to `investor`'s direct referrer via the RewardManager.
    /// @dev Direct-referral flow, triggered when a new investment or package upgrade occurs
    ///      (never by daily-ROI processing):
    ///      1. Validate `investor` is a registered protocol user (else revert {InvalidUser}).
    ///      2. Read the direct referrer from the InvestmentManager and compute the reward from
    ///         `investmentAmount` and the ProtocolConfig percentage. When `investor` has no
    ///         referrer the reward is zero ({InvalidReferrer} terminal state).
    ///      3. Record the reward with the RewardManager only when it is non-zero, crediting the
    ///         referrer — never the investor.
    ///      4. Emit {ReferralRewardProcessed}. The call always returns successfully; it never
    ///         reverts for a missing referrer or a zero reward.
    /// @param investor The registered user whose investment/upgrade triggers the reward.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    function processReferralReward(address investor, uint256 investmentAmount) external override nonReentrant {
        _requireLifecycleCaller();
        _requireUser(investor);
        _requireProcessingEnabled();
        (address referrer, uint256 reward) = _referralReward(investor, investmentAmount);
        _submitReferralReward(referrer, reward);
        emit ReferralRewardProcessed(investor, referrer, investmentAmount, reward);
    }

    /// @notice Pays `user`'s currently-due weekly rank-bonus installments.
    /// @dev The spec-v2 weekly reward: rank achievements enqueue a fixed bonus split into equal
    ///      installments on a fixed interval (both frozen at achievement in the RankEngine
    ///      ledger). Flow:
    ///      1. Validate `user` is a registered protocol user (else revert {InvalidUser}).
    ///      2. Return when the weekly reward is disabled or no RankEngine is wired.
    ///      3. Collect every due installment from the RankEngine (which advances the ledger —
    ///         repeated calls can never double-pay; no scheduler gating is needed).
    ///      4. Record the collected amount with the RewardManager (only when non-zero) and emit
    ///         {WeeklyRankBonusProcessed}.
    /// @param user The registered user to process.
    function processWeeklyReward(address user) external override nonReentrant {
        _requireUser(user);
        _requireProcessingEnabled();

        if (!IProtocolConfig(protocolConfig).weeklyRewardEnabled()) return;
        address ranks = rankEngine;
        if (ranks == address(0)) return;

        uint256 due = IRankEngine(ranks).collectDueRankBonus(user);
        if (due == 0) return;

        _submitWeeklyReward(user, due);
        emit WeeklyRankBonusProcessed(user, due);
    }

    /// @notice Distributes the infinity bonus for `investor`'s investment/upgrade.
    /// @dev The spec-v2 infinity reward is rank-gated and unlimited-depth (bounded by the
    ///      configured traversal cap): the **nearest** upline achiever at or above
    ///      `infinityRankGate` earns `investmentAmount * infinityRewardPercentage / 10000`, and
    ///      the **next** achiever above them earns `infinityUplineShareBps` of that bonus. Flow:
    ///      1. Validate `investor` is a registered protocol user (else revert {InvalidUser}).
    ///      2. Return when the infinity reward is disabled, the rank gate is unset, or no
    ///         RankEngine is wired (fail-closed — never computed from stale state).
    ///      3. Traverse upward from the investor (bounded by `maxUplineTraversalDepth`),
    ///         consulting the RankEngine for each ancestor's rank; credit the first achiever
    ///         with the bonus and the second with the upline share, emitting
    ///         {InfinityRewardProcessed} (with the achiever's depth) for each credit.
    /// @param investor The registered user whose investment/upgrade triggers the distribution.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    function processInfinityReward(address investor, uint256 investmentAmount) external override nonReentrant {
        _requireLifecycleCaller();
        _requireUser(investor);
        _requireProcessingEnabled();

        (
            address achiever,
            uint256 achieverReward,
            uint256 achieverDepth,
            address uplineAchiever,
            uint256 uplineReward,
            uint256 uplineDepth
        ) = _infinityDistribution(investor, investmentAmount);
        if (achiever == address(0)) return;

        _submitInfinityReward(achiever, achieverReward);
        emit InfinityRewardProcessed(investor, achiever, investmentAmount, achieverReward, achieverDepth);

        if (uplineAchiever != address(0)) {
            _submitInfinityReward(uplineAchiever, uplineReward);
            emit InfinityRewardProcessed(investor, uplineAchiever, investmentAmount, uplineReward, uplineDepth);
        }
    }

    /// @notice Distributes level income for `investor`'s investment/upgrade to qualified uplines.
    /// @dev Level 1 is the direct referral, paid by {processReferralReward}; this walk starts
    ///      paying at level 2. Flow:
    ///      1. Validate `investor` is a registered protocol user (else revert {InvalidUser}).
    ///      2. Return when level income is disabled or no RankEngine is wired (fail-closed).
    ///      3. Walk up to `levelIncomeCount` ancestors. For each ancestor at level 2..N whose
    ///         unlocked-levels count (from the RankEngine qualification state) covers the level,
    ///         credit `investmentAmount * levelIncomeBps(level) / 10000` and emit
    ///         {LevelRewardProcessed}. Unqualified ancestors are skipped — the level is never
    ///         re-assigned ("no compression").
    /// @param investor The registered user whose investment/upgrade triggers the distribution.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    function processLevelReward(address investor, uint256 investmentAmount) external override nonReentrant {
        _requireLifecycleCaller();
        _requireUser(investor);
        _requireProcessingEnabled();

        IProtocolConfig config = IProtocolConfig(protocolConfig);
        if (!config.levelIncomeEnabled()) return;
        address ranks = rankEngine;
        if (ranks == address(0)) return;

        uint256 maxLevel = config.levelIncomeCount();
        IInvestmentManager investment = IInvestmentManager(investmentManager);

        address current = investor;
        for (uint256 level = 1; level <= maxLevel; level++) {
            address receiver = investment.getUser(current).referrer;
            if (receiver == address(0)) break;

            // Level 1 == the direct referral, paid by the referral module — never double-paid here.
            if (level >= 2 && IRankEngine(ranks).unlockedLevels(receiver) >= level) {
                uint256 reward = (investmentAmount * config.levelIncomeBps(level)) / BPS_DENOMINATOR;
                if (reward != 0) {
                    _submitLevelReward(receiver, reward);
                    emit LevelRewardProcessed(investor, receiver, level, investmentAmount, reward);
                }
            }

            current = receiver;
        }
    }

    // -------------------------------------------------------------------------
    // Withdrawal
    // -------------------------------------------------------------------------

    /// @notice Withdraws the caller's entire pending reward balance.
    /// @dev Withdrawal flow — the engine coordinates but **never** moves tokens itself:
    ///      1. Validate the caller is a registered protocol user (else revert {InvalidUser}).
    ///      2. Read the pending reward from the RewardManager and apply the withdrawal rules
    ///         (fee / minimum / maximum / cooldown framework — see {_previewWithdrawal}).
    ///      3. Revert {NothingToWithdraw} when there is nothing pending.
    ///      4. Ask the RewardManager to process the claim, which pays the user out of the
    ///         Treasury; a failure reverts {WithdrawalFailed}.
    ///      5. Emit {WithdrawalCompleted} with the gross/net amounts and the protocol day.
    function withdrawRewards() external override nonReentrant {
        address user = msg.sender;
        _requireUser(user);
        _requireProcessingEnabled();

        (uint256 gross,, uint256 net) = _previewWithdrawal(user);
        // ARX-denominated ROI is claimable even when the USDT balance is empty.
        if (gross == 0 && IRewardManager(rewardManager).pendingArxRewards(user) == 0) {
            revert NothingToWithdraw();
        }

        // The engine requests the RewardManager to process the claim; the RewardManager pays the
        // user from the Treasury. The engine itself never transfers tokens.
        try IRewardManager(rewardManager).processClaim(user) {}
        catch {
            revert WithdrawalFailed();
        }

        emit WithdrawalCompleted(user, gross, net, IProtocolScheduler(protocolScheduler).currentDay());
    }

    // -------------------------------------------------------------------------
    // Previews
    // -------------------------------------------------------------------------

    /// @inheritdoc IProtocolEngine
    /// @dev Performs the real, non-reverting daily-ROI calculation for `user`: the exact amount
    ///      {processDailyROI} would record if run now, honouring the duration and maximum-ROI cap.
    ///      Returns zero for an unregistered, expired or fully-capped package.
    function previewDailyROI(address user) external view override returns (uint256) {
        return _calculateDailyROI(user);
    }

    /// @inheritdoc IProtocolEngine
    /// @dev Performs the real, non-reverting direct-referral calculation: the exact amount
    ///      {processReferralReward} would credit to `user`'s referrer for an investment/upgrade
    ///      of `investmentAmount`. Returns zero when `user` has no referrer.
    function previewReferralReward(address user, uint256 investmentAmount)
        external
        view
        override
        returns (uint256 reward)
    {
        (, reward) = _referralReward(user, investmentAmount);
    }

    /// @inheritdoc IProtocolEngine
    /// @dev Non-reverting quote: the rank-bonus installments {processWeeklyReward} would pay if
    ///      run now. Returns zero when the weekly reward is disabled or no RankEngine is wired.
    function previewWeeklyReward(address user) external view override returns (uint256) {
        if (!IProtocolConfig(protocolConfig).weeklyRewardEnabled()) return 0;
        address ranks = rankEngine;
        if (ranks == address(0)) return 0;
        return IRankEngine(ranks).previewDueRankBonus(user);
    }

    /// @inheritdoc IProtocolEngine
    /// @dev Non-reverting quote of the infinity distribution {processInfinityReward} would make.
    function previewInfinityReward(address user, uint256 investmentAmount)
        external
        view
        override
        returns (address achiever, uint256 achieverReward, address uplineAchiever, uint256 uplineReward)
    {
        (achiever, achieverReward,, uplineAchiever, uplineReward,) = _infinityDistribution(user, investmentAmount);
    }

    /// @inheritdoc IProtocolEngine
    /// @dev Non-reverting withdrawal quote: the gross pending reward (from the RewardManager),
    ///      the withdrawal fee and the net payout. Mirrors exactly what {withdrawRewards} would
    ///      pay if run now.
    function previewWithdrawal(address user)
        external
        view
        override
        returns (uint256 grossReward, uint256 fee, uint256 netReward)
    {
        return _previewWithdrawal(user);
    }

    // -------------------------------------------------------------------------
    // Daily ROI calculation (production formula — all parameters from ProtocolConfig)
    // -------------------------------------------------------------------------

    /// @dev Sums `user`'s current daily-ROI reward across every active investment, reading the
    ///      investment history from the InvestmentManager. Each stream is aged from its own start
    ///      time and capped by its own `roiEarned`; streams are never merged. Never reverts; returns
    ///      zero for an unregistered user, an empty history, or when every stream is expired/capped.
    function _calculateDailyROI(address user) internal view returns (uint256 total) {
        IInvestmentManager.Investment[] memory list = IInvestmentManager(investmentManager).getInvestments(user);
        uint256 len = list.length;
        if (len == 0) return 0;

        (uint256 dailyBps, uint256 maxBps, uint256 durationDays) = _roiParameters();

        for (uint256 i = 0; i < len; i++) {
            if (list[i].status != IInvestmentManager.InvestmentStatus.Active) continue;
            (uint256 reward,) = _investmentROI(list[i], dailyBps, maxBps, durationDays);
            total += reward;
        }
    }

    /// @dev Computes a single investment's daily ROI using its **frozen** economics (falling back to
    ///      the passed live-config values when unset). Wraps {_effectiveRoiParams} and
    ///      {_investmentDailyROI} in one call frame so the per-user processing loop stays within the
    ///      EVM stack limit.
    /// @param inv The investment to process.
    /// @param liveDaily The live daily-ROI rate fallback, in basis points.
    /// @param liveMax The live lifetime-ROI-cap fallback, in basis points.
    /// @param liveDuration The live ROI-duration fallback, in days.
    /// @return reward The daily-ROI reward for this investment, in USDT base units.
    /// @return completed Whether this investment has finished accruing (expired or cap reached).
    function _investmentROI(
        IInvestmentManager.Investment memory inv,
        uint256 liveDaily,
        uint256 liveMax,
        uint256 liveDuration
    ) internal view returns (uint256 reward, bool completed) {
        (uint256 dBps, uint256 mBps, uint256 dur) = _effectiveRoiParams(inv, liveDaily, liveMax, liveDuration);
        return _investmentDailyROI(inv.amount, inv.startTime, inv.roiEarned, dBps, mBps, dur);
    }

    /// @dev Resolves the effective ROI parameters for a single investment: its **frozen** economics
    ///      when present (non-zero), otherwise the live ProtocolConfig fallback passed in. Freezing
    ///      makes later ProtocolConfig changes never retroactively alter a historical investment,
    ///      while the fallback preserves backward compatibility for investments created before a
    ///      ProtocolConfig was wired (frozen fields all zero).
    /// @param inv The investment whose economics are resolved.
    /// @param liveDaily The live daily-ROI rate fallback, in basis points.
    /// @param liveMax The live lifetime-ROI-cap fallback, in basis points.
    /// @param liveDuration The live ROI-duration fallback, in days.
    function _effectiveRoiParams(
        IInvestmentManager.Investment memory inv,
        uint256 liveDaily,
        uint256 liveMax,
        uint256 liveDuration
    ) internal pure returns (uint256 dailyBps, uint256 maxBps, uint256 durationDays) {
        dailyBps = inv.roiPercentage != 0 ? inv.roiPercentage : liveDaily;
        maxBps = inv.maxRoiPercentage != 0 ? inv.maxRoiPercentage : liveMax;
        durationDays = inv.roiDurationDays != 0 ? inv.roiDurationDays : liveDuration;
    }

    /// @dev Reads the three daily-ROI parameters from the ProtocolConfig in one place, so both the
    ///      processing loop and the preview loop stay config-driven and never hardcode a value.
    /// @return dailyBps The daily ROI rate, in basis points.
    /// @return maxBps The lifetime maximum-ROI cap, in basis points.
    /// @return durationDays The ROI accrual duration, in days.
    function _roiParameters() internal view returns (uint256 dailyBps, uint256 maxBps, uint256 durationDays) {
        IProtocolConfig config = IProtocolConfig(protocolConfig);
        return (config.dailyROIPercentage(), config.maximumROIPercentage(), config.roiDurationDays());
    }

    /// @dev Pure per-investment daily-ROI policy over pre-read investment data and pre-read config
    ///      parameters. Enforces the 24-hour maturation, the accrual duration and the
    ///      per-investment lifetime maximum-ROI cap; it never hardcodes a percentage, duration or
    ///      limit. The cap and duration are config-driven (never frozen at purchase), preserving
    ///      the protocol's tunability.
    ///
    ///      - Maturation: a stream earns nothing until 24 hours have passed since its purchase
    ///        (day index 0). The keeper runs once per protocol day, so a purchase minutes before a
    ///        run can never capture a full day's ROI; the first payable day is index 1 — the first
    ///        run at least 24 hours after purchase — and it counts as day 1 of the duration.
    ///      - Duration: the accrual window is day indexes `[1, durationDays]` (shifted one day for
    ///        the maturation day, so a stream still pays exactly `durationDays` daily credits).
    ///        Once `daysSinceStart > durationDays` the stream is expired ({PackageExpired}
    ///        terminal state), the reward is zero and the stream is completed.
    ///      - Rate: `reward = amount * dailyBps / 10000`.
    ///      - Cap: `roiEarned + reward` may never exceed `amount * maxBps / 10000`. When it would,
    ///        the reward is reduced to the remaining headroom and the stream is completed; once no
    ///        headroom remains the reward is zero ({MaximumROIReached} terminal state).
    /// @param amount The investment principal, in USDT base units.
    /// @param startTime The timestamp this investment's ROI stream started.
    /// @param roiEarned The ROI already recorded against this investment, in USDT base units.
    /// @param dailyBps The daily ROI rate, in basis points.
    /// @param maxBps The lifetime maximum-ROI cap, in basis points.
    /// @param durationDays The ROI accrual duration, in days.
    /// @return reward The daily-ROI reward to record for this investment, in USDT base units.
    /// @return completed Whether this investment has finished accruing (expired or cap reached).
    function _investmentDailyROI(
        uint256 amount,
        uint256 startTime,
        uint256 roiEarned,
        uint256 dailyBps,
        uint256 maxBps,
        uint256 durationDays
    ) internal view returns (uint256 reward, bool completed) {
        // Maturation: no ROI during the first 24 hours after purchase (day index 0). The stream
        // stays Active — its first payable day is index 1, so a purchase minutes before a keeper
        // run never captures a full day's ROI.
        uint256 daysSinceStart = (block.timestamp - startTime) / ROI_DAY;
        if (daysSinceStart == 0) return (0, false);

        // Duration: the accrual window is day indexes [1, durationDays] — shifted one day for the
        // maturation day, so the stream still pays exactly `durationDays` daily credits.
        if (daysSinceStart > durationDays) return (0, true);

        // Cap: this stream's own accrued ROI plus this reward may never exceed its maximum.
        uint256 maximumReward = (amount * maxBps) / BPS_DENOMINATOR;
        if (roiEarned >= maximumReward) return (0, true);

        // Rate: principal times the daily percentage, in basis points.
        reward = (amount * dailyBps) / BPS_DENOMINATOR;

        uint256 remaining = maximumReward - roiEarned;
        if (reward >= remaining) {
            reward = remaining;
            completed = true; // reaching the lifetime cap completes the stream
        }
    }

    // -------------------------------------------------------------------------
    // Direct referral calculation (production formula — percentage from ProtocolConfig)
    // -------------------------------------------------------------------------

    /// @dev Resolves `investor`'s direct referrer and the referral reward due on `investmentAmount`.
    ///      The referral relationship is read **only** from the InvestmentManager (never
    ///      duplicated here) and the percentage **only** from the ProtocolConfig (never
    ///      hardcoded). Returns a zero referrer and zero reward when `investor` has no referrer
    ///      (the referral-tree root); never reverts.
    /// @param investor The user whose investment/upgrade generates the reward.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    /// @return referrer The investor's direct referrer (zero when none).
    /// @return reward `investmentAmount * directReferralPercentage / 10000`, or zero when there
    ///         is no referrer.
    function _referralReward(address investor, uint256 investmentAmount)
        internal
        view
        returns (address referrer, uint256 reward)
    {
        referrer = IInvestmentManager(investmentManager).getUser(investor).referrer;
        if (referrer == address(0)) return (address(0), 0);

        reward = (investmentAmount * IProtocolConfig(protocolConfig).directReferralPercentage()) / BPS_DENOMINATOR;
    }

    // -------------------------------------------------------------------------
    // Withdrawal rules framework
    // -------------------------------------------------------------------------

    /// @dev Builds a withdrawal quote for `user`: gross pending reward, fee and net payout.
    ///      The withdrawal rules (fee, and in later phases minimum / maximum / cooldown) form a
    ///      framework designed to be sourced from the ProtocolConfig once it exposes withdrawal
    ///      parameters; enabling them then slots into this quote and {withdrawRewards} without
    ///      redesigning the flow. Until then the phase defaults apply — fee 0, minimum 0, maximum
    ///      unlimited, cooldown disabled — so `net == gross`. Never reverts.
    /// @param user The user to quote.
    /// @return gross The user's total pending reward, in USDT base units.
    /// @return fee The withdrawal fee to deduct, in USDT base units.
    /// @return net The amount payable to the user after the fee, in USDT base units.
    function _previewWithdrawal(address user) internal view returns (uint256 gross, uint256 fee, uint256 net) {
        gross = IRewardManager(rewardManager).pendingRewards(user);
        fee = (gross * _withdrawalFeeBps()) / BPS_DENOMINATOR;
        net = gross - fee;
    }

    /// @dev The current withdrawal fee, in basis points. Single source for the fee rule: a later
    ///      phase points this at `ProtocolConfig` (e.g. a `withdrawalFeePercentage`) without
    ///      touching the withdrawal flow. The phase default is 0 (no fee) — the empty named-return
    ///      body yields zero.
    function _withdrawalFeeBps() internal pure returns (uint256 bps) {}

    // -------------------------------------------------------------------------
    // Infinity distribution (spec v2 — rank-gated, shared calculation for process/preview)
    // -------------------------------------------------------------------------

    /// @dev Resolves the spec-v2 infinity distribution for a deposit of `investmentAmount` by
    ///      `investor`: the nearest upline achiever at or above the configured rank gate (the
    ///      bonus receiver) and the next achiever above them (the upline-share receiver). All
    ///      parameters come from the ProtocolConfig; ranks come from the RankEngine; the referral
    ///      chain from the InvestmentManager. All-zero when the reward is disabled, the gate or
    ///      RankEngine is unwired, or no achiever exists within the traversal bound. Never reverts.
    function _infinityDistribution(address investor, uint256 investmentAmount)
        internal
        view
        returns (
            address achiever,
            uint256 achieverReward,
            uint256 achieverDepth,
            address uplineAchiever,
            uint256 uplineReward,
            uint256 uplineDepth
        )
    {
        IProtocolConfig config = IProtocolConfig(protocolConfig);
        if (!config.infinityRewardEnabled()) return (address(0), 0, 0, address(0), 0, 0);
        uint256 rankGate = config.infinityRankGate();
        address ranks = rankEngine;
        if (rankGate == 0 || ranks == address(0)) return (address(0), 0, 0, address(0), 0, 0);

        uint256 bonus = (investmentAmount * config.infinityRewardPercentage()) / BPS_DENOMINATOR;
        if (bonus == 0) return (address(0), 0, 0, address(0), 0, 0);

        IInvestmentManager investment = IInvestmentManager(investmentManager);
        uint256 maxDepth = config.maxUplineTraversalDepth();

        address current = investor;
        for (uint256 depth = 1; depth <= maxDepth; depth++) {
            address ancestor = investment.getUser(current).referrer;
            if (ancestor == address(0)) break;

            if (IRankEngine(ranks).rankOf(ancestor) >= rankGate) {
                if (achiever == address(0)) {
                    achiever = ancestor;
                    achieverReward = bonus;
                    achieverDepth = depth;
                } else {
                    uplineAchiever = ancestor;
                    uplineReward = (bonus * config.infinityUplineShareBps()) / BPS_DENOMINATOR;
                    uplineDepth = depth;
                    break;
                }
            }

            current = ancestor;
        }
    }

    // -------------------------------------------------------------------------
    // Reward submission (records a non-zero amount; reverts on failure)
    // -------------------------------------------------------------------------

    /// @dev Records a daily-ROI reward (`amount` = USDT value, `arxAmount` = ARX payout; zero
    ///      `arxAmount` = legacy USDT-payable path). No-op when `amount` is zero.
    function _submitDailyReward(address user, uint256 amount, uint256 arxAmount) internal {
        if (amount == 0) return;
        try IRewardManager(rewardManager).recordDailyReward(user, amount, arxAmount) {}
        catch {
            revert CalculationFailed();
        }
    }

    /// @dev Records a referral reward. No-op when `amount` is zero.
    function _submitReferralReward(address user, uint256 amount) internal {
        if (amount == 0) return;
        try IRewardManager(rewardManager).recordReferralReward(user, amount) {}
        catch {
            revert CalculationFailed();
        }
    }

    /// @dev Records a weekly reward. No-op when `amount` is zero.
    function _submitWeeklyReward(address user, uint256 amount) internal {
        if (amount == 0) return;
        try IRewardManager(rewardManager).recordWeeklyReward(user, amount) {}
        catch {
            revert CalculationFailed();
        }
    }

    /// @dev Records an infinity reward. No-op when `amount` is zero.
    function _submitInfinityReward(address user, uint256 amount) internal {
        if (amount == 0) return;
        try IRewardManager(rewardManager).recordInfinityReward(user, amount) {}
        catch {
            revert CalculationFailed();
        }
    }

    /// @dev Records a level-income reward. No-op when `amount` is zero.
    function _submitLevelReward(address user, uint256 amount) internal {
        if (amount == 0) return;
        try IRewardManager(rewardManager).recordLevelReward(user, amount) {}
        catch {
            revert CalculationFailed();
        }
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Reverts {InvalidUser} unless `user` is a registered protocol user.
    function _requireUser(address user) private view {
        if (!IInvestmentManager(investmentManager).isRegistered(user)) revert InvalidUser();
    }

    /// @dev Reverts when processing is paused — at the module level ({ModuleIsPaused}) or protocol-wide
    ///      ({ProtocolIsPaused}, read from the ProtocolConfig). No calculation or accounting changes.
    function _requireProcessingEnabled() private view {
        if (processingPaused) revert ModuleIsPaused();
        if (IProtocolConfig(protocolConfig).protocolPaused()) revert ProtocolIsPaused();
    }

    /// @dev Reverts {UnauthorizedCaller} unless the caller is the wired InvestmentLifecycleEngine.
    ///      Investment-driven rewards take a caller-supplied amount, so only the orchestrator may
    ///      trigger them (on a real, funded investment). **Fail-closed:** while the lifecycle engine
    ///      is unset the guard reverts for *every* caller, so these amount-backed reward triggers
    ///      cannot be abused during the deployment-wiring window — they stay disabled until the owner
    ///      wires the orchestrator (see {setInvestmentLifecycleEngine}). The permissionless keeper
    ///      flow for the amount-derived rewards (daily ROI, weekly) is unaffected: those paths are not
    ///      routed through this guard.
    function _requireLifecycleCaller() private view {
        if (msg.sender != investmentLifecycleEngine) revert UnauthorizedCaller();
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
