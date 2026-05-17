# Gateman Analysis: Phase B-E Keeper Operations

Date: 2026-05-17

Scope: `perps-keeper` SDK module, Arc keeper scripts, matcher/funding/
liquidation/canary loops, structured logs, docs, and operator runbook.

## Verdict

No blocking findings for the current Arc testnet keeper handoff.

## Checks

- Assume nothing: every loop starts by loading the manifest through the SDK
  runtime loader and passing `assertFxPerpLiveReadiness`; no Phase B-E contract
  address is copied into the loop scripts.
- Question everything: matcher settlement checks local processed state and
  on-chain nonce bitmaps before sending `settleMatch`; funding reads
  `fundingState` and skips zero-elapsed pokes; liquidation reads position,
  health, flag state, and flag delay before flag/liquidate.
- Worship no one: the canary does not pretend stale oracle quotes are healthy.
  Read-only mode logs `canary_quote_unavailable`; hard monitoring can require
  quote success after an explicit Pyth refresh transaction.
- Applaud humility: the matcher order source remains intentionally generic
  (`PERP_MATCHES_JSON`/`PERP_MATCHES_FILE`) until BUFX supplies the production
  queue/orderbook adapter.

## Evidence

- `cd packages/sdk && bun run typecheck`: passed.
- `cd packages/sdk && bun test`: `40` passed, `0` failed.
- `cd packages/sdk && bun run build`: passed.
- `cd packages/sdk && bun build scripts/perp-arc-keeper-loop.ts scripts/perp-arc-matcher-loop.ts scripts/perp-arc-funding-loop.ts scripts/perp-arc-liquidation-loop.ts scripts/perp-arc-canary-loop.ts --target bun --outdir /tmp/fx-perp-keeper-build`: passed.
- `bun run perps:arc:readiness`: passed against live Arc.
- `ARC_RPC_URL=https://rpc.testnet.arc.network PERP_KEEPER_ONCE=1 PERP_KEEPER_STATE_PATH=/tmp/fx-perp-canary-state.json bun run perps:arc:canary`: exited successfully with a structured stale-quote warning.
- `git diff --check`: passed.

## Residual Risk

The hard quote canary was not run because it requires the keeper key and sends a
Pyth refresh transaction. Use `PERP_CANARY_REFRESH_PYTH=1
PERP_CANARY_REQUIRE_QUOTE=1` for that production check.
