# @bu/fx-engine

TypeScript SDK for the fx-Telaraña Hub-and-Spoke protocol.

## What it gives you

- **Typed ABIs** for every contract (`FxOracleAbi`, `FxMarketRegistryAbi`, `FxSpokeAbi`, `FxReceiptAbi`, `FxLiquidatorAbi`, `FxHubMessageReceiverAbi`, `MorphoOracleAdapterAbi`, plus the `IFx*` interfaces). Auto-synced from `contracts/out/` — re-run `bun run abis:sync` after contract changes.
- **Addresses per chain** — Fuji, Arc, the active CCTP V2 testnet spokes, Avalanche mainnet prep, and external deps (Morpho Blue, Pyth, USDC, EURC, CCTP V2).
- **Live Arc basket metadata** — mock AUDF/JPYC/MXNB/KRW1/ZCHF token addresses, decimals, oracle feed metadata, and the Arc basket hub contracts.
- **`Telarana` route client** — one entry point for Fuji-vs-Arc hub selection, route resolution, Gateway metadata, and live market IDs.
- **`EligibilityReason` enum** — the machine-readable contract between pasillo `/fx/eligibility` and the frontend.
- **`plan*` calldata builders** — `planSupply`, `planBorrow`, `planRepay`, `planEnterHub`, …
- **`getMid` / `getMidVerified`** — typed reads against `FxOracle`. `getMidVerified` runs the RedStone deviation gate (caller must wrap the tx with the RedStone SDK so the signed payload is in msg.data tail).

## Install

```bash
bun add @bu/fx-engine viem
```

## Quick start

```ts
import {
  ChainId,
  Telarana,
  getAddresses,
  planSupply,
  planEnterHub,
  getMid,
} from "@bu/fx-engine";
import { createPublicClient, http } from "viem";
import { baseSepolia } from "viem/chains";

const arc = getAddresses(ChainId.ArcTestnet);
const baseSep = getAddresses(ChainId.BaseSepolia);
const telarana = new Telarana();
const arcHub = telarana.hub("arc");

console.log("Arc registry:", arcHub.marketRegistry);
console.log("Arc markets:", arcHub.marketIds);
console.log("mJPYC:", arc.stablecoinBasket?.jpyc.address);

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

## Live Arc basket surface

Arc testnet (`5042002`) is the current UI/API proof-of-concept hub for the FX basket. The SDK exposes this through `getAddresses(ChainId.ArcTestnet)`, `new Telarana().hub("arc")`, and `telarana.route(...)`.

| Surface | Address |
|---|---|
| FxMarketRegistry | `0xdB59d712a3cD19DccD98F5a245302a94d43f9A8c` |
| FxHubMessageReceiver | `0x4FBe4cc4ab09648d65195f5B9490D20D12D49a2c` |
| FxGatewayHook | `0x412f0CE9cb7697458dF3804d56de259c3e38371B` |
| FxOracle | `0x625e2870a94F67F575Ed82678C2c619994721D29` |
| FxLiquidator | `0x3DD99ace9ab896C613b47749e6Daae84ceF0433B` |
| FxTimelock / receiver owner | `0x6b44F29DFf260D4426116c313a83e10f741A5a7a` |

Mock basket assets:

| Asset | Address | Decimals | SDK path |
|---|---|---:|---|
| mAUDF | `0x4DeB6B4C83588c987C952858225A4725F6e1B1f2` | 6 | `stablecoinBasket.audf.address` |
| mJPYC | `0xD9eCFc78BDFbD121E8b07Bf96D6E27a1C11C6331` | 18 | `stablecoinBasket.jpyc.address` |
| mMXNB | `0xdb6EC7E8ad32D2c6fe05c0862d626A84049c24c5` | 6 | `stablecoinBasket.mxnb.address` |
| mKRW1 | `0x204E306FBc71D876E4F105111bBBB1E8113886C3` | 0 | `stablecoinBasket.krw1.address` |
| mZCHF | `0xF50D7B5B6699f2D1FB7BCFC80261Ae0fca48396C` | 18 | `stablecoinBasket.zchf.address` |

These are testnet mocks. When issuer testnet contracts arrive, deploy new markets instead of swapping these addresses in place; Morpho market IDs depend on token addresses.

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

## License

The published `@bu/fx-engine` SDK source, ABI modules, addresses, and helpers
are Apache-2.0. Operational scripts under `packages/sdk/scripts/` are
AGPL-3.0-only workflow/service code. See the repository [LICENSE](../../LICENSE)
policy for the full matrix.
