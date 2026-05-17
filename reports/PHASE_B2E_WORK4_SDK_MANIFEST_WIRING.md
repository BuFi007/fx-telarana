# Phase B2E Work 4 SDK Manifest Wiring

Date: 2026-05-17

Scope: SDK and keeper/smoke wiring so Phase B-E agents consume
`deployments/perps-config-5042002.json` instead of copying live Arc perps
addresses, market ids, and risk params into scripts.

## Added

- `packages/sdk/src/perps.ts`
  - `parseFxPerpConfigManifest`
  - `assertFxPerpConfigReady`
  - `getFxPerpMarket`
  - `fxPerpsAddressesFromConfigManifest`
  - `fxPerpContractAddressesJson`
- Package export: `@bu/fx-engine/perps`.
- SDK test that parses `deployments/perps-config-5042002.json`, validates
  readiness, and compares contract addresses against the SDK registry.

## Refactored

- `packages/sdk/scripts/perp-arc-trading-smoke.ts`
  - reads `ARC_PERP_CONFIG_PATH` or defaults to
    `deployments/perps-config-5042002.json`;
  - derives USDC, FxOracle, six perps contract addresses, EURC base token, and
    EURC/USDC market id from the manifest;
  - keeps Pyth endpoint metadata in the SDK chain registry.

## Verification

```bash
cd packages/sdk && bun run typecheck
cd packages/sdk && bun test
cd packages/sdk && bun run build
cd packages/sdk && bun build scripts/perp-arc-trading-smoke.ts --target bun --outdir /tmp/fx-perp-smoke-build
bun run perps:arc:config:verify
git diff --check
```

Results:

- SDK typecheck passed.
- SDK tests passed: `38` passed, `0` failed.
- SDK build passed.
- Trading smoke script bundled successfully without executing transactions.
- Live Arc config verifier passed.

No trading smoke or admin transaction was executed in this block.
