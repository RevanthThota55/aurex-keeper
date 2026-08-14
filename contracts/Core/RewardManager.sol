// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AlreadyPaused, ModuleIsPaused, NotPaused, ProtocolIsPaused, ZeroAddress} from "../Errors/CommonErrors.sol";
import {
    EarningsCapReached,
    InvalidRewardAmount,
    InvalidUser,
    NothingToClaim,
    TransferFailed,
    UnauthorizedContract
} from "../Errors/RewardErrors.sol";
import {IInvestmentManager} from "../Interfaces/IInvestmentManager.sol";
import {IProtocolConfig} from "../Interfaces/IProtocolConfig.sol";
import {IRankEngine} from "../Interfaces/IRankEngine.sol";
import {IRewardManager} from "../Interfaces/IRewardManager.sol";
import {ITreasury} from "../Interfaces/ITreasury.sol";

/// @title RewardManager
/// @author Aurex Protocol
/// @notice Upgradeable reward-accounting and claim engine for the Aurex protocol.
/// @dev
/// ## Responsibilities
/// Maintains per-user reward balances across five buckets (daily ROI, referral, weekly
/// rank bonus, infinity, level income), tracks claimed / pending / total-earned totals, and
/// processes claims by requesting the Treasury to pay the user in USDT.
///
/// ## Explicit non-responsibilities
/// This contract owns **no** registration, referral-tree, package or Treasury-custody
/// logic, and contains **no** ROI/MLM calculation formulas. Authorized recorder contracts
/// supply the reward amounts; this contract only stores them. It never holds user funds —
/// claims are paid out of the Treasury.
///
/// ## Integration
/// The InvestmentManager is used **only** to validate that a reward target is a registered
/// user; user storage is never duplicated. The Treasury is used **only** to transfer claimed
/// rewards.
///
/// ## Security
/// `SafeERC20` semantics are enforced by the Treasury; claims follow Checks-Effects-
/// Interactions and are `nonReentrant`; recording is restricted to authorized contracts and
/// validates the user and amount. The reentrancy guard is the storage-namespaced OpenZeppelin
/// v5 `ReentrancyGuard` (no initializer required).
contract RewardManager is Initializable, OwnableUpgradeable, ReentrancyGuard, UUPSUpgradeable, IRewardManager {
    /// @notice Basis-point denominator: 10,000 basis points == 100%. Earnings-cap percentages are in BPS.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Treasury that pays out claimed rewards. Owner-updatable.
    address public override treasury;

    /// @notice InvestmentManager consulted to validate registered users. Owner-updatable.
    address public override investmentManager;

    /// @notice USDT token address. Fixed after initialization.
    address public override usdt;

    /// @notice ARX token address. Fixed after initialization.
    address public override arx;

    /// @notice Whether an address is authorized to record rewards.
    mapping(address account => bool authorized) public override authorizedContracts;

    /// @notice Per-user reward accounting.
    mapping(address user => RewardInfo info) private _rewards;

    // --- Appended storage (operational phase) ---------------------------------

    /// @notice The ProtocolConfig read for the protocol-wide pause. Owner-updatable.
    /// @dev Zero until wired; while zero, the protocol-wide pause is not enforced here.
    address public protocolConfig;

    /// @notice Whether reward claims are paused at the module level (independent of the protocol pause).
    bool public rewardsPaused;

    /// @notice Cumulative reward VALUE ever recorded across all users and buckets (USDT terms).
    uint256 public totalRewardsRecorded;

    /// @notice Cumulative USDT rewards ever claimed across all users, in USDT base units.
    uint256 public totalRewardsClaimed;

    // --- Appended storage (spec-v2.1 phase) -----------------------------------

    /// @inheritdoc IRewardManager
    /// @dev Zero until wired; while zero the rank-based cap boost is inactive.
    address public override rankEngine;

    /// @inheritdoc IRewardManager
    uint256 public override totalUsdtRewardsRecorded;

    /// @inheritdoc IRewardManager
    uint256 public override totalArxRewardsRecorded;

    /// @inheritdoc IRewardManager
    uint256 public override totalArxRewardsClaimed;

    /// @notice Reserved storage slots. Shrunk from 36 to 34 to absorb the two mappings appended
    ///         below WITHOUT shifting any slot declared above it.
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[34] private __gap;

    // --- Appended storage (accrue-uncapped / withdraw-capped phase) ------------
    //
    // The earnings cap moved from ACCRUAL to WITHDRAWAL. Rewards of every type now accrue in
    // full and are never destroyed; the cap instead bounds how much VALUE a user may take out.
    // A re-topup raises `totalInvested`, which raises the cap, which unlocks balance that had
    // already accrued. These two mappings are the whole of the new bookkeeping.

    /// @notice Cumulative reward VALUE each user has actually withdrawn, in USDT base units.
    /// @dev The figure the cap is measured against. Distinct from `RewardInfo.claimedReward`,
    ///      which counts USDT tokens only — this counts the USDT-denominated value of BOTH the
    ///      USDT and the ARX legs, which is the unit the cap is expressed in.
    mapping(address user => uint256 value) private _withdrawnValue;

    /// @notice The USDT-denominated value backing each user's `pendingArxReward`.
    /// @dev ARX pendings are stored in ARX, but the cap is denominated in USDT. The value is
    ///      known at accrual time (it is the `amount` the engine passes alongside `arxAmount`),
    ///      so it is recorded here rather than re-derived at claim time from a live price —
    ///      which would make an already-claimable balance move with the market.
    mapping(address user => uint256 value) private _pendingArxValue;

    /// @notice Emitted when reward claims are paused at the module level.
    event RewardsPaused(address indexed account);

    /// @notice Emitted when reward claims are resumed at the module level.
    event RewardsResumed(address indexed account);

    /// @notice Emitted when the owner updates the ProtocolConfig address.
    event ProtocolConfigUpdated(address indexed previous, address indexed current);

    /// @notice Restricts a function to addresses in the {authorizedContracts} set.
    modifier onlyAuthorized() {
        _requireAuthorized();
        _;
    }

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the manager and wires the protocol addresses.
    /// @dev Callable exactly once, on the proxy. All addresses must be non-zero.
    /// @param owner_ Protocol administrator.
    /// @param treasury_ Treasury that pays claimed rewards.
    /// @param investmentManager_ InvestmentManager used for user validation.
    /// @param usdt_ USDT token address.
    /// @param arx_ ARX token address.
    function initialize(address owner_, address treasury_, address investmentManager_, address usdt_, address arx_)
        external
        initializer
    {
        if (
            owner_ == address(0) || treasury_ == address(0) || investmentManager_ == address(0) || usdt_ == address(0)
                || arx_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __Ownable_init(owner_);

        treasury = treasury_;
        investmentManager = investmentManager_;
        usdt = usdt_;
        arx = arx_;
    }

    // -------------------------------------------------------------------------
    // Owner configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the Treasury address. USDT and ARX are fixed and cannot be changed.
    /// @param newTreasury The new Treasury address (non-zero).
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    /// @notice Updates the InvestmentManager address.
    /// @param newInvestmentManager The new InvestmentManager address (non-zero).
    function setInvestmentManager(address newInvestmentManager) external onlyOwner {
        if (newInvestmentManager == address(0)) revert ZeroAddress();
        address previous = investmentManager;
        investmentManager = newInvestmentManager;
        emit InvestmentManagerUpdated(previous, newInvestmentManager);
    }

    // -------------------------------------------------------------------------
    // Authorization management (owner only)
    // -------------------------------------------------------------------------

    /// @notice Grants `account` authorization to record rewards.
    /// @param account The address to authorize (non-zero).
    function authorizeContract(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedContracts[account] = true;
        emit AuthorizedContractAdded(account);
    }

    /// @notice Revokes `account`'s authorization to record rewards.
    /// @param account The address to de-authorize (non-zero).
    function removeAuthorizedContract(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedContracts[account] = false;
        emit AuthorizedContractRemoved(account);
    }

    /// @notice Updates the ProtocolConfig address consulted for the protocol-wide pause.
    /// @param newProtocolConfig The new ProtocolConfig address (non-zero).
    function setProtocolConfig(address newProtocolConfig) external onlyOwner {
        if (newProtocolConfig == address(0)) revert ZeroAddress();
        address previous = protocolConfig;
        protocolConfig = newProtocolConfig;
        emit ProtocolConfigUpdated(previous, newProtocolConfig);
    }

    /// @notice Updates the RankEngine consulted for the rank-based earnings-cap boost.
    /// @param newRankEngine The new RankEngine address (non-zero).
    function setRankEngine(address newRankEngine) external onlyOwner {
        if (newRankEngine == address(0)) revert ZeroAddress();
        address previous = rankEngine;
        rankEngine = newRankEngine;
        emit RankEngineUpdated(previous, newRankEngine);
    }

    /// @notice Pauses reward claims at the module level.
    function pauseRewards() external onlyOwner {
        if (rewardsPaused) revert AlreadyPaused();
        rewardsPaused = true;
        emit RewardsPaused(msg.sender);
    }

    /// @notice Resumes reward claims at the module level.
    function resumeRewards() external onlyOwner {
        if (!rewardsPaused) revert NotPaused();
        rewardsPaused = false;
        emit RewardsResumed(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Reward recording (authorized contracts only)
    // -------------------------------------------------------------------------

    /// @notice Records a daily-ROI reward for `user` IN FULL. The `amount` is the USDT-denominated
    ///         VALUE (cap + statistics); `arxAmount` is the ARX payable for it. A zero `arxAmount`
    ///         preserves the legacy USDT-payable path (no oracle price available).
    /// @dev No longer clamped at accrual. The total-earnings cap is enforced on WITHDRAWAL (see
    ///      {_claim}), so a user at their cap keeps accruing and keeps the balance — it is locked,
    ///      not destroyed, and unlocks when a re-topup raises the cap. Clamping here also let a
    ///      stream's `roiEarned` absorb ROI the user never received, retiring streams early.
    /// @param user The registered user to credit (non-zero, registered).
    /// @param amount The reward value, in USDT base units (non-zero).
    /// @param arxAmount The corresponding ARX payout, in ARX base units (zero = pay in USDT).
    function recordDailyReward(address user, uint256 amount, uint256 arxAmount) external override onlyAuthorized {
        _validate(user, amount);

        RewardInfo storage info = _rewards[user];
        info.dailyROIReward += amount;
        info.totalRewardEarned += amount;
        totalRewardsRecorded += amount;

        if (arxAmount == 0) {
            // Legacy path: no price available — the ROI stays a USDT liability.
            info.pendingReward += amount;
            totalUsdtRewardsRecorded += amount;
        } else {
            // ARX path: the ARX is the payable, `amount` is the value it represents. Both are
            // recorded so the withdrawal gate can measure an ARX balance against a USDT cap.
            info.pendingArxReward += arxAmount;
            _pendingArxValue[user] += amount;
            totalArxRewardsRecorded += arxAmount;
            emit ArxRewardAccrued(user, amount, arxAmount);
        }

        emit DailyRewardRecorded(user, amount);
    }

    /// @notice Records a referral reward of `amount` for `user` in full.
    /// @dev Accrual is uncapped; the total-earnings cap is enforced on withdrawal. See
    ///      {recordDailyReward} for why.
    /// @param user The registered user to credit (non-zero, registered).
    /// @param amount The reward amount, in USDT base units (non-zero).
    function recordReferralReward(address user, uint256 amount) external override onlyAuthorized {
        _validate(user, amount);
        RewardInfo storage info = _rewards[user];
        info.referralReward += amount;
        _accrue(info, amount);
        emit ReferralRewardRecorded(user, amount);
    }

    /// @notice Records a weekly reward of `amount` for `user` in full.
    /// @dev Accrual is uncapped; the cap is enforced on withdrawal.
    /// @param user The registered user to credit (non-zero, registered).
    /// @param amount The reward amount, in USDT base units (non-zero).
    function recordWeeklyReward(address user, uint256 amount) external override onlyAuthorized {
        _validate(user, amount);
        RewardInfo storage info = _rewards[user];
        info.weeklyReward += amount;
        _accrue(info, amount);
        emit WeeklyRewardRecorded(user, amount);
    }

    /// @notice Records an infinity reward of `amount` for `user` in full.
    /// @dev Accrual is uncapped; the cap is enforced on withdrawal.
    /// @param user The registered user to credit (non-zero, registered).
    /// @param amount The reward amount, in USDT base units (non-zero).
    function recordInfinityReward(address user, uint256 amount) external override onlyAuthorized {
        _validate(user, amount);
        RewardInfo storage info = _rewards[user];
        info.infinityReward += amount;
        _accrue(info, amount);
        emit InfinityRewardRecorded(user, amount);
    }

    /// @notice Records a level-income reward of `amount` for `user` in full.
    /// @dev Accrual is uncapped; the cap is enforced on withdrawal.
    /// @param user The registered user to credit (non-zero, registered).
    /// @param amount The reward amount, in USDT base units (non-zero).
    function recordLevelReward(address user, uint256 amount) external override onlyAuthorized {
        _validate(user, amount);
        RewardInfo storage info = _rewards[user];
        info.levelReward += amount;
        _accrue(info, amount);
        emit LevelRewardRecorded(user, amount);
    }

    // -------------------------------------------------------------------------
    // Claiming
    // -------------------------------------------------------------------------

    /// @notice Claims the caller's entire pending reward balance — USDT and ARX together.
    /// @dev Follows Checks-Effects-Interactions: both pendings are zeroed and claimed totals
    ///      increased before the Treasury is asked to pay. Reverts {TransferFailed} (rolling back
    ///      all state) if either Treasury transfer does not succeed.
    function claimRewards() external override nonReentrant {
        _requireClaimable();
        _claim(msg.sender);
    }

    /// @notice Processes `user`'s pending reward claim (USDT and ARX), paying them via the Treasury.
    /// @dev Authorized-contract counterpart to {claimRewards}: it lets a trusted coordinator
    ///      (the ProtocolEngine) drive a withdrawal for a specific `user` without ever moving
    ///      tokens itself, with identical Checks-Effects-Interactions and accounting.
    ///      Restricted to authorized contracts and `nonReentrant`.
    /// @param user The registered user whose pending balances are claimed and paid.
    /// @return amount The USDT amount claimed and transferred, in USDT base units.
    function processClaim(address user) external override onlyAuthorized nonReentrant returns (uint256 amount) {
        _requireClaimable();
        amount = _claim(user);
    }

    /// @dev Shared claim core: zeroes both pendings, updates the claimed ledgers, then pays the
    ///      user from the Treasury (USDT and/or ARX). Reverts {NothingToClaim} when neither
    ///      balance is pending and {TransferFailed} when a Treasury transfer fails.
    function _claim(address user) private returns (uint256 usdtAmount) {
        RewardInfo storage info = _rewards[user];
        uint256 usdtPending = info.pendingReward;
        uint256 arxPending = info.pendingArxReward;
        uint256 arxValue = _pendingArxValue[user];
        uint256 arxOut;

        // The cap is denominated in USDT value, so both legs are measured in value: a USDT
        // pending IS its own value, and an ARX pending carries the value recorded beside it.
        uint256 totalValue = usdtPending + arxValue;

        if (totalValue == 0) {
            // No value-tracked balance. Any ARX sitting here accrued under the previous rule,
            // where the cap was applied at ACCRUAL — capping it again on the way out would
            // charge it twice, so it is paid in full without consuming allowance.
            if (arxPending == 0) revert NothingToClaim();
            arxOut = arxPending;
        } else {
            uint256 payableValue = _withdrawableValue(user, totalValue);
            // Distinct from NothingToClaim: a balance exists, the cap is what is holding it.
            // It stays owed and becomes claimable the moment a re-topup raises the cap.
            if (payableValue == 0) revert EarningsCapReached();

            if (payableValue == totalValue) {
                // Full claim divides exactly — take both legs whole and leave no dust behind.
                usdtAmount = usdtPending;
                arxOut = arxPending;
                arxValue = 0;
            } else {
                // Partial claim: split the allowance across the legs in proportion to their
                // value, so neither asset is drained ahead of the other.
                usdtAmount = (usdtPending * payableValue) / totalValue;
                uint256 arxValueOut = payableValue - usdtAmount;
                arxOut = arxValue == 0 ? 0 : (arxPending * arxValueOut) / arxValue;
                arxValue -= arxValueOut;
            }

            _withdrawnValue[user] += payableValue;
            emit RewardWithdrawalCapped(user, totalValue, payableValue);
        }

        // Effects before interactions.
        if (usdtAmount != 0) {
            info.pendingReward = usdtPending - usdtAmount;
            info.claimedReward += usdtAmount;
            totalRewardsClaimed += usdtAmount;
        }
        if (arxOut != 0) {
            info.pendingArxReward = arxPending - arxOut;
            info.claimedArxReward += arxOut;
            totalArxRewardsClaimed += arxOut;
        }
        _pendingArxValue[user] = arxValue;

        ITreasury vault = ITreasury(treasury);
        if (usdtAmount != 0) {
            try vault.transferUSDT(user, usdtAmount) {}
            catch {
                revert TransferFailed();
            }
            emit RewardClaimed(user, usdtAmount);
        }
        if (arxOut != 0) {
            try vault.transferARX(user, arxOut) {}
            catch {
                revert TransferFailed();
            }
            emit ArxRewardClaimed(user, arxOut);
        }
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IRewardManager
    function getRewardInfo(address user) external view override returns (RewardInfo memory) {
        return _rewards[user];
    }

    /// @inheritdoc IRewardManager
    function pendingRewards(address user) external view override returns (uint256) {
        return _rewards[user].pendingReward;
    }

    /// @inheritdoc IRewardManager
    function pendingArxRewards(address user) external view override returns (uint256) {
        return _rewards[user].pendingArxReward;
    }

    /// @inheritdoc IRewardManager
    function claimedRewards(address user) external view override returns (uint256) {
        return _rewards[user].claimedReward;
    }

    /// @inheritdoc IRewardManager
    function totalEarned(address user) external view override returns (uint256) {
        return _rewards[user].totalRewardEarned;
    }

    // -------------------------------------------------------------------------
    // Business-rule earnings cap (views)
    // -------------------------------------------------------------------------

    /// @inheritdoc IRewardManager
    /// @dev Spec v2.1: users at or above the configured `capBoostRank` (V8 under the finalized
    ///      rule) use the boosted percentage (3X) instead of the base cap (2X). The boost is
    ///      inactive while the RankEngine is unwired or the boost parameters are zero.
    function earningsCap(address user) public view override returns (uint256) {
        address pc = protocolConfig;
        if (pc == address(0)) return type(uint256).max; // cap disabled until config wired
        IProtocolConfig config = IProtocolConfig(pc);
        uint256 capBps = config.maxTotalEarningsPercentage();
        if (capBps == 0) return type(uint256).max; // cap disabled

        address ranks = rankEngine;
        if (ranks != address(0)) {
            uint256 boostBps = config.maxTotalEarningsBoostedPercentage();
            uint256 boostRank = config.capBoostRank();
            if (boostBps != 0 && boostRank != 0 && IRankEngine(ranks).rankOf(user) >= boostRank) {
                capBps = boostBps;
            }
        }

        uint256 invested = IInvestmentManager(investmentManager).getUser(user).totalInvested;
        return (invested * capBps) / BPS_DENOMINATOR;
    }

    /// @inheritdoc IRewardManager
    /// @dev Measured against cumulative WITHDRAWALS, not cumulative earnings — the cap now bounds
    ///      what leaves the protocol, not what accrues. A user may legitimately have earned far
    ///      more than this; see {lockedValue} for the part held back.
    function remainingEarningsCap(address user) external view override returns (uint256) {
        uint256 cap = earningsCap(user);
        if (cap == type(uint256).max) return type(uint256).max;
        uint256 withdrawn = _withdrawnValue[user];
        return withdrawn >= cap ? 0 : cap - withdrawn;
    }

    /// @notice The reward VALUE `user` has withdrawn over their lifetime, in USDT base units.
    /// @dev This is the figure the earnings cap is measured against. It counts the value of both
    ///      the USDT and ARX legs, unlike `getReward(user).claimedReward`, which counts USDT only.
    function withdrawnValue(address user) external view returns (uint256) {
        return _withdrawnValue[user];
    }

    /// @notice The USDT-denominated value backing `user`'s pending ARX balance.
    function pendingArxValue(address user) external view returns (uint256) {
        return _pendingArxValue[user];
    }

    /// @notice The value `user` could withdraw right now, in USDT base units.
    /// @dev Their whole pending balance, or whatever the cap still allows — whichever is smaller.
    function claimableValue(address user) external view returns (uint256) {
        return _withdrawableValue(user, _rewards[user].pendingReward + _pendingArxValue[user]);
    }

    /// @notice The value `user` has accrued but cannot withdraw yet because of the earnings cap.
    /// @dev Locked, not lost. A re-topup raises `totalInvested`, raising the cap, releasing this.
    ///      Surface this in the UI — a member whose rewards stop with no explanation assumes the
    ///      protocol is broken or dishonest.
    function lockedValue(address user) external view returns (uint256) {
        uint256 pendingValue = _rewards[user].pendingReward + _pendingArxValue[user];
        return pendingValue - _withdrawableValue(user, pendingValue);
    }

    // -------------------------------------------------------------------------
    // Treasury solvency (accounting invariants & monitoring)
    // -------------------------------------------------------------------------

    /// @inheritdoc IRewardManager
    /// @dev USDT liabilities only: the ARX-payable ROI is tracked in {arxOutstandingLiabilities}.
    function outstandingLiabilities() public view override returns (uint256) {
        return totalUsdtRewardsRecorded - totalRewardsClaimed;
    }

    /// @inheritdoc IRewardManager
    function arxOutstandingLiabilities() public view override returns (uint256) {
        return totalArxRewardsRecorded - totalArxRewardsClaimed;
    }

    /// @inheritdoc IRewardManager
    function treasuryBacking() public view override returns (uint256) {
        return ITreasury(treasury).balanceOfToken(usdt);
    }

    /// @inheritdoc IRewardManager
    /// @dev USDT-only, by interface contract. For the ARX side — which is where the ROI liability
    ///      actually lives — use {arxTreasuryBacking}/{isArxTreasurySolvent}. A protocol that pays
    ///      ROI in ARX and checks only USDT is not measuring the exposure that can actually fail.
    function isTreasurySolvent() public view override returns (bool) {
        return treasuryBacking() >= outstandingLiabilities();
    }

    /// @notice The Treasury's ARX balance, in ARX base units.
    function arxTreasuryBacking() public view returns (uint256) {
        return ITreasury(treasury).balanceOfToken(arx);
    }

    /// @notice Whether the Treasury's ARX covers the unclaimed ARX rewards already recorded.
    /// @dev Now that accrual is uncapped, `arxOutstandingLiabilities()` grows without bound while
    ///      members sit at their cap, and the whole locked balance becomes claimable the moment a
    ///      re-topup raises it. This going false is the early warning; the alternative is finding
    ///      out when a member's claim reverts with TransferFailed.
    function isArxTreasurySolvent() public view returns (bool) {
        return arxTreasuryBacking() >= arxOutstandingLiabilities();
    }

    /// @notice Reads the current solvency position and emits it on-chain for monitoring.
    /// @dev Permissionless monitoring entrypoint (keeper/admin/anyone). The protocol is structurally
    ///      inflow-funded, so recorded liabilities can legitimately exceed backing between funding
    ///      rounds; this surfaces that condition **non-silently** rather than blocking accrual (which
    ///      would DoS the keeper flow). The ultimate backstop is the claim path, which reverts and
    ///      rolls back if the Treasury cannot pay (see {claimRewards}/{processClaim}).
    /// @return outstanding The unclaimed recorded liabilities, in USDT base units.
    /// @return backing The Treasury's USDT balance, in USDT base units.
    /// @return solvent Whether backing currently covers the outstanding liabilities.
    function checkSolvency() external override returns (uint256 outstanding, uint256 backing, bool solvent) {
        outstanding = outstandingLiabilities();
        backing = treasuryBacking();
        solvent = backing >= outstanding;
        emit SolvencyChecked(outstanding, backing, solvent);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev How much of `requestedValue` the user may withdraw right now, bounded by the business
    ///      rule that lifetime WITHDRAWALS (across every reward type) never exceed
    ///      `totalInvested * maxTotalEarningsPercentage / 10000`.
    ///
    ///      This replaces the former accrual-time clamp. Measuring against cumulative withdrawals
    ///      rather than cumulative earnings is what makes the cap a lock instead of a shredder:
    ///      balance above the cap keeps sitting in `pending*` and becomes withdrawable as soon as
    ///      a re-topup raises `totalInvested`.
    ///
    ///      Returns the request unchanged when the cap is disabled (no ProtocolConfig wired, or
    ///      the percentage is zero), preserving backward compatibility.
    /// @param user The user withdrawing.
    /// @param requestedValue The USDT-denominated value the user wants to take out.
    /// @return The value that may actually be paid (0 when the cap is already exhausted).
    function _withdrawableValue(address user, uint256 requestedValue) private view returns (uint256) {
        uint256 cap = earningsCap(user);
        if (cap == type(uint256).max) return requestedValue; // cap disabled
        uint256 withdrawn = _withdrawnValue[user];
        if (withdrawn >= cap) return 0;
        uint256 allowance = cap - withdrawn;
        return requestedValue > allowance ? allowance : requestedValue;
    }

    /// @dev Reverts unless the caller is an authorized reward recorder.
    function _requireAuthorized() private view {
        if (!authorizedContracts[msg.sender]) revert UnauthorizedContract();
    }

    /// @dev Reverts when claims are paused — at the module level ({ModuleIsPaused}) or, when a
    ///      ProtocolConfig is wired, protocol-wide ({ProtocolIsPaused}).
    function _requireClaimable() private view {
        if (rewardsPaused) revert ModuleIsPaused();
        address pc = protocolConfig;
        if (pc != address(0) && IProtocolConfig(pc).protocolPaused()) revert ProtocolIsPaused();
    }

    /// @dev Reverts unless `user` is a registered protocol user and `amount` is non-zero.
    function _validate(address user, uint256 amount) private view {
        if (!IInvestmentManager(investmentManager).isRegistered(user)) revert InvalidUser();
        if (amount == 0) revert InvalidRewardAmount();
    }

    /// @dev Adds a USDT-payable `amount` to the user's total-earned and pending balances and the
    ///      protocol-wide value + USDT-claimable ledgers.
    function _accrue(RewardInfo storage info, uint256 amount) private {
        info.totalRewardEarned += amount;
        info.pendingReward += amount;
        totalRewardsRecorded += amount;
        totalUsdtRewardsRecorded += amount;
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
