# Aurex Keeper

Automation runner for the Aurex protocol's daily reward processing on BNB Smart Chain.

This repository contains only what the scheduled runner needs:

- `contracts/` — the protocol sources (the same code verified on BscScan), present so the
  keeper script compiles against the exact deployed interfaces.
- `script/Keeper.s.sol` — the keeper: refreshes the ARX/USDT conversion price from the
  PancakeSwap pair and calls `processDailyROI` / `processWeeklyReward` for every
  registered user.
- `.github/workflows/keeper.yml` — the schedule (23:50 / 10:00 / 18:00 UTC; the
  23:50 run is the daily payout, the others are idempotent safety re-runs).

## Security model

- `processDailyROI` is **permissionless by design** — the keeper wallet holds no protocol
  authority beyond the delegated price-updater role, and the private key exists only as a
  GitHub Actions secret, never in this repository.
- Workflows trigger on `schedule` and `workflow_dispatch` only. There are no `push` or
  `pull_request` triggers, so no third-party contribution can ever execute a workflow here.
- The workflow's `GITHUB_TOKEN` is restricted to read access.
- Runs are idempotent: already-processed periods are skipped on re-runs.

The heartbeat workflow commits a timestamp monthly so GitHub's 60-day inactivity rule
never silently disables the schedule.
