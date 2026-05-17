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
- `packages/sdk/src/perps-runtime.ts`
  - `loadFxPerpRuntimeConfig`
  - `parseFxPerpContractAddressesJson`
  - `assertFxPerpAddressesMatch`
  - `assertFxPerpLiveReadiness`
- Package export: `@bu/fx-engine/perps`.
- Package export: `@bu/fx-engine/perps-runtime`.
- SDK test that parses `deployments/perps-config-5042002.json`, validates
  readiness, and compares contract addresses against the SDK registry.
- SDK test that validates manifest/`CONTRACT_ADDRESSES_JSON` parity and proves
  the default manifest path resolves even when a worker starts from
  `packages/sdk`.
- Readiness command:
  `ARC_RPC_URL=https://rpc.testnet.arc.network bun run perps:arc:readiness`.

## Refactored

- `packages/sdk/scripts/perp-arc-trading-smoke.ts`
  - loads `ARC_PERP_CONFIG_PATH` or the repo's default
    `deployments/perps-config-5042002.json` through
    `loadFxPerpRuntimeConfig`;
  - checks optional `CONTRACT_ADDRESSES_JSON` parity before touching the live
    trading path;
  - runs `assertFxPerpLiveReadiness` before quote/order/settlement/funding/
    liquidation smoke actions;
  - derives USDC, FxOracle, six perps contract addresses, EURC base token, and
    EURC/USDC market id from the manifest;
  - keeps Pyth endpoint metadata in the SDK chain registry.

The live readiness gate verifies bytecode at every manifest contract, funding
links, AccessControl roles, all four market configs, all four funding configs,
liquidation config, protocol liquidity minimum, and margin USDC coverage for
`protocolLiquidity + totalAccountMargin`.

## Verification

```bash
cd packages/sdk && bun run typecheck
cd packages/sdk && bun test
cd packages/sdk && bun run build
cd packages/sdk && bun build scripts/perp-arc-trading-smoke.ts --target bun --outdir /tmp/fx-perp-smoke-build
bun run perps:arc:readiness
bun run perps:arc:config:verify
git diff --check
```

Results:

- SDK typecheck passed.
- SDK tests passed: `39` passed, `0` failed.
- SDK build passed.
- Trading smoke script bundled successfully without executing transactions.
- Live Arc SDK readiness gate passed:
  - `checkedContracts=6`
  - `checkedMarkets=EURC_USDC,TJPYC_USDC,TMXNB_USDC,TCHFC_USDC`
  - `protocolLiquidity=100100300`
  - `totalAccountMargin=599700`
  - `marginUsdcBalance=100700000`
- Live Arc config verifier passed.

No trading smoke or admin transaction was executed in this block.
