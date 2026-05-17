# Phase B-E Perp Stack Runbook

This runbook resolves the `CONTRACT_ADDRESSES_JSON` gap for the Phase B-E perps
backend. The six perps addresses are unavailable until these contracts are
deployed, because they do not exist in the Phase A deployment manifests.

No deployment is performed by this document. Broadcast requires explicit user
approval.

## Contracts

`DeployFxPerpStack.s.sol` deploys and wires:

- `FxMarginAccount` - USDC margin custody, reserved margin, protocol liquidity,
  realized PnL, and liquidator rewards.
- `FxPerpClearinghouse` - position lifecycle, oracle-priced notional, open
  interest caps, fees, PnL realization, and liquidation close path.
- `FxFundingEngine` - Perennial-style version-keyed funding accumulator.
- `FxHealthChecker` - Synthetix-style maintenance margin and liquidation check.
- `FxLiquidationEngine` - flag-then-liquidate flow and capped liquidator bounty.
- `FxOrderSettlement` - OZ EIP-712 + SignatureChecker maker/taker settlement.

The perps math helpers use OZ `Math.mulDiv` and `SafeCast`. Formula NatSpec
points to the vendored GMX Synthetics, Synthetix v3 BFP, and Perennial v2
reference shapes.

## Dry Run

Arc testnet dry-run:

```bash
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
USDC=0x3600000000000000000000000000000000000000 \
FX_ORACLE=0x77b3A3B420dB98B01085b8C46a753Ed9879e2865 \
INITIAL_ADMIN="$INITIAL_ADMIN" \
KEEPER=0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69 \
forge script contracts/script/DeployFxPerpStack.s.sol:DeployFxPerpStack \
  --root contracts \
  --rpc-url "$ARC_RPC_URL" \
  -vvvv
```

The script writes `deployments/perps-5042002.json` unless
`PERP_DEPLOYMENT_PATH` is set. It also prints a ready-to-inject
`CONTRACT_ADDRESSES_JSON` object.

## Broadcast Gate

Only after explicit approval, run the same command with `--broadcast`:

```bash
forge script contracts/script/DeployFxPerpStack.s.sol:DeployFxPerpStack \
  --root contracts \
  --rpc-url "$ARC_RPC_URL" \
  --broadcast \
  -vvvv
```

After broadcast, inject the printed JSON into the perps backend:

```bash
CONTRACT_ADDRESSES_JSON='{"5042002":{"FxPerpClearinghouse":"0x...","FxMarginAccount":"0x...","FxFundingEngine":"0x...","FxHealthChecker":"0x...","FxLiquidationEngine":"0x...","FxOrderSettlement":"0x..."}}'
```

## Config Readiness Manifest

After market/funding/liquidation params are configured on Arc, use the
read-only readiness scripts to prove and export the live state:

```bash
bun run perps:arc:config:verify
bun run perps:arc:config:export
```

`VerifyArcPerpConfig` reverts if any expected address, role, pointer, market
param, funding param, liquidation param, or minimum protocol liquidity check
diverges from the Arc trading stack.

`ExportArcPerpConfig` runs the same checks and writes
`deployments/perps-config-5042002.json`. The JSON is intentionally flat so
backend agents can parse it without a custom schema. It includes the six perps
contracts, oracle/USDC/admin/keeper, all four market ids and risk params,
funding params, liquidation params, open-interest readbacks, liquidity
readbacks, margin USDC balance, and role booleans.

SDK/keeper code should parse that manifest instead of copying addresses or
market ids:

```ts
import {
  assertFxPerpConfigReady,
  getFxPerpMarket,
  parseFxPerpConfigManifest,
} from "@bu/fx-engine/perps";

const manifest = parseFxPerpConfigManifest(JSON.parse(rawJson));
assertFxPerpConfigReady(manifest);
const eurcMarket = getFxPerpMarket(manifest, "EURC_USDC");
```

The Arc trading smoke follows this path and accepts `ARC_PERP_CONFIG_PATH` to
point at an alternate manifest.

Keeper/runtime code should use `@bu/fx-engine/perps-runtime` and
`@bu/fx-engine/perps-keeper`, not copied addresses:

```ts
import {
  assertFxPerpLiveReadiness,
  loadFxPerpRuntimeConfig,
} from "@bu/fx-engine/perps-runtime";
import { runFxPerpKeeperLoop } from "@bu/fx-engine/perps-keeper";

const runtime = loadFxPerpRuntimeConfig();
await assertFxPerpLiveReadiness(publicClient, runtime);
await runFxPerpKeeperLoop({ components: ["funding", "liquidation", "canary"] });
```

Useful env overrides:

- `ARC_PERP_CONFIG_PATH`
- `ARC_PERP_CLEARINGHOUSE`
- `ARC_PERP_MARGIN`
- `ARC_PERP_FUNDING`
- `ARC_PERP_HEALTH`
- `ARC_PERP_LIQUIDATION`
- `ARC_PERP_SETTLEMENT`
- `ARC_PERP_MIN_PROTOCOL_LIQUIDITY`

## Keeper Operations

All Arc keeper scripts fail closed unless the live readiness gate passes first:

```bash
# Read-only canary loop; use ONCE in CI or manual checks.
ARC_RPC_URL=https://rpc.testnet.arc.network PERP_KEEPER_ONCE=1 bun run perps:arc:canary

# Long-running funding scheduler.
PERP_KEEPER_PRIVATE_KEY=0x... ARC_RPC_URL=https://rpc.testnet.arc.network bun run perps:arc:funding

# Idempotent signed-order matcher.
PERP_KEEPER_PRIVATE_KEY=0x... PERP_MATCHES_FILE=./orders.ndjson bun run perps:arc:matcher

# Event-backed liquidation scanner with optional manual candidates.
PERP_KEEPER_PRIVATE_KEY=0x... PERP_LIQUIDATION_CANDIDATES='{"EURC_USDC":["0x..."]}' bun run perps:arc:liquidations

# Sequential all-in-one loop.
PERP_KEEPER_PRIVATE_KEY=0x... bun run perps:arc:keeper
```

Operational env:

- `PERP_KEEPER_STATE_PATH` defaults to `.keeper/perps-5042002-state.json`.
  It records settled match ids and the next liquidation event scan block.
- `PERP_DRY_RUN=1` performs readiness, parsing, candidate discovery, and
  decision logging without sending transactions.
- `PERP_KEEPER_INTERVAL_MS` controls loop cadence.
- `PERP_KEEPER_ONCE=1` runs one tick and exits.
- `PERP_FUNDING_MIN_INTERVAL_SECONDS` prevents zero-elapsed funding pokes.
- `PERP_MATCHES_JSON` or `PERP_MATCHES_FILE` provides signed maker/taker match
  intents. The matcher skips already-used nonces before sending.
- `PERP_LIQUIDATION_SCAN_FROM_BLOCK` and `PERP_LIQUIDATION_SCAN_BLOCK_RANGE`
  tune event-based candidate discovery.
- `PERP_CANARY_MARKETS` defaults to `EURC_USDC`; use `all` only once every
  configured market has a live oracle quote path.
- `PERP_CANARY_REFRESH_PYTH=1` sends the Pyth refresh through `FxOracle` before
  quote checks and requires a keeper key.
- `PERP_CANARY_REQUIRE_QUOTE=1` turns quote warnings into a non-zero process
  exit for hard monitoring.

## Post-Deploy Admin Steps

Before any live testnet open, execute explicit admin transactions for:

- `FxPerpClearinghouse.configureMarket`
- `FxFundingEngine.configureFunding`
- `FxLiquidationEngine.configureLiquidation`
- `FxMarginAccount.depositProtocolLiquidity`

The deploy script intentionally does not invent market risk parameters. The
unit tests use 5 bps trading fee, 5% initial margin, 3% maintenance margin, and
bounded test OI only as test fixtures.

## Verification

Run:

```bash
forge test --root contracts --offline --match-path 'test/perp/*.t.sol' -vv
forge build --root contracts --offline --sizes
```

Expected perps coverage:

- unit and role tests for margin, clearinghouse, funding, liquidation, and
  EIP-712 order settlement;
- 256-run fuzz for required-margin math;
- 256-run invariants for cash backing and open-interest caps.
