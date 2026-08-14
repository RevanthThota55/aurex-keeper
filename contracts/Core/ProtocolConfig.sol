// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {AlreadyPaused, NotPaused, ZeroAddress} from "../Errors/CommonErrors.sol";
import {
    ArxPriceDeviationExceeded,
    InvalidAllocation,
    InvalidConfiguration,
    InvalidPercentage,
    UnauthorizedPriceUpdater
} from "../Errors/ProtocolConfigErrors.sol";
import {IProtocolConfig} from "../Interfaces/IProtocolConfig.sol";

/// @title ProtocolConfig
/// @author Aurex Protocol
/// @notice The single source of truth for every configurable protocol parameter.
/// @dev
/// ## Purpose
/// Every percentage, limit, duration, bonus toggle and protocol rule lives here. The
/// ProtocolEngine (and any future module) reads its business parameters from this contract
/// so calculation logic never hardcodes values — parameters can be tuned via upgrade-free
/// configuration updates.
///
/// ## Boundaries
/// This contract only **stores** and **validates** configuration. It performs **no** protocol
/// calculations. Percentages are expressed in basis points ({BPS_DENOMINATOR} = 100%).
///
/// ## Upgradeability
/// UUPS (ERC-1967). Deploy behind an `ERC1967Proxy`; only the owner may authorize an upgrade
/// or update any parameter.
contract ProtocolConfig is Initializable, OwnableUpgradeable, UUPSUpgradeable, IProtocolConfig {
    /// @notice Basis-point denominator: 10,000 basis points == 100%.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // --- ROI configuration ---------------------------------------------------

    /// @inheritdoc IProtocolConfig
    uint256 public override dailyROIPercentage;
    /// @inheritdoc IProtocolConfig
    uint256 public override maximumROIPercentage;
    /// @inheritdoc IProtocolConfig
    uint256 public override roiDurationDays;

    // --- Investment rules ----------------------------------------------------

    /// @inheritdoc IProtocolConfig
    uint256 public override minimumInvestment;
    /// @inheritdoc IProtocolConfig
    uint256 public override investmentStep;
    /// @inheritdoc IProtocolConfig
    uint256 public override maximumInvestment;

    // --- Referral rules ------------------------------------------------------

    /// @inheritdoc IProtocolConfig
    uint256 public override directReferralPercentage;
    /// @inheritdoc IProtocolConfig
    uint256 public override maximumReferralDepth;

    // --- Weekly reward configuration -----------------------------------------

    /// @inheritdoc IProtocolConfig
    bool public override weeklyRewardEnabled;
    /// @inheritdoc IProtocolConfig
    uint256 public override weeklyRewardPercentage;

    // --- Infinity reward configuration ---------------------------------------

    /// @inheritdoc IProtocolConfig
    bool public override infinityRewardEnabled;
    /// @inheritdoc IProtocolConfig
    uint256 public override infinityRewardPercentage;

    // --- Liquidity / allocation rules ----------------------------------------

    /// @inheritdoc IProtocolConfig
    uint256 public override liquidityAllocationPercentage;
    /// @inheritdoc IProtocolConfig
    uint256 public override treasuryAllocationPercentage;
    /// @inheritdoc IProtocolConfig
    uint256 public override rewardAllocationPercentage;

    // --- Protocol status -----------------------------------------------------

    /// @inheritdoc IProtocolConfig
    bool public override protocolPaused;

    // --- Automatic-reinvestment configuration (appended in the re-topup phase) ---

    /// @inheritdoc IProtocolConfig
    bool public override autoReinvestEnabled;
    /// @inheritdoc IProtocolConfig
    uint256 public override minimumReinvestAmount;
    /// @inheritdoc IProtocolConfig
    uint256 public override maximumReinvestAmount;
    /// @inheritdoc IProtocolConfig
    uint256 public override reinvestPercentage;
    /// @inheritdoc IProtocolConfig
    uint256 public override reinvestCooldown;

    // --- DEX / liquidity configuration (appended in the PancakeSwap phase) ----

    /// @inheritdoc IProtocolConfig
    address public override dexRouter;
    /// @inheritdoc IProtocolConfig
    address public override dexFactory;
    /// @inheritdoc IProtocolConfig
    uint256 public override arxPriceUSDT;
    /// @inheritdoc IProtocolConfig
    uint256 public override maxSlippageBps;

    // --- Business-rule earnings cap & renewal (appended in the corrective phase) ---

    /// @inheritdoc IProtocolConfig
    /// @dev Slot appended after {maxSlippageBps}; the storage gap shrinks by one to preserve layout.
    uint256 public override maxTotalEarningsPercentage;

    /// @inheritdoc IProtocolConfig
    /// @dev Slot appended after {maxTotalEarningsPercentage}; the storage gap shrinks by one.
    uint256 public override weeklyRenewalPeriodDays;

    // --- Level income (appended in the spec-v2 phase) --------------------------

    /// @inheritdoc IProtocolConfig
    bool public override levelIncomeEnabled;

    /// @notice Level-income rates per level, in basis points, 0-indexed (index 0 = level 1).
    /// @dev Level 1's slot is informational — the direct-referral module pays level 1; the
    ///      level-income walk pays levels 2..N. Read via {levelIncomeBps}/{levelIncomeCount}.
    uint256[] private _levelIncomeBps;

    /// @inheritdoc IProtocolConfig
    uint256 public override levelUnlockBand1Deposit;
    /// @inheritdoc IProtocolConfig
    uint256 public override levelUnlockBand2Deposit;
    /// @inheritdoc IProtocolConfig
    uint256 public override levelUnlockBand3Deposit;
    /// @inheritdoc IProtocolConfig
    uint256 public override levelUnlockL1Count;
    /// @inheritdoc IProtocolConfig
    uint256 public override levelUnlockL2Count;

    // --- Rank ladder & weekly rank bonus (appended in the spec-v2 phase) -------

    /// @notice Matching-business threshold per rank, USDT base units, 0-indexed (index 0 = V1).
    /// @dev Zero marks a leg-criteria rank (see {_rankLegRequirement}). Read via
    ///      {rankMatchingThreshold}/{rankCount}.
    uint256[] private _rankMatchingThreshold;

    /// @notice Total achievement bonus per rank, USDT base units, 0-indexed (index 0 = V1).
    uint256[] private _rankBonusTotal;

    /// @notice Leg-criteria requirement per rank, 0-indexed: the lower rank that must appear in
    ///         {rankLegCount} distinct legs. Zero for matching-threshold ranks.
    uint256[] private _rankLegRequirement;

    /// @inheritdoc IProtocolConfig
    uint256 public override rankLegCount;
    /// @inheritdoc IProtocolConfig
    uint256 public override rankBonusInstallments;
    /// @inheritdoc IProtocolConfig
    uint256 public override rankBonusInterval;

    // --- Infinity v2 & traversal (appended in the spec-v2 phase) ---------------

    /// @inheritdoc IProtocolConfig
    uint256 public override infinityRankGate;
    /// @inheritdoc IProtocolConfig
    uint256 public override infinityUplineShareBps;
    /// @inheritdoc IProtocolConfig
    uint256 public override maxUplineTraversalDepth;

    // --- Weekly renewal, cap boost & daily limits (appended in the spec-v2.1 phase) ---

    /// @inheritdoc IProtocolConfig
    uint256 public override rankRenewalLegBps;
    /// @inheritdoc IProtocolConfig
    uint256 public override capBoostRank;
    /// @inheritdoc IProtocolConfig
    uint256 public override maxTotalEarningsBoostedPercentage;

    /// @notice Daily deposit limit per rank, USDT base units, indexed by rank (0 = unranked).
    /// @dev Ranks beyond the last index clamp to the final entry. Read via
    ///      {rankDailyDepositLimit}/{rankDailyDepositLimitCount}; empty = limits disabled.
    uint256[] private _rankDailyDepositLimit;

    // --- Live ARX pricing: delegated updater & deviation guard (appended in the live-pricing phase) ---

    /// @notice The account allowed to push routine ARX price updates besides the owner.
    /// @dev APPENDED after {_rankDailyDepositLimit}, never inserted — the storage gap shrinks by
    ///      two to absorb this and {arxPriceMaxDeviationBps} without shifting any slot declared
    ///      above. Packs with {_arxPriceUpdatedAt} into one slot (20 + 8 = 28 bytes). Read via
    ///      {arxPriceUpdater}.
    address private _arxPriceUpdater;

    /// @notice Unix timestamp of the last ARX price write, by either path.
    /// @dev `uint64` so it shares a slot with {_arxPriceUpdater}. Read via {arxPriceUpdatedAt}.
    uint64 private _arxPriceUpdatedAt;

    /// @inheritdoc IProtocolConfig
    uint256 public override arxPriceMaxDeviationBps;

    // --- Deposit-funded buyback (appended in the buyback phase) ----------------

    /// @inheritdoc IProtocolConfig
    /// @dev APPENDED after {arxPriceMaxDeviationBps}, consuming the final reserved gap slot. The
    ///      gap is now exhausted: any further state must be appended after this declaration and the
    ///      layout re-verified against the deployed implementation before upgrading.
    uint256 public override buybackPercentage;

    /// @inheritdoc IProtocolConfig
    /// @dev APPENDED after {buybackPercentage}, in the gap block opened below it.
    uint256 public override buybackFloatShareBps;

    /// @notice Reserved storage slots. The original 50-slot reservation is now fully consumed, so
    ///         this opens a fresh block appended AFTER every slot declared above.
    /// @dev Appending a new gap rather than shrinking the old one is what keeps the layout stable:
    ///      {buybackPercentage} took the last slot of the original reservation, and these slots sit
    ///      beyond it. See
    ///      https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[19] private __gap;

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the configuration and assigns ownership.
    /// @dev Callable exactly once, on the proxy. All parameters start at their zero defaults;
    ///      the owner sets them via the update functions before the protocol goes live.
    /// @param owner_ Protocol administrator; the sole account able to update configuration.
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
    }

    // -------------------------------------------------------------------------
    // ROI configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the ROI configuration.
    /// @param dailyROIPercentage_ Daily ROI in basis points (`1..BPS_DENOMINATOR`).
    /// @param maximumROIPercentage_ Cumulative ROI cap in basis points (`>= daily`).
    /// @param roiDurationDays_ ROI accrual duration in days (non-zero).
    function setROIConfig(uint256 dailyROIPercentage_, uint256 maximumROIPercentage_, uint256 roiDurationDays_)
        external
        onlyOwner
    {
        if (dailyROIPercentage_ == 0 || dailyROIPercentage_ > BPS_DENOMINATOR) revert InvalidPercentage();
        if (maximumROIPercentage_ < dailyROIPercentage_ || roiDurationDays_ == 0) revert InvalidConfiguration();

        dailyROIPercentage = dailyROIPercentage_;
        maximumROIPercentage = maximumROIPercentage_;
        roiDurationDays = roiDurationDays_;

        emit ROIConfigUpdated(dailyROIPercentage_, maximumROIPercentage_, roiDurationDays_);
    }

    // -------------------------------------------------------------------------
    // Investment rules
    // -------------------------------------------------------------------------

    /// @notice Updates the investment rules. {InvestmentManager} enforces all three on every
    ///         invest / upgrade / re-topup, so these are the live deposit bounds.
    /// @dev The minimum must itself be a whole multiple of the step; otherwise the stated minimum
    ///      would be un-depositable and the true floor would silently be the next multiple above it.
    /// @param minimumInvestment_ Minimum investment in USDT base units (non-zero, a whole multiple
    ///        of `investmentStep_`).
    /// @param investmentStep_ Investment step in USDT base units (non-zero).
    /// @param maximumInvestment_ Maximum investment in USDT base units (`>= minimum`).
    function setInvestmentRules(uint256 minimumInvestment_, uint256 investmentStep_, uint256 maximumInvestment_)
        external
        onlyOwner
    {
        if (
            minimumInvestment_ == 0 || investmentStep_ == 0 || maximumInvestment_ < minimumInvestment_
                || minimumInvestment_ % investmentStep_ != 0
        ) {
            revert InvalidConfiguration();
        }

        minimumInvestment = minimumInvestment_;
        investmentStep = investmentStep_;
        maximumInvestment = maximumInvestment_;

        emit InvestmentRulesUpdated(minimumInvestment_, investmentStep_, maximumInvestment_);
    }

    // -------------------------------------------------------------------------
    // Referral rules
    // -------------------------------------------------------------------------

    /// @notice Updates the referral rules.
    /// @param directReferralPercentage_ Direct referral commission in basis points (`<= 100%`).
    /// @param maximumReferralDepth_ Maximum referral depth (non-zero).
    function setReferralRules(uint256 directReferralPercentage_, uint256 maximumReferralDepth_) external onlyOwner {
        if (directReferralPercentage_ > BPS_DENOMINATOR) revert InvalidPercentage();
        if (maximumReferralDepth_ == 0) revert InvalidConfiguration();

        directReferralPercentage = directReferralPercentage_;
        maximumReferralDepth = maximumReferralDepth_;

        emit ReferralRulesUpdated(directReferralPercentage_, maximumReferralDepth_);
    }

    // -------------------------------------------------------------------------
    // Weekly reward configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the weekly-reward configuration.
    /// @param enabled Whether the weekly reward is enabled.
    /// @param percentage Weekly reward rate in basis points (`<= 100%`).
    function setWeeklyReward(bool enabled, uint256 percentage) external onlyOwner {
        if (percentage > BPS_DENOMINATOR) revert InvalidPercentage();

        weeklyRewardEnabled = enabled;
        weeklyRewardPercentage = percentage;

        emit WeeklyRewardUpdated(enabled, percentage);
    }

    // -------------------------------------------------------------------------
    // Infinity reward configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the infinity-reward configuration.
    /// @param enabled Whether the infinity reward is enabled.
    /// @param percentage Infinity reward rate in basis points (`<= 100%`).
    function setInfinityReward(bool enabled, uint256 percentage) external onlyOwner {
        if (percentage > BPS_DENOMINATOR) revert InvalidPercentage();

        infinityRewardEnabled = enabled;
        infinityRewardPercentage = percentage;

        emit InfinityRewardUpdated(enabled, percentage);
    }

    // -------------------------------------------------------------------------
    // Liquidity / allocation rules
    // -------------------------------------------------------------------------

    /// @notice Updates the allocation percentages. They must sum to exactly 100%.
    /// @param liquidity Liquidity allocation in basis points.
    /// @param treasuryShare Treasury allocation in basis points.
    /// @param reward Reward allocation in basis points.
    function setAllocations(uint256 liquidity, uint256 treasuryShare, uint256 reward) external onlyOwner {
        if (liquidity + treasuryShare + reward != BPS_DENOMINATOR) revert InvalidAllocation();

        liquidityAllocationPercentage = liquidity;
        treasuryAllocationPercentage = treasuryShare;
        rewardAllocationPercentage = reward;

        emit AllocationsUpdated(liquidity, treasuryShare, reward);
    }

    // -------------------------------------------------------------------------
    // Automatic-reinvestment configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the automatic-reinvestment configuration.
    /// @dev A zero minimum/maximum means that bound is not enforced; when both are non-zero the
    ///      maximum must be at least the minimum. The percentage is capped at 100%.
    /// @param enabled Whether automatic reinvestment is enabled protocol-wide.
    /// @param minAmount Minimum reinvest amount in USDT base units (zero = unbounded).
    /// @param maxAmount Maximum reinvest amount in USDT base units (zero = unbounded).
    /// @param percentage Share of eligible rewards earmarked for reinvestment, in basis points (`<= 100%`).
    /// @param cooldown Minimum time between a user's automatic reinvestments, in seconds.
    function setAutoReinvestConfig(
        bool enabled,
        uint256 minAmount,
        uint256 maxAmount,
        uint256 percentage,
        uint256 cooldown
    ) external onlyOwner {
        if (percentage > BPS_DENOMINATOR) revert InvalidPercentage();
        if (minAmount != 0 && maxAmount != 0 && maxAmount < minAmount) revert InvalidConfiguration();

        autoReinvestEnabled = enabled;
        minimumReinvestAmount = minAmount;
        maximumReinvestAmount = maxAmount;
        reinvestPercentage = percentage;
        reinvestCooldown = cooldown;

        emit AutoReinvestConfigUpdated(enabled, minAmount, maxAmount, percentage, cooldown);
    }

    // -------------------------------------------------------------------------
    // DEX / liquidity configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the DEX router address used for liquidity provisioning.
    /// @param newRouter The new router address (non-zero).
    function setDexRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        address previous = dexRouter;
        dexRouter = newRouter;
        emit RouterUpdated(previous, newRouter);
    }

    /// @notice Updates the DEX factory address used to create/look up the ARX/USDT pair.
    /// @param newFactory The new factory address (non-zero).
    function setDexFactory(address newFactory) external onlyOwner {
        if (newFactory == address(0)) revert ZeroAddress();
        address previous = dexFactory;
        dexFactory = newFactory;
        emit FactoryUpdated(previous, newFactory);
    }

    /// @notice Sets the ARX price, without bound. Owner-only administrative re-pricing.
    /// @dev The unbounded path, for deliberate moves the owner intends: the initial launch price,
    ///      a re-denomination, or recovering from a stalled feed. Routine per-day updates should
    ///      go through {updateArxPrice}, which is bounded and can be delegated to a hot key.
    ///      This price is read live by {ProtocolEngine.processDailyROI} to convert each day's
    ///      USDT-denominated ROI into ARX, so it is a payout-affecting parameter, not merely a
    ///      liquidity-sizing one.
    /// @param newArxPriceUSDT The new price, in USDT base units per whole ARX (non-zero).
    function setArxPrice(uint256 newArxPriceUSDT) external onlyOwner {
        if (newArxPriceUSDT == 0) revert InvalidConfiguration();
        uint256 previous = arxPriceUSDT;
        arxPriceUSDT = newArxPriceUSDT;
        _arxPriceUpdatedAt = uint64(block.timestamp);
        emit ArxPriceUpdated(previous, newArxPriceUSDT);
    }

    /// @notice Pushes a routine ARX price update, bounded by {arxPriceMaxDeviationBps}.
    /// @dev Callable by the owner or by {arxPriceUpdater} — the keeper's hot wallet, so the daily
    ///      run can refresh the price without holding the owner key.
    ///
    ///      The bound is what makes delegating safe. Because {ProtocolEngine} converts ROI at the
    ///      live price, an unbounded feed would let a stolen updater key (or a momentarily
    ///      manipulated DEX spot price, on a thin pool) crash the price just before the daily run
    ///      and mint an arbitrary multiple of the ARX actually owed. Capping each move to a
    ///      fraction of the current price bounds that to the same fraction, and the attacker has
    ///      to hold the price down across many days to compound it — at which point the move is
    ///      visible and the owner can intervene.
    ///
    ///      A zero bound disables the check, which is only appropriate before the first price is
    ///      set. The first write (`previous == 0`) is always unbounded — there is no baseline to
    ///      deviate from.
    /// @param newArxPriceUSDT The new price, in USDT base units per whole ARX (non-zero).
    function updateArxPrice(uint256 newArxPriceUSDT) external {
        if (msg.sender != owner() && msg.sender != _arxPriceUpdater) revert UnauthorizedPriceUpdater();
        if (newArxPriceUSDT == 0) revert InvalidConfiguration();

        uint256 previous = arxPriceUSDT;
        uint256 maxDeviation = arxPriceMaxDeviationBps;
        if (previous != 0 && maxDeviation != 0) {
            uint256 delta = newArxPriceUSDT > previous ? newArxPriceUSDT - previous : previous - newArxPriceUSDT;
            // delta / previous > maxDeviation / BPS, cross-multiplied to avoid truncation.
            if (delta * BPS_DENOMINATOR > previous * maxDeviation) revert ArxPriceDeviationExceeded();
        }

        arxPriceUSDT = newArxPriceUSDT;
        _arxPriceUpdatedAt = uint64(block.timestamp);
        emit ArxPriceUpdated(previous, newArxPriceUSDT);
    }

    /// @notice Sets the account allowed to push bounded ARX price updates.
    /// @param newUpdater The delegated updater; the zero address disables delegation, leaving the
    ///        owner as the only price source.
    function setArxPriceUpdater(address newUpdater) external onlyOwner {
        address previous = _arxPriceUpdater;
        _arxPriceUpdater = newUpdater;
        emit ArxPriceUpdaterUpdated(previous, newUpdater);
    }

    /// @notice Sets how far a single {updateArxPrice} call may move the price.
    /// @param newMaxDeviationBps The bound, in basis points of the current price (`<= 100%`).
    ///        `0` disables the bound.
    function setArxPriceMaxDeviation(uint256 newMaxDeviationBps) external onlyOwner {
        if (newMaxDeviationBps > BPS_DENOMINATOR) revert InvalidPercentage();
        uint256 previous = arxPriceMaxDeviationBps;
        arxPriceMaxDeviationBps = newMaxDeviationBps;
        emit ArxPriceMaxDeviationUpdated(previous, newMaxDeviationBps);
    }

    /// @notice Sets the share of every deposit routed into buying ARX on the open market and pairing
    ///         the proceeds into liquidity.
    /// @dev This is the protocol's only structural source of ARX buy pressure. Without it the token
    ///      flow is one-directional — the Treasury pays ARX out as ROI and holders sell it — and the
    ///      float drains monotonically against a fixed supply. Routing a slice of deposits back
    ///      through the market both bids the token and deepens the pool it is quoted on.
    ///
    ///      Bounded jointly with {treasuryAllocationPercentage}: the company share and the buyback
    ///      share are both taken from the same deposit, so their sum may not reach 100% or the
    ///      Treasury would receive nothing and every USDT-denominated reward would be unbacked.
    /// @param newBuybackBps The share, in basis points of each deposit. `0` disables the buyback.
    function setBuybackPercentage(uint256 newBuybackBps) external onlyOwner {
        if (newBuybackBps >= BPS_DENOMINATOR) revert InvalidPercentage();
        if (newBuybackBps + treasuryAllocationPercentage >= BPS_DENOMINATOR) revert InvalidAllocation();

        uint256 previous = buybackPercentage;
        buybackPercentage = newBuybackBps;
        emit BuybackPercentageUpdated(previous, newBuybackBps);
    }

    /// @notice Sets how the buyback's USDT divides between refilling the ARX reward float and
    ///         deepening the liquidity pool.
    /// @dev The two legs do different jobs, and the split is the lever between them:
    ///
    ///      - **Float leg.** The USDT buys ARX and the ARX is handed to the Treasury, where it pays
    ///        daily ROI. This is what turns a fixed supply from a reserve that only drains into a
    ///        medium that circulates: ARX goes pool -> Treasury -> member -> pool. Buying also adds
    ///        the spent USDT to the pool, so the quote side deepens as a side effect of this leg.
    ///      - **LP leg.** Half the USDT buys ARX, the other half is paired with it and added as
    ///        liquidity, with the LP tokens minted to the Treasury. This thickens the ARX side of
    ///        the pool, which the float leg alone does not do.
    ///
    ///      100% float is the right default while ARX float is the binding constraint. Shift toward
    ///      the LP leg once members are selling enough ROI that the pool's ARX side needs help.
    /// @param newFloatShareBps Share of the buyback routed to the float leg, in basis points.
    ///        `10000` sends everything to the float; `0` sends everything to liquidity.
    function setBuybackFloatShare(uint256 newFloatShareBps) external onlyOwner {
        if (newFloatShareBps > BPS_DENOMINATOR) revert InvalidPercentage();

        uint256 previous = buybackFloatShareBps;
        buybackFloatShareBps = newFloatShareBps;
        emit BuybackFloatShareUpdated(previous, newFloatShareBps);
    }

    /// @inheritdoc IProtocolConfig
    function arxPriceUpdater() external view override returns (address) {
        return _arxPriceUpdater;
    }

    /// @inheritdoc IProtocolConfig
    function arxPriceUpdatedAt() external view override returns (uint256) {
        return _arxPriceUpdatedAt;
    }

    /// @notice Updates the maximum tolerated liquidity slippage.
    /// @param newMaxSlippageBps The new maximum slippage, in basis points (`<= 100%`).
    function setMaxSlippage(uint256 newMaxSlippageBps) external onlyOwner {
        if (newMaxSlippageBps > BPS_DENOMINATOR) revert InvalidPercentage();
        uint256 previous = maxSlippageBps;
        maxSlippageBps = newMaxSlippageBps;
        emit MaxSlippageUpdated(previous, newMaxSlippageBps);
    }

    // -------------------------------------------------------------------------
    // Protocol status
    // -------------------------------------------------------------------------

    /// @notice Pauses the protocol.
    function pause() external onlyOwner {
        protocolPaused = true;
        emit Paused();
    }

    /// @notice Unpauses the protocol.
    function unpause() external onlyOwner {
        protocolPaused = false;
        emit Unpaused();
    }

    /// @notice Emergency protocol-wide pause. Reverts if already paused (operational entry point).
    /// @dev Sets the same {protocolPaused} flag as {pause}; every operational module reads it and
    ///      fails closed while set. Administrative owner functions remain available.
    function pauseProtocol() external onlyOwner {
        if (protocolPaused) revert AlreadyPaused();
        protocolPaused = true;
        emit ProtocolPaused(msg.sender);
    }

    /// @notice Resumes the protocol after an emergency pause. Reverts if not paused.
    function resumeProtocol() external onlyOwner {
        if (!protocolPaused) revert NotPaused();
        protocolPaused = false;
        emit ProtocolResumed(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Business-rule earnings cap & weekly renewal
    // -------------------------------------------------------------------------

    /// @notice Updates the protocol-wide total-earnings cap.
    /// @dev The cap bounds each user's **lifetime** total rewards (ROI + referral + weekly +
    ///      infinity + every future reward type) to `totalInvested * bps / 10000`, enforced globally
    ///      by the {RewardManager}. A value of `0` disables the cap (backward-compatible default);
    ///      the finalized Aurex business rule is `20000` (200%). Values below 100% are rejected as a
    ///      likely misconfiguration (a cap under the principal would strand invested funds).
    /// @param bps The cap in basis points (`0` to disable, otherwise `>= BPS_DENOMINATOR`).
    function setMaxTotalEarnings(uint256 bps) external onlyOwner {
        if (bps != 0 && bps < BPS_DENOMINATOR) revert InvalidPercentage();
        uint256 previous = maxTotalEarningsPercentage;
        maxTotalEarningsPercentage = bps;
        emit MaxTotalEarningsUpdated(previous, bps);
    }

    /// @notice Updates the weekly-reward renewal window.
    /// @dev Weekly rewards remain payable only while the user's active package is younger than this
    ///      window (measured from the package's `packageStart`, which every investment / re-topup /
    ///      upgrade resets). Once the window lapses without a renewal (re-topup / upgrade), weekly
    ///      rewards stop until the user renews. A value of `0` disables the renewal requirement
    ///      (backward-compatible default); the finalized Aurex business rule is `32` days.
    /// @param daysCount The renewal window in days (`0` to disable).
    function setWeeklyRenewalPeriod(uint256 daysCount) external onlyOwner {
        uint256 previous = weeklyRenewalPeriodDays;
        weeklyRenewalPeriodDays = daysCount;
        emit WeeklyRenewalPeriodUpdated(previous, daysCount);
    }

    // -------------------------------------------------------------------------
    // Level income (spec v2)
    // -------------------------------------------------------------------------

    /// @notice Updates the level-income configuration: the enable flag and the per-level rate
    ///         table (index 0 = level 1; level 1 is informational — the direct-referral module
    ///         pays it, the level-income walk pays levels 2..N).
    /// @param enabled Whether level income is enabled.
    /// @param levelBps The per-level rates, in basis points (each `<= 100%`, non-empty).
    function setLevelIncome(bool enabled, uint256[] calldata levelBps) external onlyOwner {
        if (levelBps.length == 0) revert InvalidConfiguration();
        for (uint256 i = 0; i < levelBps.length; i++) {
            if (levelBps[i] > BPS_DENOMINATOR) revert InvalidPercentage();
        }
        levelIncomeEnabled = enabled;
        _levelIncomeBps = levelBps;
        emit LevelIncomeUpdated(enabled, levelBps);
    }

    /// @notice Updates the level-income unlock criteria.
    /// @param band1Deposit Band-1 single-deposit threshold (unlocks levels 1–5, one per direct), USDT base units.
    /// @param band2Deposit Band-2 single-deposit threshold (levels 6–10 team counting), USDT base units.
    /// @param band3Deposit Band-3 single-deposit threshold (levels 11–15 team counting), USDT base units.
    /// @param l1Count Direct (level-1 team) members required for the band-2/band-3 unlocks.
    /// @param l2Count Level-2 team members required for the band-2/band-3 unlocks.
    function setLevelUnlockCriteria(
        uint256 band1Deposit,
        uint256 band2Deposit,
        uint256 band3Deposit,
        uint256 l1Count,
        uint256 l2Count
    ) external onlyOwner {
        if (band1Deposit == 0 || band2Deposit < band1Deposit || band3Deposit < band2Deposit) {
            revert InvalidConfiguration();
        }
        if (l1Count == 0 || l2Count == 0) revert InvalidConfiguration();

        levelUnlockBand1Deposit = band1Deposit;
        levelUnlockBand2Deposit = band2Deposit;
        levelUnlockBand3Deposit = band3Deposit;
        levelUnlockL1Count = l1Count;
        levelUnlockL2Count = l2Count;

        emit LevelUnlockCriteriaUpdated(band1Deposit, band2Deposit, band3Deposit, l1Count, l2Count);
    }

    /// @inheritdoc IProtocolConfig
    function levelIncomeCount() external view override returns (uint256) {
        return _levelIncomeBps.length;
    }

    /// @inheritdoc IProtocolConfig
    function levelIncomeBps(uint256 level) external view override returns (uint256) {
        if (level == 0 || level > _levelIncomeBps.length) return 0;
        return _levelIncomeBps[level - 1];
    }

    // -------------------------------------------------------------------------
    // Rank ladder & weekly rank bonus (spec v2)
    // -------------------------------------------------------------------------

    /// @notice Updates the rank ladder: per-rank matching thresholds, achievement bonuses and
    ///         leg-criteria requirements (all 0-indexed; index 0 = V1), plus the leg count for
    ///         leg-criteria ranks.
    /// @dev Every rank must carry exactly one criterion: a non-zero matching threshold **or** a
    ///      non-zero leg requirement referencing a strictly lower rank.
    /// @param matchingThresholds Matching-business threshold per rank, USDT base units (0 = leg-criteria rank).
    /// @param bonusTotals Total achievement bonus per rank, USDT base units.
    /// @param legRequirements Required lower rank per leg-criteria rank (0 = matching-threshold rank).
    /// @param legCount Distinct legs required to satisfy a leg-criteria rank (non-zero).
    function setRankConfig(
        uint256[] calldata matchingThresholds,
        uint256[] calldata bonusTotals,
        uint256[] calldata legRequirements,
        uint256 legCount
    ) external onlyOwner {
        uint256 count = matchingThresholds.length;
        if (count == 0 || bonusTotals.length != count || legRequirements.length != count || legCount == 0) {
            revert InvalidConfiguration();
        }
        for (uint256 i = 0; i < count; i++) {
            bool hasMatching = matchingThresholds[i] != 0;
            bool hasLegReq = legRequirements[i] != 0;
            // Exactly one criterion per rank; a leg requirement must reference a lower rank.
            if (hasMatching == hasLegReq) revert InvalidConfiguration();
            if (hasLegReq && legRequirements[i] > i) revert InvalidConfiguration();
        }

        _rankMatchingThreshold = matchingThresholds;
        _rankBonusTotal = bonusTotals;
        _rankLegRequirement = legRequirements;
        rankLegCount = legCount;

        emit RankConfigUpdated(count, legCount);
    }

    /// @notice Updates the rank-bonus payout schedule.
    /// @dev Bounds keep the values castable into the RankEngine's packed installment ledger
    ///      (`uint32` count, `uint64` timing): at most 10,000 installments and a 10-year interval.
    /// @param installments The number of equal installments each rank bonus is split into (non-zero).
    /// @param intervalSeconds The interval between installments, in seconds (non-zero).
    function setRankBonusSchedule(uint256 installments, uint256 intervalSeconds) external onlyOwner {
        if (installments == 0 || installments > 10_000) revert InvalidConfiguration();
        if (intervalSeconds == 0 || intervalSeconds > 3650 days) revert InvalidConfiguration();
        rankBonusInstallments = installments;
        rankBonusInterval = intervalSeconds;
        emit RankBonusScheduleUpdated(installments, intervalSeconds);
    }

    /// @inheritdoc IProtocolConfig
    function rankCount() external view override returns (uint256) {
        return _rankMatchingThreshold.length;
    }

    /// @inheritdoc IProtocolConfig
    function rankMatchingThreshold(uint256 rank) external view override returns (uint256) {
        if (rank == 0 || rank > _rankMatchingThreshold.length) return 0;
        return _rankMatchingThreshold[rank - 1];
    }

    /// @inheritdoc IProtocolConfig
    function rankBonusTotal(uint256 rank) external view override returns (uint256) {
        if (rank == 0 || rank > _rankBonusTotal.length) return 0;
        return _rankBonusTotal[rank - 1];
    }

    /// @inheritdoc IProtocolConfig
    function rankLegRequirement(uint256 rank) external view override returns (uint256) {
        if (rank == 0 || rank > _rankLegRequirement.length) return 0;
        return _rankLegRequirement[rank - 1];
    }

    // -------------------------------------------------------------------------
    // Infinity v2 & traversal (spec v2)
    // -------------------------------------------------------------------------

    /// @notice Updates the infinity-bonus structure: the achievement rank gate and the share of
    ///         the bonus paid to the next achiever above the primary one.
    /// @param rankGate The rank (1-based) that unlocks the infinity bonus (0 disables the v2
    ///        structure — the engine then pays nothing).
    /// @param uplineShareBps The upline achiever's share of the bonus, in basis points (`<= 100%`).
    function setInfinityStructure(uint256 rankGate, uint256 uplineShareBps) external onlyOwner {
        if (uplineShareBps > BPS_DENOMINATOR) revert InvalidPercentage();
        infinityRankGate = rankGate;
        infinityUplineShareBps = uplineShareBps;
        emit InfinityStructureUpdated(rankGate, uplineShareBps);
    }

    /// @notice Updates the upline traversal-depth bound used by volume crediting, rank
    ///         propagation and the infinity achiever search (gas-safety cap).
    /// @param depth The maximum number of ancestors walked per operation (non-zero).
    function setMaxUplineTraversalDepth(uint256 depth) external onlyOwner {
        if (depth == 0) revert InvalidConfiguration();
        uint256 previous = maxUplineTraversalDepth;
        maxUplineTraversalDepth = depth;
        emit MaxUplineTraversalDepthUpdated(previous, depth);
    }

    // -------------------------------------------------------------------------
    // Weekly renewal, cap boost & rank daily deposit limits (spec v2.1)
    // -------------------------------------------------------------------------

    /// @notice Updates the weekly rank-bonus renewal requirement: after a 32-day cycle, BOTH the
    ///         power (strongest) leg and the weaker legs must each add this share of the rank's
    ///         matching base in new business before the next cycle starts (15% + 15% = 30% total
    ///         under the finalized business rule).
    /// @param legBps The per-leg share of the rank's matching base, in basis points (`<= 100%`;
    ///        `0` disables renewal — every rank bonus is then one-time).
    function setRankRenewal(uint256 legBps) external onlyOwner {
        if (legBps > BPS_DENOMINATOR) revert InvalidPercentage();
        uint256 previous = rankRenewalLegBps;
        rankRenewalLegBps = legBps;
        emit RankRenewalUpdated(previous, legBps);
    }

    /// @notice Updates the rank-based earnings-cap boost: users at or above `rank` use the
    ///         boosted lifetime cap instead of {maxTotalEarningsPercentage} (3X for V8+ under the
    ///         finalized business rule).
    /// @param rank The rank (1-based) at which the boosted cap applies (`0` disables the boost).
    /// @param bps The boosted cap in basis points (`0` disables; otherwise `>= BPS_DENOMINATOR`).
    function setCapBoost(uint256 rank, uint256 bps) external onlyOwner {
        if (bps != 0 && bps < BPS_DENOMINATOR) revert InvalidPercentage();
        capBoostRank = rank;
        maxTotalEarningsBoostedPercentage = bps;
        emit CapBoostUpdated(rank, bps);
    }

    /// @notice Updates the per-rank daily deposit limits (USDT base units, index 0 = unranked;
    ///         ranks beyond the last index clamp to the final entry).
    /// @param limits The limit table (non-empty to enable; every entry non-zero).
    function setRankDailyDepositLimits(uint256[] calldata limits) external onlyOwner {
        for (uint256 i = 0; i < limits.length; i++) {
            if (limits[i] == 0) revert InvalidConfiguration();
        }
        _rankDailyDepositLimit = limits;
        emit RankDailyDepositLimitsUpdated(limits);
    }

    /// @inheritdoc IProtocolConfig
    function rankDailyDepositLimitCount() external view override returns (uint256) {
        return _rankDailyDepositLimit.length;
    }

    /// @inheritdoc IProtocolConfig
    function rankDailyDepositLimit(uint256 rank) external view override returns (uint256) {
        uint256 len = _rankDailyDepositLimit.length;
        if (len == 0) return 0;
        return _rankDailyDepositLimit[rank >= len ? len - 1 : rank];
    }

    // -------------------------------------------------------------------------
    // Upgrade authorization
    // -------------------------------------------------------------------------

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
