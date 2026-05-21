# @bu/fx-engine

TypeScript SDK for the fx-Telaraña Hub-and-Spoke protocol.

## What it gives you

- **Typed ABIs** for every contract (`FxOracleAbi`, `FxMarketRegistryAbi`, `FxSpokeAbi`, `FxReceiptAbi`, `FxLiquidatorAbi`, `FxHubMessageReceiverAbi`, `MorphoOracleAdapterAbi`, plus the `IFx*` interfaces). Auto-synced from `contracts/out/` — re-run `bun run abis:sync` after contract changes.
- **Addresses per chain** — Base Sepolia, Arc testnet, Ethereum mainnet, Sepolia. fx-Telaraña contract slots are populated after deploy; external deps (Morpho Blue, Pyth, USDC, EURC, CCTP V2) are hard-coded.
- **`EligibilityReason` enum** — the machine-readable contract between pasillo `/fx/eligibility` and the frontend.
- **`plan*` calldata builders** — `planSupply`, `planBorrow`, `planRepay`, `planEnterHub`, …
- **`getMid` / `getMidVerified`** — typed reads against `FxOracle`. `getMidVerified` runs the RedStone deviation gate (caller must wrap the tx with the RedStone SDK so the signed payload is in msg.data tail).
- **Phase B-E perps runtime gate** — `@bu/fx-engine/perps-runtime` loads `deployments/perps-config-5042002.json`, checks optional `CONTRACT_ADDRESSES_JSON` parity, and verifies live Arc roles, links, markets, funding, liquidation, and liquidity before keeper loops start.
- **Phase B-E keeper operations** — `@bu/fx-engine/perps-keeper` runs manifest-gated matcher, funding poke, liquidation scanner, and canary loops with JSON structured logs.

## Install

```bash
bun add @bu/fx-engine viem
```

## Quick start

```ts
import {
  ChainId,
  getAddresses,
  planSupply,
  planEnterHub,
  getMid,
} from "@bu/fx-engine";
import { createPublicClient, http } from "viem";
import { baseSepolia } from "viem/chains";

const arc = getAddresses(ChainId.ArcTestnet);
const baseSep = getAddresses(ChainId.BaseSepolia);

// Read the EURC/USDC mid from the Hub oracle (Pyth-only)
const client = createPublicClient({ chain: baseSepolia, transport: http() });
const quote = await getMid(client, baseSep.fxOracle!, baseSep.eurc!, baseSep.usdc!);
console.log("EURC/USDC mid (1e18):", quote.midE18);

// Build a cross-chain supply call: from a spoke chain, send USDC into Arc Hub.
const hubCalldata = planSupply({
  loanToken: arc.usdc!,
  collateralToken: arc.eurc!,
  assets: 1_000_000n,                     // 1 USDC at 6 decimals
  onBehalf: "0xYourSCA",
});

const spokeCalldata = planEnterHub({
  token: baseSep.usdc!,
  amount: 1_000_000n,
  beneficiary: "0xYourSCA",               // Hub-side recipient — never msg.sender
  hubCalldata,
});

// Send `spokeCalldata` to `FxSpoke` on Base Sepolia.
```

## Layout

```
src/
├── abis/                 # auto-generated typed ABIs (sync via scripts/sync-abis.mjs)
├── addresses/            # per-chain registry of fx + external deps + Pyth feed ids
├── helpers/
│   ├── plan.ts           # calldata builders (planSupply, planBorrow, planEnterHub, …)
│   └── quote.ts          # typed reads (getMid, getMidVerified)
├── eligibility.ts        # EligibilityReason enum
└── index.ts              # re-exports
```

## Re-sync ABIs

After any `contracts/` change:

```bash
forge build --root ../../contracts
bun run abis:sync
```

## Test

```bash
bun test
```

## Arc Perps Readiness

Run this before starting matcher, funding, liquidation, or canary workers:

```bash
ARC_RPC_URL=https://rpc.testnet.arc.network bun run perps:arc:readiness
```

The gate loads `ARC_PERP_CONFIG_PATH` or defaults to the repo's
`deployments/perps-config-5042002.json`. If `CONTRACT_ADDRESSES_JSON` is also
present, it must match the manifest exactly.

## Arc Perps Keeper Loops

Every loop runs the live readiness gate before polling. Use `PERP_DRY_RUN=1`
to validate config and candidate discovery without sending transactions.

```bash
# Read-only canary: readiness, EURC quote, funding/OI/liquidity checks.
ARC_RPC_URL=https://rpc.testnet.arc.network PERP_KEEPER_ONCE=1 bun run perps:arc:canary

# Funding scheduler: skips markets until PERP_FUNDING_MIN_INTERVAL_SECONDS has elapsed.
PERP_KEEPER_PRIVATE_KEY=0x... ARC_RPC_URL=https://rpc.testnet.arc.network bun run perps:arc:funding

# Matcher: reads signed maker/taker fills from PERP_MATCHES_JSON or PERP_MATCHES_FILE.
PERP_KEEPER_PRIVATE_KEY=0x... PERP_MATCHES_FILE=./orders.ndjson bun run perps:arc:matcher

# Liquidation scanner: combines event-discovered traders with optional candidates.
PERP_KEEPER_PRIVATE_KEY=0x... PERP_LIQUIDATION_CANDIDATES='{"EURC_USDC":["0x..."]}' bun run perps:arc:liquidations

# Sequential all-in-one keeper tick: matcher, funding, liquidation, canary.
PERP_KEEPER_PRIVATE_KEY=0x... bun run perps:arc:keeper
```

Useful env:

- `PERP_KEEPER_STATE_PATH` defaults to `.keeper/perps-5042002-state.json`.
- `PERP_KEEPER_INTERVAL_MS` controls polling cadence.
- `PERP_KEEPER_ONCE=1` runs one tick and exits.
- `PERP_KEEPER_COMPONENTS=matcher,funding,liquidation,canary` selects the all-in-one loop components.
- `PERP_MATCHES_JSON` accepts a JSON array of signed match intents; `PERP_MATCHES_FILE` accepts the same array or NDJSON.
- `PERP_LIQUIDATION_SCAN_FROM_BLOCK` and `PERP_LIQUIDATION_SCAN_BLOCK_RANGE` tune event candidate discovery.
- `PERP_CANARY_MARKETS` defaults to `EURC_USDC`; use `all` only once every market has a live quote path.
- `PERP_CANARY_REFRESH_PYTH=1` refreshes Pyth before quote checks and requires a keeper key.
- `PERP_CANARY_REQUIRE_QUOTE=1` makes quote failures exit non-zero; otherwise they are structured warnings.

## License

The published `@bu/fx-engine` SDK source, ABI modules, addresses, and helpers
are Apache-2.0. Operational scripts under `packages/sdk/scripts/` are
AGPL-3.0-only workflow/service code. See the repository [LICENSE](../../LICENSE)
policy for the full matrix.
