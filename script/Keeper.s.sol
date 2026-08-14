// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {InvestmentManager} from "../contracts/Core/InvestmentManager.sol";
import {ProtocolConfig} from "../contracts/Core/ProtocolConfig.sol";
import {ProtocolEngine} from "../contracts/Core/ProtocolEngine.sol";
import {ProtocolScheduler} from "../contracts/Core/ProtocolScheduler.sol";

/// @title Keeper
/// @author Aurex Protocol
/// @notice Operational keeper for the reward pipeline. Discovers every registered user from
///         `UserRegistered` events (chunked `eth_getLogs`, starting at the deployment
///         block), then drives the two permissionless triggers once per period per user:
///         {ProtocolEngine.processDailyROI} and {ProtocolEngine.processWeeklyReward}.
///         Failed calls are caught, retried once, and reported — one bad user cannot
///         block the rest of the run.
/// @dev Idempotent by construction: the {ProtocolScheduler} `canProcessDaily` /
///      `canProcessWeekly` guards make re-runs no-ops for already-processed users, so the
///      script is safe to execute on any schedule (cron once per hour is fine). The
///      broadcasting key needs no authorization — only gas. Run once per protocol day.
///
///      Environment:
///        PROTOCOL_ENGINE_ADDRESS     required
///        PROTOCOL_SCHEDULER_ADDRESS  required
///        PROTOCOL_CONFIG_ADDRESS     required
///        INVESTMENT_MANAGER_ADDRESS  required (UserRegistered event source)
///        DEPLOYMENT_BLOCK            required, non-zero (log-scan floor)
///        KEEPER_LOG_CHUNK            optional, default 50,000 blocks per getLogs call
///        ARX_PRICE_USDT              optional — target ARX price in USDT base units per whole
///                                    ARX. When set, the keeper refreshes the on-chain price
///                                    BEFORE processing any ROI, so the day's payouts convert at
///                                    the current rate. Requires the broadcasting key to be the
///                                    configured `arxPriceUpdater`. Unset leaves the price alone.
///        KEEPER_USER_START          optional, default 0 — first registry index to process
///        KEEPER_USER_COUNT          optional, default 0 (= all remaining) — how many users this
///                                    run handles. Public BSC RPCs prune state within ~seconds,
///                                    and a whole-network run's simulation outlives the forked
///                                    block ("missing trie node") once the user count grows past
///                                    roughly forty. Slicing keeps each run short enough to
///                                    complete against a non-archive node. Runs are independent
///                                    and idempotent, so a full sweep is just a loop over slices.
///
///      Usage (cron):
///        forge script script/Keeper.s.sol:Keeper --rpc-url $RPC_URL --broadcast
contract Keeper is Script {
    /// @dev keccak256("UserRegistered(address,address)") — topic0 of the discovery event.
    bytes32 internal constant USER_REGISTERED_TOPIC = keccak256("UserRegistered(address,address)");

    /// @dev Basis-point denominator, mirroring {ProtocolConfig.BPS_DENOMINATOR}.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Per-period processing counters for the summary.
    struct Stats {
        uint256 processed;
        uint256 skipped;
        uint256 failed;
        uint256 retried;
    }

    /// @notice Discovers users and processes every due daily/weekly period.
    function run() external {
        ProtocolEngine engine = ProtocolEngine(vm.envAddress("PROTOCOL_ENGINE_ADDRESS"));
        ProtocolScheduler scheduler = ProtocolScheduler(vm.envAddress("PROTOCOL_SCHEDULER_ADDRESS"));
        ProtocolConfig config = ProtocolConfig(vm.envAddress("PROTOCOL_CONFIG_ADDRESS"));
        address investmentManager = vm.envAddress("INVESTMENT_MANAGER_ADDRESS");
        uint256 fromBlock = vm.envOr("DEPLOYMENT_BLOCK", uint256(0));
        require(fromBlock != 0, "Keeper: set DEPLOYMENT_BLOCK (log-scan floor); scanning from genesis is not viable");

        address[] memory users = _slice(_discoverUsers(investmentManager, fromBlock));
        console2.log("Keeper: users to process this run:", users.length);

        bool weeklyEnabled = config.weeklyRewardEnabled();
        Stats memory daily;
        Stats memory weekly;

        vm.startBroadcast();
        // Refresh the conversion price FIRST: processDailyROI reads it live, so a stale price
        // here would misprice the whole run's payouts.
        _refreshArxPrice(config);
        for (uint256 i = 0; i < users.length; i++) {
            _processDaily(engine, scheduler, users[i], daily);
            if (weeklyEnabled) {
                _processWeekly(engine, scheduler, users[i], weekly);
            }
        }
        vm.stopBroadcast();

        console2.log("=== Keeper summary ===");
        console2.log("Protocol day:              ", scheduler.currentDay());
        console2.log("Users discovered:          ", users.length);
        console2.log("Daily  processed/skipped:  ", daily.processed, daily.skipped);
        console2.log("Daily  failed (after retry):", daily.failed);
        console2.log("Daily  recovered by retry: ", daily.retried);
        console2.log("Weekly enabled:            ", weeklyEnabled);
        console2.log("Weekly processed/skipped:  ", weekly.processed, weekly.skipped);
        console2.log("Weekly failed (after retry):", weekly.failed);
        console2.log("Weekly recovered by retry: ", weekly.retried);
        console2.log("Safe to re-run at any time: already-processed periods are skipped.");
    }

    /// @dev Narrows the discovered set to this run's slice. Returns the input untouched when no
    ///      slicing is configured, so single-run deployments behave exactly as before.
    function _slice(address[] memory all) internal view returns (address[] memory) {
        uint256 start = vm.envOr("KEEPER_USER_START", uint256(0));
        uint256 count = vm.envOr("KEEPER_USER_COUNT", uint256(0));
        if (start == 0 && count == 0) return all;
        if (start >= all.length) return new address[](0);

        uint256 end = count == 0 ? all.length : start + count;
        if (end > all.length) end = all.length;

        address[] memory out = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = all[i];
        }
        console2.log("Keeper: slice", start, "..", end - 1);
        return out;
    }

    /// @dev Pushes the day's ARX price before any ROI is processed. No-op when `ARX_PRICE_USDT`
    ///      is unset, so existing deployments keep their current behaviour.
    ///
    ///      A target further away than the config's deviation bound is CLAMPED to the largest
    ///      permitted move rather than being sent as-is and reverting. That keeps the guard
    ///      meaningful without ever failing the run: a large genuine re-pricing walks toward the
    ///      target over several days, and a bad target (manipulated spot, fat-fingered env var)
    ///      is capped at one step and stays visible in the logs for the operator to catch.
    function _refreshArxPrice(ProtocolConfig config) internal {
        uint256 target = vm.envOr("ARX_PRICE_USDT", uint256(0));
        if (target == 0) {
            console2.log("Keeper: ARX_PRICE_USDT unset - on-chain price left unchanged");
            return;
        }

        uint256 current = config.arxPriceUSDT();
        if (current == target) {
            console2.log("Keeper: ARX price already at target:", target);
            return;
        }

        uint256 bounded = _clampToDeviation(current, target, config.arxPriceMaxDeviationBps());
        if (bounded != target) {
            console2.log("Keeper: target clamped by deviation bound. target/applied:", target, bounded);
        }

        try config.updateArxPrice(bounded) {
            console2.log("Keeper: ARX price updated. previous/current:", current, bounded);
        } catch {
            console2.log("Keeper: ARX price update FAILED (is this key the arxPriceUpdater?). current:", current);
        }
    }

    /// @dev Clamps `target` to within `maxDeviationBps` of `current`. Returns `target` unchanged
    ///      when there is no baseline (`current == 0`) or no bound configured.
    function _clampToDeviation(uint256 current, uint256 target, uint256 maxDeviationBps)
        internal
        pure
        returns (uint256)
    {
        if (current == 0 || maxDeviationBps == 0) return target;
        uint256 maxMove = (current * maxDeviationBps) / BPS_DENOMINATOR;
        if (target > current) {
            uint256 ceiling = current + maxMove;
            return target > ceiling ? ceiling : target;
        }
        uint256 floor_ = current - maxMove; // maxMove <= current, since maxDeviationBps <= BPS
        return target < floor_ ? floor_ : target;
    }

    /// @dev Discovers registered users. Preferred source: the InvestmentManager's ON-CHAIN
    ///      network registry (`registeredUserCount`/`userAt` — no `eth_getLogs` dependency,
    ///      reliable on every RPC). Falls back to the historical chunked log scan only when the
    ///      registry is empty (pre-registry deployments).
    function _discoverUsers(address investmentManager, uint256 fromBlock) internal returns (address[] memory users) {
        InvestmentManager manager = InvestmentManager(investmentManager);
        try manager.registeredUserCount() returns (uint256 count) {
            if (count != 0) {
                users = new address[](count);
                for (uint256 i = 0; i < count; i++) {
                    users[i] = manager.userAt(i);
                }
                return users;
            }
        } catch {} // registry not present on this deployment — fall through to the log scan
        return _discoverUsersFromLogs(investmentManager, fromBlock);
    }

    /// @dev Scans `UserRegistered` logs in chunks and returns the registered users.
    ///      Each user registers exactly once (the contract rejects re-registration), so
    ///      the log set is already duplicate-free.
    function _discoverUsersFromLogs(address investmentManager, uint256 fromBlock)
        internal
        returns (address[] memory users)
    {
        uint256 chunk = vm.envOr("KEEPER_LOG_CHUNK", uint256(50_000));
        require(chunk != 0, "Keeper: KEEPER_LOG_CHUNK must be non-zero");
        uint256 latest = block.number;

        bytes32[] memory topics = new bytes32[](1);
        topics[0] = USER_REGISTERED_TOPIC;

        // Collect chunk results, then flatten once sizes are known.
        uint256 total;
        VmSafe.EthGetLogs[][] memory batches = new VmSafe.EthGetLogs[][]((latest - fromBlock) / chunk + 1);
        uint256 batchCount;
        for (uint256 start = fromBlock; start <= latest; start += chunk) {
            uint256 end = start + chunk - 1;
            if (end > latest) end = latest;
            VmSafe.EthGetLogs[] memory logs = vm.eth_getLogs(start, end, investmentManager, topics);
            batches[batchCount++] = logs;
            total += logs.length;
        }

        users = new address[](total);
        uint256 idx;
        for (uint256 b = 0; b < batchCount; b++) {
            for (uint256 i = 0; i < batches[b].length; i++) {
                // topic1 = indexed user address.
                users[idx++] = address(uint160(uint256(batches[b][i].topics[1])));
            }
        }
    }

    /// @dev Processes one user's daily ROI with a single retry on failure.
    function _processDaily(ProtocolEngine engine, ProtocolScheduler scheduler, address user, Stats memory s) internal {
        if (!scheduler.canProcessDaily(user)) {
            s.skipped++;
            return;
        }
        try engine.processDailyROI(user) {
            s.processed++;
        } catch {
            try engine.processDailyROI(user) {
                s.processed++;
                s.retried++;
            } catch {
                s.failed++;
                console2.log("Keeper: daily processing failed for", user);
            }
        }
    }

    /// @dev Processes one user's weekly rank bonus with a single retry on failure. The
    ///      installment ledger self-gates (nothing marks the scheduler anymore), so a
    ///      transaction is only broadcast when something is actually due.
    function _processWeekly(ProtocolEngine engine, ProtocolScheduler scheduler, address user, Stats memory s) internal {
        if (!scheduler.canProcessWeekly(user) || engine.previewWeeklyReward(user) == 0) {
            s.skipped++;
            return;
        }
        try engine.processWeeklyReward(user) {
            s.processed++;
        } catch {
            try engine.processWeeklyReward(user) {
                s.processed++;
                s.retried++;
            } catch {
                s.failed++;
                console2.log("Keeper: weekly processing failed for", user);
            }
        }
    }
}
