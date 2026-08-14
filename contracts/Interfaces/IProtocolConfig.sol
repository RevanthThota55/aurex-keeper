// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IProtocolConfig
/// @author Aurex Protocol
/// @notice Events and read interface for the {ProtocolConfig} — the single source of truth
///         for every configurable protocol parameter.
/// @dev Consumers (notably the ProtocolEngine) read all business parameters through this
///      interface so calculation logic never hardcodes values. Percentages are expressed in
///      basis points (10,000 = 100%).
interface IProtocolConfig {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when the ROI configuration is updated.
    event ROIConfigUpdated(uint256 dailyROIPercentage, uint256 maximumROIPercentage, uint256 roiDurationDays);

    /// @notice Emitted when the investment rules are updated.
    event InvestmentRulesUpdated(uint256 minimumInvestment, uint256 investmentStep, uint256 maximumInvestment);

    /// @notice Emitted when the referral rules are updated.
    event ReferralRulesUpdated(uint256 directReferralPercentage, uint256 maximumReferralDepth);

    /// @notice Emitted when the weekly-reward configuration is updated.
    event WeeklyRewardUpdated(bool enabled, uint256 percentage);

    /// @notice Emitted when the infinity-reward configuration is updated.
    event InfinityRewardUpdated(bool enabled, uint256 percentage);

    /// @notice Emitted when the allocation percentages are updated.
    event AllocationsUpdated(
        uint256 liquidityAllocationPercentage, uint256 treasuryAllocationPercentage, uint256 rewardAllocationPercentage
    );

    /// @notice Emitted when the automatic-reinvestment configuration is updated.
    event AutoReinvestConfigUpdated(
        bool enabled,
        uint256 minimumReinvestAmount,
        uint256 maximumReinvestAmount,
        uint256 reinvestPercentage,
        uint256 reinvestCooldown
    );

    /// @notice Emitted when the DEX router address is updated.
    event RouterUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the DEX factory address is updated.
    event FactoryUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the ARX price used for liquidity provisioning is updated.
    event ArxPriceUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when the maximum liquidity slippage tolerance is updated.
    event MaxSlippageUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when the delegated ARX price updater is changed. The zero address
    ///         disables delegated updates, leaving the owner as the only price source.
    event ArxPriceUpdaterUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the per-update ARX price deviation bound is changed.
    event ArxPriceMaxDeviationUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when the protocol is paused.
    event Paused();

    /// @notice Emitted when the protocol is unpaused.
    event Unpaused();

    /// @notice Emitted when the protocol is paused via the operational {pauseProtocol}.
    event ProtocolPaused(address indexed account);

    /// @notice Emitted when the protocol is resumed via the operational {resumeProtocol}.
    event ProtocolResumed(address indexed account);

    /// @notice Emitted when the total-earnings cap percentage is updated.
    event MaxTotalEarningsUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when the weekly-reward renewal window is updated.
    event WeeklyRenewalPeriodUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when the level-income configuration is updated.
    event LevelIncomeUpdated(bool enabled, uint256[] levelBps);

    /// @notice Emitted when the level-income unlock criteria are updated.
    event LevelUnlockCriteriaUpdated(
        uint256 band1Deposit, uint256 band2Deposit, uint256 band3Deposit, uint256 l1Count, uint256 l2Count
    );

    /// @notice Emitted when the rank ladder configuration is updated.
    event RankConfigUpdated(uint256 rankCount, uint256 legCount);

    /// @notice Emitted when the rank-bonus payout schedule is updated.
    event RankBonusScheduleUpdated(uint256 installments, uint256 intervalSeconds);

    /// @notice Emitted when the infinity-bonus structure is updated.
    event InfinityStructureUpdated(uint256 rankGate, uint256 uplineShareBps);

    /// @notice Emitted when the upline traversal-depth bound is updated.
    event MaxUplineTraversalDepthUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when the weekly rank-bonus renewal requirement is updated.
    event RankRenewalUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when the rank-based earnings-cap boost is updated.
    event CapBoostUpdated(uint256 rank, uint256 bps);

    /// @notice Emitted when the per-rank daily deposit limits are updated.
    event RankDailyDepositLimitsUpdated(uint256[] limits);

    /// @notice Emitted when the deposit-funded buyback share is updated.
    event BuybackPercentageUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when the buyback's float/liquidity split is updated.
    event BuybackFloatShareUpdated(uint256 previous, uint256 current);

    // -------------------------------------------------------------------------
    // ROI configuration
    // -------------------------------------------------------------------------

    /// @notice Daily ROI rate, in basis points.
    function dailyROIPercentage() external view returns (uint256);

    /// @notice Maximum cumulative ROI cap, in basis points (may exceed 100%).
    function maximumROIPercentage() external view returns (uint256);

    /// @notice Number of days ROI accrues.
    function roiDurationDays() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Investment rules
    // -------------------------------------------------------------------------

    /// @notice Minimum investment amount, in USDT base units. Enforced by
    ///         `InvestmentManager._validatePackage` on every invest / upgrade / re-topup.
    function minimumInvestment() external view returns (uint256);

    /// @notice Investment step size, in USDT base units — every deposit must be a whole multiple of
    ///         it. Enforced by `InvestmentManager._validatePackage`.
    function investmentStep() external view returns (uint256);

    /// @notice Maximum investment amount, in USDT base units — the absolute per-package ceiling.
    ///         The operative day-to-day bound is {rankDailyDepositLimit}.
    function maximumInvestment() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Referral rules
    // -------------------------------------------------------------------------

    /// @notice Direct referral commission, in basis points.
    function directReferralPercentage() external view returns (uint256);

    /// @notice Maximum referral tree depth considered by reward logic.
    function maximumReferralDepth() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Weekly reward configuration
    // -------------------------------------------------------------------------

    /// @notice Whether the weekly reward is enabled.
    function weeklyRewardEnabled() external view returns (bool);

    /// @notice Weekly reward rate, in basis points.
    function weeklyRewardPercentage() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Infinity reward configuration
    // -------------------------------------------------------------------------

    /// @notice Whether the infinity reward is enabled.
    function infinityRewardEnabled() external view returns (bool);

    /// @notice Infinity reward rate, in basis points.
    function infinityRewardPercentage() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Liquidity / allocation rules
    // -------------------------------------------------------------------------

    /// @notice Share of inflows allocated to liquidity, in basis points.
    function liquidityAllocationPercentage() external view returns (uint256);

    /// @notice Share of inflows allocated to the treasury, in basis points.
    function treasuryAllocationPercentage() external view returns (uint256);

    /// @notice Share of inflows allocated to rewards, in basis points.
    function rewardAllocationPercentage() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Automatic-reinvestment configuration
    // -------------------------------------------------------------------------

    /// @notice Whether automatic reinvestment is enabled protocol-wide.
    function autoReinvestEnabled() external view returns (bool);

    /// @notice Minimum automatic-reinvestment amount, in USDT base units (zero = unbounded).
    function minimumReinvestAmount() external view returns (uint256);

    /// @notice Maximum automatic-reinvestment amount, in USDT base units (zero = unbounded).
    function maximumReinvestAmount() external view returns (uint256);

    /// @notice Share of eligible rewards earmarked for automatic reinvestment, in basis points.
    function reinvestPercentage() external view returns (uint256);

    /// @notice Minimum time between a user's automatic reinvestments, in seconds.
    function reinvestCooldown() external view returns (uint256);

    // -------------------------------------------------------------------------
    // DEX / liquidity configuration
    // -------------------------------------------------------------------------

    /// @notice The configured DEX router address used for liquidity provisioning.
    function dexRouter() external view returns (address);

    /// @notice The configured DEX factory address used to create/look up the ARX/USDT pair.
    function dexFactory() external view returns (address);

    /// @notice The ARX price used to size the ARX side of a liquidity add, in USDT base units per
    ///         whole ARX (1e18 units). `requiredArx = usdtAmount * 1e18 / arxPriceUSDT`.
    function arxPriceUSDT() external view returns (uint256);

    /// @notice The maximum tolerated slippage for a liquidity add, in basis points.
    function maxSlippageBps() external view returns (uint256);

    /// @notice The account allowed to push routine ARX price updates alongside the owner, via
    ///         {ProtocolConfig.updateArxPrice}. Intended for the keeper's hot wallet. The zero
    ///         address disables delegated updates.
    function arxPriceUpdater() external view returns (address);

    /// @notice The maximum move a single delegated ARX price update may make, in basis points of
    ///         the current price. `0` disables the bound. Applies only to
    ///         {ProtocolConfig.updateArxPrice}; the owner's {ProtocolConfig.setArxPrice} is
    ///         deliberately unbounded.
    function arxPriceMaxDeviationBps() external view returns (uint256);

    /// @notice The share of every deposit routed into buying ARX on the open market and pairing the
    ///         proceeds into liquidity, in basis points. `0` disables the buyback.
    /// @dev Taken from the same deposit as {treasuryAllocationPercentage}; the two together must
    ///      leave a non-zero remainder for the Treasury.
    function buybackPercentage() external view returns (uint256);

    /// @notice Share of the buyback routed to refilling the ARX reward float rather than to
    ///         liquidity, in basis points. `10000` sends the whole buyback to the float.
    function buybackFloatShareBps() external view returns (uint256);

    /// @notice Unix timestamp of the last ARX price write, by either path. Zero until the first
    ///         write. Exposed so operators can detect a stalled price feed.
    function arxPriceUpdatedAt() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Business-rule earnings cap & weekly renewal
    // -------------------------------------------------------------------------

    /// @notice The lifetime total-earnings cap, in basis points of a user's total qualifying
    ///         investment. `0` disables the cap; the finalized business rule is `20000` (200%).
    ///         Enforced globally by the {RewardManager} across every reward type.
    function maxTotalEarningsPercentage() external view returns (uint256);

    /// @notice The weekly-reward renewal window, in days from the active package's start. `0`
    ///         disables the renewal requirement; the finalized business rule is `32` days. Weekly
    ///         rewards stop once this window lapses without a re-topup / upgrade.
    function weeklyRenewalPeriodDays() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Level income (spec v2)
    // -------------------------------------------------------------------------

    /// @notice Whether level income is enabled.
    function levelIncomeEnabled() external view returns (bool);

    /// @notice The number of configured level-income levels (15 under the finalized plan).
    function levelIncomeCount() external view returns (uint256);

    /// @notice The level-income rate for 1-based `level`, in basis points (zero when out of
    ///         range). Level 1 is informational — the direct-referral module pays level 1.
    function levelIncomeBps(uint256 level) external view returns (uint256);

    /// @notice Band-1 single-deposit threshold (levels 1–5 unlock, one per qualified direct).
    function levelUnlockBand1Deposit() external view returns (uint256);

    /// @notice Band-2 single-deposit threshold (levels 6–10 team counting).
    function levelUnlockBand2Deposit() external view returns (uint256);

    /// @notice Band-3 single-deposit threshold (levels 11–15 team counting).
    function levelUnlockBand3Deposit() external view returns (uint256);

    /// @notice Direct (level-1 team) members required for the band-2/band-3 unlocks.
    function levelUnlockL1Count() external view returns (uint256);

    /// @notice Level-2 team members required for the band-2/band-3 unlocks.
    function levelUnlockL2Count() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Rank ladder & weekly rank bonus (spec v2)
    // -------------------------------------------------------------------------

    /// @notice The number of configured ranks (14 under the finalized plan).
    function rankCount() external view returns (uint256);

    /// @notice The matching-business threshold for 1-based `rank`, in USDT base units (zero for
    ///         leg-criteria ranks or out-of-range).
    function rankMatchingThreshold(uint256 rank) external view returns (uint256);

    /// @notice The total achievement bonus for 1-based `rank`, in USDT base units.
    function rankBonusTotal(uint256 rank) external view returns (uint256);

    /// @notice The required lower rank for 1-based leg-criteria `rank` (zero for
    ///         matching-threshold ranks or out-of-range).
    function rankLegRequirement(uint256 rank) external view returns (uint256);

    /// @notice Distinct legs required to satisfy a leg-criteria rank.
    function rankLegCount() external view returns (uint256);

    /// @notice The number of equal installments each rank bonus is split into.
    function rankBonusInstallments() external view returns (uint256);

    /// @notice The interval between rank-bonus installments, in seconds.
    function rankBonusInterval() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Infinity v2 & traversal (spec v2)
    // -------------------------------------------------------------------------

    /// @notice The rank (1-based) that unlocks the infinity bonus (zero = v2 structure unset).
    function infinityRankGate() external view returns (uint256);

    /// @notice The upline achiever's share of the infinity bonus, in basis points.
    function infinityUplineShareBps() external view returns (uint256);

    /// @notice The maximum ancestors walked per traversal (volume credit, rank propagation,
    ///         infinity achiever search).
    function maxUplineTraversalDepth() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Weekly renewal, cap boost & rank daily deposit limits (spec v2.1)
    // -------------------------------------------------------------------------

    /// @notice The per-leg share of a rank's matching base required (power leg AND weaker legs
    ///         each) to renew the weekly rank-bonus cycle, in basis points (`0` = renewal off).
    function rankRenewalLegBps() external view returns (uint256);

    /// @notice The rank (1-based) at which the boosted earnings cap applies (`0` = boost off).
    function capBoostRank() external view returns (uint256);

    /// @notice The boosted lifetime earnings cap for ranks at/above {capBoostRank}, in basis
    ///         points (`0` = boost off; the finalized business rule is 30000 = 3X for V8+).
    function maxTotalEarningsBoostedPercentage() external view returns (uint256);

    /// @notice The number of configured per-rank daily deposit limits (`0` = limits disabled).
    function rankDailyDepositLimitCount() external view returns (uint256);

    /// @notice The daily deposit limit for `rank` (0 = unranked), in USDT base units. Ranks
    ///         beyond the table clamp to the final entry; `0` when the table is unset.
    function rankDailyDepositLimit(uint256 rank) external view returns (uint256);

    // -------------------------------------------------------------------------
    // Protocol status
    // -------------------------------------------------------------------------

    /// @notice Whether the protocol is currently paused.
    function protocolPaused() external view returns (bool);
}
