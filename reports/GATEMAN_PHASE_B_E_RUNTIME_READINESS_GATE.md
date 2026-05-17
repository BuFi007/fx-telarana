# Gateman Analysis: Phase B-E Runtime Readiness Gate

Date: 2026-05-17

Scope: SDK runtime loader, `CONTRACT_ADDRESSES_JSON` parity check, live Arc
readiness gate, and the trading smoke preflight wiring.

## Verdict

No blocking findings for the current Arc testnet keeper handoff.

## Checks

- Assume nothing: the runtime loader validates manifest shape, rejects missing
  manifests by default, and rejects `CONTRACT_ADDRESSES_JSON` when any Phase B-E
  contract address diverges from `deployments/perps-config-5042002.json`.
- Question everything: the readiness gate reads live Arc state before any
  keeper-style smoke action and checks bytecode, funding links, roles,
  market/funding params, liquidation params, protocol liquidity, and margin USDC
  backing.
- Worship no one: the existing Foundry config verifier remains in place; the
  SDK gate is an independent viem read path over the same deployment manifest.
- Applaud humility: no admin or trading transaction was executed for this
  wiring block; the live check is deliberately read-only and fails closed.

## Evidence

- `cd packages/sdk && bun run typecheck`: passed.
- `cd packages/sdk && bun test`: `39` passed, `0` failed.
- `cd packages/sdk && bun run build`: passed.
- `cd packages/sdk && bun build scripts/perp-arc-trading-smoke.ts --target bun --outdir /tmp/fx-perp-smoke-build`: passed.
- `bun run perps:arc:readiness`: passed; `checkedContracts=6`,
  `protocolLiquidity=100100300`, `marginUsdcBalance=100700000`.
- `bun run perps:arc:config:verify`: passed.
- `git diff --check`: passed.

## Residual Risk

There are no long-running matcher, funding, or liquidation worker loops in this
repo yet. Work 4/5 should start those loops from `loadFxPerpRuntimeConfig` and
call `assertFxPerpLiveReadiness` before entering their polling loops.
