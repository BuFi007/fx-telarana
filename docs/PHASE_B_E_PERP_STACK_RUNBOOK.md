# Phase B-E Perp Stack Runbook

This runbook resolves the `CONTRACT_ADDRESSES_JSON` gap for the Phase B-E perps
backend. The six perps addresses are unavailable until these contracts are
deployed, because they do not exist in the Phase A deployment manifests.

No deployment is performed by this document. Broadcast requires explicit user
approval.

The broader tomorrow broadcast target list lives in
`docs/TOMORROW_BROADCAST_TEST_TARGETS.md`.

## Safety Gates

Do not publish new perp addresses to integrators until all of these are true:

- The supplied `FX_ORACLE` passes `DeployFxPerpStack._verifySprint1Oracle`, or
  a fresh sprint-1 `FxOracle` is deployed in the same broadcast plan and passed
  as `FX_ORACLE`.
- The chain-specific configure broadcast has landed for the same addresses:
  `ConfigureFujiPerpMarkets` on Fuji and `ConfigureArcPerpMarkets` on Arc.
- The readback verifier/exporter passes on the live chain and shows
  `liquidation_flagDelay >= 60` (`120` expected).
- The old clearinghouse and liquidation engine for that chain are retired with
  `RetireOldPerpStack`.
- Keeper liquidation traffic uses RedStone-wrapped tx calldata for
  `flagAccount`, `rescindFlag`, and `liquidate`.

## Contracts

`DeployPerpOracle.s.sol` deploys the sprint-1 `FxOracle` required by the perps
stack and wires the chain-specific perps feeds:

- Fuji: USDC, EURC, MXNB.
- Arc: USDC, EURC, tJPYC, tMXNB, tCHFC.

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

Deploy a fresh sprint-1 perps oracle first. The currently deployed historical
hub oracles on Fuji and Arc must not be reused for sprint-1 perps unless the
selector readback below proves they expose the hard-cap selectors.

Fuji oracle dry-run:

```bash
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
PERP_ORACLE_DEPLOYMENT_PATH=../deployments/perp-oracle-43113.json \
forge script contracts/script/DeployPerpOracle.s.sol:DeployPerpOracle \
  --root contracts \
  --rpc-url "$FUJI_RPC_URL" \
  -vvvv
```

Arc oracle dry-run:

```bash
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
PERP_ORACLE_DEPLOYMENT_PATH=../deployments/perp-oracle-5042002.json \
forge script contracts/script/DeployPerpOracle.s.sol:DeployPerpOracle \
  --root contracts \
  --rpc-url "$ARC_RPC_URL" \
  -vvvv
```

Arc testnet dry-run:

```bash
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
USDC=0x3600000000000000000000000000000000000000 \
FX_ORACLE="$(jq -r .FxOracle deployments/perp-oracle-5042002.json)" \
INITIAL_ADMIN="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")" \
KEEPER=0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69 \
forge script contracts/script/DeployFxPerpStack.s.sol:DeployFxPerpStack \
  --root contracts \
  --rpc-url "$ARC_RPC_URL" \
  -vvvv
```

Either deploy a fresh FxOracle in the same broadcast OR confirm the supplied
FX_ORACLE address passes `_verifySprint1Oracle`.

Fuji dry-run is the same generic deploy script with Fuji env:

```bash
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
USDC=0x5425890298aed601595a70AB815c96711a31Bc65 \
FX_ORACLE="$(jq -r .FxOracle deployments/perp-oracle-43113.json)" \
INITIAL_ADMIN="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")" \
KEEPER=0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69 \
PERP_DEPLOYMENT_PATH=../deployments/perps-43113.json \
forge script contracts/script/DeployFxPerpStack.s.sol:DeployFxPerpStack \
  --root contracts \
  --rpc-url "$FUJI_RPC_URL" \
  -vvvv
```

The script writes `deployments/perps-5042002.json` unless
`PERP_DEPLOYMENT_PATH` is set. It also prints a ready-to-inject
`CONTRACT_ADDRESSES_JSON` object.

`INITIAL_ADMIN` must equal the deployer for this bootstrap script because the
same broadcast wires roles and applies safe liquidation defaults. Do not hand
off admin roles to timelock/multisig until after configure, export, and
old-stack retirement have passed.

## Broadcast Gate

Only after explicit approval, run the same commands with `--broadcast`. Oracle
broadcast comes first, then the perps stack:

```bash
forge script contracts/script/DeployPerpOracle.s.sol:DeployPerpOracle \
  --root contracts \
  --rpc-url "$ARC_RPC_URL" \
  --broadcast \
  -vvvv

forge script contracts/script/DeployFxPerpStack.s.sol:DeployFxPerpStack \
  --root contracts \
  --rpc-url "$ARC_RPC_URL" \
  --broadcast \
  -vvvv
```

After broadcast, keep the printed JSON locally. Do not inject or publish it
until the chain-specific configure broadcast and readback gate below pass:

```bash
CONTRACT_ADDRESSES_JSON='{"5042002":{"FxPerpClearinghouse":"0x...","FxMarginAccount":"0x...","FxFundingEngine":"0x...","FxHealthChecker":"0x...","FxLiquidationEngine":"0x...","FxOrderSettlement":"0x..."}}'
```

## Configure Before Publishing

The generic deploy script deploys, wires roles, and applies only the shared
safe liquidation defaults. It intentionally does not invent market, funding, or
liquidity params. For redeploys, the configure broadcast is mandatory before
any backend, keeper, dashboard, or integrator address cutover.

Fuji:

```bash
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
FUJI_PERP_CLEARINGHOUSE=0x... \
FUJI_PERP_MARGIN=0x... \
FUJI_PERP_FUNDING=0x... \
FUJI_PERP_LIQUIDATION=0x... \
forge script contracts/script/ConfigureFujiPerpMarkets.s.sol:ConfigureFujiPerpMarkets \
  --root contracts \
  --rpc-url "$FUJI_RPC_URL" \
  --broadcast \
  -vvvv
```

Arc:

```bash
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
ARC_PERP_CLEARINGHOUSE=0x... \
ARC_PERP_MARGIN=0x... \
ARC_PERP_FUNDING=0x... \
ARC_PERP_LIQUIDATION=0x... \
forge script contracts/script/ConfigureArcPerpMarkets.s.sol:ConfigureArcPerpMarkets \
  --root contracts \
  --rpc-url "$ARC_RPC_URL" \
  --broadcast \
  -vvvv
```

Both scripts configure `bountyBps=500`, `bountyCap=5e6` USDC raw units, and
`flagDelay=120`. They refuse unsafe configured constants below 60 seconds.

## Config Readiness Manifest

After market/funding/liquidation params are configured, use the read-only
readiness scripts to prove and export the live state.

```bash
# Arc
ARC_PERP_CLEARINGHOUSE=0x... \
ARC_PERP_MARGIN=0x... \
ARC_PERP_FUNDING=0x... \
ARC_PERP_HEALTH=0x... \
ARC_PERP_LIQUIDATION=0x... \
ARC_PERP_SETTLEMENT=0x... \
ARC_FX_ORACLE=0x... \
bun run perps:arc:config:verify

ARC_PERP_CLEARINGHOUSE=0x... \
ARC_PERP_MARGIN=0x... \
ARC_PERP_FUNDING=0x... \
ARC_PERP_HEALTH=0x... \
ARC_PERP_LIQUIDATION=0x... \
ARC_PERP_SETTLEMENT=0x... \
ARC_FX_ORACLE=0x... \
bun run perps:arc:config:export

# Fuji
FUJI_PERP_CLEARINGHOUSE=0x... \
FUJI_PERP_MARGIN=0x... \
FUJI_PERP_FUNDING=0x... \
FUJI_PERP_HEALTH=0x... \
FUJI_PERP_LIQUIDATION=0x... \
FUJI_PERP_SETTLEMENT=0x... \
FUJI_FX_ORACLE=0x... \
forge script contracts/script/FujiPerpConfigReadiness.s.sol:VerifyFujiPerpConfig \
  --root contracts --rpc-url "$FUJI_RPC_URL" -vv

FUJI_PERP_CLEARINGHOUSE=0x... \
FUJI_PERP_MARGIN=0x... \
FUJI_PERP_FUNDING=0x... \
FUJI_PERP_HEALTH=0x... \
FUJI_PERP_LIQUIDATION=0x... \
FUJI_PERP_SETTLEMENT=0x... \
FUJI_FX_ORACLE=0x... \
forge script contracts/script/FujiPerpConfigReadiness.s.sol:ExportFujiPerpConfig \
  --root contracts --rpc-url "$FUJI_RPC_URL" -q
```

The configure/readiness scripts require explicit fresh-stack addresses. They do
not default to the old live 0x2201/0xED58 Fuji stack or 0x6A26/0xD384 Arc stack.
Readiness also requires an explicit fresh `FUJI_FX_ORACLE` / `ARC_FX_ORACLE` so
stale historical hub oracles cannot pass by omission.

`VerifyArcPerpConfig` and `VerifyFujiPerpConfig` revert if any expected
address, role, pointer, market param, funding param, liquidation param, or
minimum protocol liquidity check diverges from the chain stack. The readback
gate must also prove `liquidation.flagDelay >= 60`.

`ExportArcPerpConfig` writes `deployments/perps-config-5042002.json`.
`ExportFujiPerpConfig` writes `deployments/perps-config-43113.json`. The JSON is
intentionally flat so backend agents can parse it without a custom schema. It
includes the six perps contracts, oracle/USDC/admin/keeper, market ids and risk
params, funding params, liquidation params, open-interest readbacks, liquidity
readbacks, margin USDC balance, and role booleans.

Post-deploy readback gate:

```bash
cast call "$FX_ORACLE" "MAX_ORACLE_AGE_HARD_CAP()(uint256)" --rpc-url "$RPC_URL"
cast call "$FX_ORACLE" "MAX_DEVIATION_BPS_HARD_CAP()(uint256)" --rpc-url "$RPC_URL"
cast call "$FX_ORACLE" "MAX_CONFIDENCE_BPS_HARD_CAP()(uint256)" --rpc-url "$RPC_URL"
cast call "$FX_ORACLE" "config()(uint256,uint256,uint256)" --rpc-url "$RPC_URL"
```

Expected oracle caps: `1800`, `500`, `500`. `config()` values must be non-zero
and within those caps.

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
- `FUJI_PERP_CONFIG_PATH`
- `FUJI_PERP_CLEARINGHOUSE`
- `FUJI_PERP_MARGIN`
- `FUJI_PERP_FUNDING`
- `FUJI_PERP_HEALTH`
- `FUJI_PERP_LIQUIDATION`
- `FUJI_PERP_SETTLEMENT`
- `FUJI_PERP_MIN_PROTOCOL_LIQUIDITY`

## Retire Old Stack

Run this after new addresses are configured and proven, before keeper traffic
moves:

```bash
# Fuji defaults retire:
#   clearinghouse 0x22013f712190034D8Ee43F3894461c27709E74AC
#   liquidation   0xED58C176E9a37Cda2854AC0Ade409cfb3687cA7d
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
forge script contracts/script/RetireOldPerpStack.s.sol:RetireOldPerpStack \
  --root contracts --rpc-url "$FUJI_RPC_URL" --broadcast -vvvv

# Arc defaults retire:
#   clearinghouse 0x6A265045D9A3291D2881d77DDC62e2781A2418c5
#   liquidation   0xD384560E5f8CE969BF4C1BDfAFACc5304AFbe8f2
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
forge script contracts/script/RetireOldPerpStack.s.sol:RetireOldPerpStack \
  --root contracts --rpc-url "$ARC_RPC_URL" --broadcast -vvvv
```

The script revokes `LIQUIDATION_ENGINE_ROLE` from the old engine on the old
clearinghouse, then pauses the old clearinghouse and old liquidation engine.

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

# One-shot RedStone payload smoke for flagAccount.
PERP_KEEPER_PRIVATE_KEY=0x... PERP_REDSTONE_SMOKE_TRADER=0x... bun run perps:arc:redstone-smoke

# Sequential all-in-one loop.
PERP_KEEPER_PRIVATE_KEY=0x... bun run perps:arc:keeper
```

`flagAccount`, `rescindFlag`, and `liquidate` must be sent through
`writeWithRedstone`. The helper encodes the function call, fetches a RedStone
payload for the market base token and USDC quote feed from
`FxOracle.redstoneFeedOf`, appends it to calldata, and sends a raw transaction.
Funding pokes, matcher writes, and canary checks stay plain `writeContract`.

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
- `REDSTONE_DATA_SERVICE_ID` defaults to `redstone-primary-prod`.
- `REDSTONE_UNIQUE_SIGNERS_COUNT` defaults to `3`.
- `REDSTONE_AUTHORIZED_SIGNERS` can override signer addresses as a comma
  separated list.

## Post-Deploy Admin Steps

Before any live testnet open, execute explicit admin transactions for:

- `FxPerpClearinghouse.configureMarket`
- `FxFundingEngine.configureFunding`
- `FxMarginAccount.depositProtocolLiquidity`

The deploy script configures only the shared liquidation defaults
(`bountyBps=500`, `bountyCap=5e6`, `flagDelay=120`). It intentionally does not
invent market/funding risk parameters. The unit tests use 5 bps trading fee, 5%
initial margin, 3% maintenance margin, and bounded test OI only as test
fixtures.

## AUDF Markets

`contracts/script/DeployArcAudfMarkets.s.sol` is restored for the Arc AUDF
market operation. It is separate from the perp redeploy and should not be run as
part of the Fuji/Arc perp cutover unless the AUDF market operation is explicitly
approved.

## Verification

Run:

```bash
forge test --root contracts --no-match-contract MainnetForkTest
bun run sdk:test
bun run contracts:size:guard
```

Expected perps coverage:

- unit and role tests for margin, clearinghouse, funding, liquidation, and
  EIP-712 order settlement;
- 256-run fuzz for required-margin math;
- 256-run invariants for cash backing and open-interest caps.
