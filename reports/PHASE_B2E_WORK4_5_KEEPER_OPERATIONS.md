# Phase B2E Work 4/5 Keeper Operations

Date: 2026-05-17

Scope: long-running Arc keeper operations on top of the Phase B-E manifest and
live readiness gate.

## Added

- `packages/sdk/src/perps-keeper.ts`
  - JSON structured logger with bigint-safe serialization.
  - Manifest-gated Arc keeper context.
  - Idempotent matcher loop:
    - reads signed match intents from `PERP_MATCHES_JSON` or
      `PERP_MATCHES_FILE`;
    - derives stable match ids;
    - skips locally processed matches and on-chain used nonces before
      `settleMatch`;
    - persists match state in `PERP_KEEPER_STATE_PATH`.
  - Funding poke scheduler:
    - iterates all manifest markets;
    - reads `fundingState`;
    - skips markets until `PERP_FUNDING_MIN_INTERVAL_SECONDS` elapsed.
  - Liquidation scanner:
    - scans clearinghouse position events for candidate traders;
    - merges optional `PERP_LIQUIDATION_CANDIDATES`;
    - checks health, flag state, flag delay, and position size;
    - flags then liquidates through the deployed engine.
  - Read-only canary loop:
    - reruns live readiness;
    - quotes the configured canary markets, defaulting to `EURC_USDC`;
    - can refresh Pyth before quotes with `PERP_CANARY_REFRESH_PYTH=1`;
    - can hard-fail quote warnings with `PERP_CANARY_REQUIRE_QUOTE=1`;
    - logs funding version and open interest.
- Arc scripts:
  - `packages/sdk/scripts/perp-arc-keeper-loop.ts`
  - `packages/sdk/scripts/perp-arc-matcher-loop.ts`
  - `packages/sdk/scripts/perp-arc-funding-loop.ts`
  - `packages/sdk/scripts/perp-arc-liquidation-loop.ts`
  - `packages/sdk/scripts/perp-arc-canary-loop.ts`
- Package scripts:
  - `bun run perps:arc:keeper`
  - `bun run perps:arc:matcher`
  - `bun run perps:arc:funding`
  - `bun run perps:arc:liquidations`
  - `bun run perps:arc:canary`
- Package export: `@bu/fx-engine/perps-keeper`.

## Operator Contract

Every script calls `assertFxPerpLiveReadiness` before entering its loop. The
same checks cover contract bytecode, manifest parity, funding links, roles,
market/funding/liquidation params, protocol liquidity minimum, and margin USDC
coverage.

Transaction-sending loops require `PERP_KEEPER_PRIVATE_KEY` or
`DEPLOYER_PRIVATE_KEY`. `PERP_DRY_RUN=1` keeps the full decision path read-only.
The canary loop is read-only and can run without a private key.

## Verification

```bash
cd packages/sdk && bun run typecheck
cd packages/sdk && bun test
cd packages/sdk && bun run build
cd packages/sdk && bun build scripts/perp-arc-keeper-loop.ts scripts/perp-arc-matcher-loop.ts scripts/perp-arc-funding-loop.ts scripts/perp-arc-liquidation-loop.ts scripts/perp-arc-canary-loop.ts --target bun --outdir /tmp/fx-perp-keeper-build
ARC_RPC_URL=https://rpc.testnet.arc.network PERP_KEEPER_ONCE=1 bun run perps:arc:canary
bun run perps:arc:readiness
git diff --check
```

Results:

- SDK typecheck passed.
- SDK tests passed: `40` passed, `0` failed.
- SDK build passed.
- Keeper scripts bundled successfully.
- Live Arc readiness gate passed.
- Read-only live Arc canary loop ran one tick and exited successfully. It
  emitted `canary_quote_unavailable` with `quoteFailures=1` because the cached
  on-chain Pyth price was stale and the validation run intentionally did not
  send an oracle refresh transaction.

## Residual Risk

The matcher still needs a production order-source adapter. This block defines
the signed match intent contract and idempotent settlement loop; BUFX can now
feed it from an orderbook, queue, or agent process without hardcoding contract
addresses.

The canary defaults to `EURC_USDC` because the test-token markets are configured
for risk/readiness but should only be included with `PERP_CANARY_MARKETS=all`
after their live oracle quote path is confirmed.

Read-only canary mode logs stale oracle quote failures as structured warnings.
Hard monitoring should run with `PERP_CANARY_REFRESH_PYTH=1` plus
`PERP_CANARY_REQUIRE_QUOTE=1`, which requires the keeper key and sends the
oracle refresh transaction before quoting.
