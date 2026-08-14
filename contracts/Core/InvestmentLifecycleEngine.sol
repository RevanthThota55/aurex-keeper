// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ZeroAddress} from "../Errors/CommonErrors.sol";
import {InvalidInvestor, UnauthorizedCaller} from "../Errors/InvestmentLifecycleErrors.sol";
import {IInvestmentLifecycleEngine} from "../Interfaces/IInvestmentLifecycleEngine.sol";
import {IInvestmentManager} from "../Interfaces/IInvestmentManager.sol";
import {ILiquidityReserveEngine} from "../Interfaces/ILiquidityReserveEngine.sol";
import {IProtocolConfig} from "../Interfaces/IProtocolConfig.sol";
import {IProtocolEngine} from "../Interfaces/IProtocolEngine.sol";
import {IRankEngine} from "../Interfaces/IRankEngine.sol";

/// @title InvestmentLifecycleEngine
/// @author Aurex Protocol
/// @notice The protocol orchestrator: every investment and package upgrade passes through here,
///         which coordinates the post-investment pipeline across the protocol modules.
/// @dev
/// ## Purpose
/// This engine is a pure coordinator. It contains **no** reward calculations, **no** fund custody
/// and stores **no** balances. Reward math lives in the ProtocolEngine, balances in the
/// RewardManager, funds in the Treasury, and user/referral state in the InvestmentManager. It
/// coordinates the modules; it does not replace them.
///
/// ## Investment allocation
/// Every investment is immediately split — a liquidity share and a protocol share — using the
/// allocation percentages from the ProtocolConfig (never hardcoded). It computes the split amounts,
/// emits {LiquidityAllocated} / {ProtocolAllocated}, and forwards the liquidity share to the
/// {LiquidityReserveEngine} (when wired) for reserve accounting. It does **not** interact with
/// PancakeSwap, create liquidity, swap or move funds — the real LP implementation arrives in a later
/// phase and consumes the reserve.
///
/// ## Pipeline
/// {processInvestment} runs the post-investment stages: validate the investor, split the investment
/// into its liquidity/protocol allocations, trigger the direct referral reward and the infinity
/// reward (both via the ProtocolEngine), signal weekly-reward eligibility and daily-ROI activation,
/// and emit {InvestmentProcessed}. Daily ROI and weekly rewards accrue from the package the
/// InvestmentManager already activated and are paid on their schedule by the ProtocolEngine; this
/// engine signals those lifecycle stages for off-chain coordination without re-implementing them.
///
/// ## Extension points
/// Later phases insert additional coordinated stages into the pipeline — the real liquidity/LP
/// step (consuming the computed liquidity allocation), re-topup and campaign rewards — each calling
/// its module without duplicating logic. They slot into the numbered steps of {processInvestment}
/// (an implementation upgrade), leaving the existing stages untouched.
///
/// ## Upgradeability
/// UUPS (ERC-1967). Deploy behind an `ERC1967Proxy`; only the owner may authorize an upgrade or
/// rewire the ProtocolEngine. The reentrancy guard is the storage-namespaced OpenZeppelin v5
/// `ReentrancyGuard` (no initializer required).
contract InvestmentLifecycleEngine is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    IInvestmentLifecycleEngine
{
    /// @notice Basis-point denominator: 10,000 basis points == 100%. Allocation percentages are in BPS.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice The ProtocolEngine this orchestrator drives (reward calculation + triggers). Owner-updatable.
    address public override protocolEngine;

    /// @notice The LiquidityReserveEngine that liquidity allocations are forwarded to. Owner-updatable.
    /// @dev Zero until wired; while zero, forwarding is skipped (the allocation is still computed and
    ///      emitted). Set by the owner via {setLiquidityReserveEngine} after both proxies exist.
    address public override liquidityReserveEngine;

    /// @notice The InvestmentManager authorized to drive {processInvestment}. Owner-updatable.
    /// @dev The pipeline takes a caller-supplied amount, so restricting it to the manager (the only
    ///      source of a real, funded investment) prevents an arbitrary caller from triggering
    ///      amount-backed rewards. Zero until wired; while zero the restriction is inactive (see
    ///      {_requireInvestmentManager}). Deployment MUST wire it. Appended in the security-hardening phase.
    address public override investmentManager;

    /// @notice The RankEngine that deposit network effects (team volumes, level qualification,
    ///         rank promotions) are recorded with. Owner-updatable. Appended in the spec-v2 phase.
    /// @dev Zero until wired; while zero the rank stage is skipped (rank-driven rewards then pay
    ///      nothing — the ProtocolEngine is also fail-closed on an unwired RankEngine).
    address public override rankEngine;

    /// @notice Reserved storage slots (4 used + 46 reserved = 50) for forward-compatible upgrades.
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[46] private __gap;

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the orchestrator and wires the ProtocolEngine.
    /// @dev Callable exactly once, on the proxy. Both addresses must be non-zero.
    /// @param owner_ Protocol administrator.
    /// @param protocolEngine_ The ProtocolEngine that performs reward calculations and triggers.
    function initialize(address owner_, address protocolEngine_) external initializer {
        if (owner_ == address(0) || protocolEngine_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);

        protocolEngine = protocolEngine_;
    }

    // -------------------------------------------------------------------------
    // Owner configuration
    // -------------------------------------------------------------------------

    /// @notice Updates the ProtocolEngine address.
    /// @param newProtocolEngine The new ProtocolEngine address (non-zero).
    function setProtocolEngine(address newProtocolEngine) external onlyOwner {
        if (newProtocolEngine == address(0)) revert ZeroAddress();
        address previous = protocolEngine;
        protocolEngine = newProtocolEngine;
        emit ProtocolEngineUpdated(previous, newProtocolEngine);
    }

    /// @notice Updates the LiquidityReserveEngine that liquidity allocations are forwarded to.
    /// @param newLiquidityReserveEngine The new LiquidityReserveEngine address (non-zero).
    function setLiquidityReserveEngine(address newLiquidityReserveEngine) external onlyOwner {
        if (newLiquidityReserveEngine == address(0)) revert ZeroAddress();
        address previous = liquidityReserveEngine;
        liquidityReserveEngine = newLiquidityReserveEngine;
        emit LiquidityReserveEngineUpdated(previous, newLiquidityReserveEngine);
    }

    /// @notice Updates the InvestmentManager authorized to drive {processInvestment}.
    /// @param newInvestmentManager The new InvestmentManager address (non-zero).
    function setInvestmentManager(address newInvestmentManager) external onlyOwner {
        if (newInvestmentManager == address(0)) revert ZeroAddress();
        address previous = investmentManager;
        investmentManager = newInvestmentManager;
        emit InvestmentManagerUpdated(previous, newInvestmentManager);
    }

    /// @notice Updates the RankEngine that deposit network effects are recorded with.
    /// @param newRankEngine The new RankEngine address (non-zero).
    function setRankEngine(address newRankEngine) external onlyOwner {
        if (newRankEngine == address(0)) revert ZeroAddress();
        address previous = rankEngine;
        rankEngine = newRankEngine;
        emit RankEngineUpdated(previous, newRankEngine);
    }

    // -------------------------------------------------------------------------
    // Orchestration
    // -------------------------------------------------------------------------

    /// @inheritdoc IInvestmentLifecycleEngine
    /// @dev Post-investment pipeline. The engine coordinates modules but moves no funds and
    ///      calculates no rewards:
    ///      1. Validate the investor is a registered protocol user (else revert {InvalidInvestor}).
    ///      2. Split the investment into its liquidity and protocol allocations (accounting only —
    ///         see {_allocate}) and emit {LiquidityAllocated} / {ProtocolAllocated}. The protocol
    ///         share is the remainder, so `liquidity + protocol == investmentAmount` holds by
    ///         construction (rounding is absorbed by the protocol share). No funds move. When a
    ///         LiquidityReserveEngine is wired, the liquidity share is forwarded to it for reserve
    ///         accounting.
    ///      3. Trigger the direct referral reward via the ProtocolEngine (credits the referrer).
    ///      4. Trigger the infinity reward via the ProtocolEngine (distributes up the referral tree).
    ///      5. Signal weekly-reward eligibility ({WeeklyEligibilityMarked}) and daily-ROI activation
    ///         ({DailyROIActivated}).
    ///      6. Emit {InvestmentProcessed}.
    function processInvestment(address investor, uint256 investmentAmount) external override nonReentrant {
        // 0. Only the wired InvestmentManager may drive the pipeline (the amount is caller-supplied,
        //    so it must be backed by a real, funded investment recorded by the manager).
        _requireInvestmentManager();

        // 1. Validate the investor is a registered protocol user.
        _requireInvestor(investor);

        // 2. Split the investment: liquidity + protocol allocation (accounting only, no funds move),
        //    then forward the liquidity share to the reserve engine when one is wired.
        (uint256 liquidityAmount, uint256 protocolAmount) = _allocate(investmentAmount);
        emit LiquidityAllocated(investor, liquidityAmount);
        emit ProtocolAllocated(investor, protocolAmount);

        address reserve = liquidityReserveEngine;
        if (reserve != address(0)) {
            ILiquidityReserveEngine(reserve).recordLiquidityAllocation(liquidityAmount);
        }

        // 2.5. Record the deposit's network effects with the RankEngine (team volumes, level
        //      qualification, rank promotions) BEFORE any rank-driven reward is computed, so the
        //      rewards below always see the post-deposit qualification state. Skipped while unwired.
        address ranks = rankEngine;
        if (ranks != address(0)) {
            IRankEngine(ranks).recordDeposit(investor, investmentAmount);
        }

        IProtocolEngine engine = IProtocolEngine(protocolEngine);

        // 3. Trigger the direct referral reward (credits the investor's referrer — level 1).
        engine.processReferralReward(investor, investmentAmount);

        // 3.5. Trigger the level-income distribution (qualified uplines, levels 2..15).
        engine.processLevelReward(investor, investmentAmount);

        // 4. Trigger the infinity reward (nearest rank-gated achiever + upline achiever share).
        engine.processInfinityReward(investor, investmentAmount);

        // 5. Mark the investor eligible for the weekly reward, and activate the daily-ROI lifecycle.
        //    Both accrue from the active package the InvestmentManager created and are paid on
        //    schedule by the ProtocolEngine; these signal the stages for off-chain coordination.
        emit WeeklyEligibilityMarked(investor);
        emit DailyROIActivated(investor);

        // Future hooks slot in here (each coordinating a module without duplicating its logic):
        // the real liquidity/LP step (consuming `liquidityAmount`), re-topup, campaign rewards.

        // 6. Signal completion of the post-investment lifecycle.
        emit InvestmentProcessed(investor, investmentAmount, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IInvestmentLifecycleEngine
    function previewAllocation(uint256 investmentAmount)
        external
        view
        override
        returns (uint256 liquidityAmount, uint256 protocolAmount)
    {
        return _allocate(investmentAmount);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Reverts {InvalidInvestor} unless `investor` is a registered protocol user. The
    ///      registration source of truth is the InvestmentManager the ProtocolEngine is wired to,
    ///      so the orchestrator never duplicates user state.
    function _requireInvestor(address investor) private view {
        address manager = IProtocolEngine(protocolEngine).investmentManager();
        if (!IInvestmentManager(manager).isRegistered(investor)) revert InvalidInvestor();
    }

    /// @dev Reverts {UnauthorizedCaller} unless the caller is the wired InvestmentManager.
    ///      **Fail-closed:** while the manager is unset the guard reverts for *every* caller, so the
    ///      post-investment pipeline (which takes a caller-supplied amount) cannot be driven by an
    ///      arbitrary account during the deployment-wiring window — it stays disabled until the owner
    ///      wires the manager (see {setInvestmentManager}).
    function _requireInvestmentManager() private view {
        if (msg.sender != investmentManager) revert UnauthorizedCaller();
    }

    /// @dev Splits `investmentAmount` into its liquidity and protocol shares. The liquidity share
    ///      is `investmentAmount * liquidityAllocationPercentage / 10000`, read from the
    ///      ProtocolConfig (the ProtocolEngine is wired to it, so the percentage is never
    ///      hardcoded); the protocol share is the remainder. Constructing the protocol share as the
    ///      remainder guarantees `liquidityAmount + protocolAmount == investmentAmount` exactly —
    ///      any rounding-down of the liquidity share is absorbed by the protocol share. Since the
    ///      ProtocolConfig enforces the allocation percentages to sum to 100%, the liquidity
    ///      percentage never exceeds 100%, so the liquidity share never exceeds the investment and
    ///      the subtraction cannot underflow.
    /// @param investmentAmount The investment (or upgrade) amount, in USDT base units.
    /// @return liquidityAmount The liquidity allocation, in USDT base units.
    /// @return protocolAmount The protocol allocation (the remainder), in USDT base units.
    function _allocate(uint256 investmentAmount)
        private
        view
        returns (uint256 liquidityAmount, uint256 protocolAmount)
    {
        address protocolConfig = IProtocolEngine(protocolEngine).protocolConfig();
        uint256 liquidityBps = IProtocolConfig(protocolConfig).liquidityAllocationPercentage();

        liquidityAmount = (investmentAmount * liquidityBps) / BPS_DENOMINATOR;
        protocolAmount = investmentAmount - liquidityAmount;
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
