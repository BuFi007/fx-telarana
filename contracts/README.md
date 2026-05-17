# fx-Telaraña — Contracts

Solidity contracts for the fx-Telaraña dual-hub protocol. Fuji runs the canonical
USDC/EURC money market; Arc testnet now runs the basket money-market proof of
concept plus low-latency execution plumbing.
Spec: `../docs/SPEC.md` (v0.3).

## Layout

```
contracts/
├── foundry.toml
├── remappings.txt
├── .env.example                       # Arc testnet addresses + Pyth feed ids pre-filled
├── src/
│   ├── interfaces/
│   │   ├── IFxOracle.sol
│   │   ├── IFxMarketRegistry.sol
│   │   ├── IFxSpoke.sol
│   │   ├── IFxHubMessageReceiver.sol
│   │   └── ICctp.sol                  # local 0.8.26 redeclaration of Circle V2 surfaces
│   ├── libraries/
│   │   └── CctpMessageLib.sol         # CCTP V2 outer + burn body byte decoder
│   ├── hub/
│   │   ├── FxOracle.sol               # Pyth primary + RedStone secondary; 24/7
│   │   ├── MorphoOracleAdapter.sol    # IFxOracle → Morpho Blue IOracle(price())
│   │   ├── FxMarketRegistry.sol       # Single surface over Morpho Blue isolated markets
│   │   ├── FxReceipt.sol              # ERC-4626 wrapping a Morpho supply position
│   │   ├── FxLiquidator.sol           # Permissionless keeper wrapper around Morpho.liquidate
│   │   └── FxHubMessageReceiver.sol   # CCTP V2 inbound + executor + stranded-deposit sweep
│   └── spoke/
│       └── FxSpoke.sol                # CCTP V2 depositForBurnWithHook on each spoke chain
├── script/
│   ├── DeployArcBasketHub.s.sol       # full Arc basket hub stack + mock basket markets
│   ├── DeployFxHub.s.sol              # legacy Arc-side stack
│   └── DeployFxSpoke.s.sol            # per-spoke deploy (Ethereum, Base)
└── test/
    ├── FxOracle.t.sol                 # oracle unit tests (mock Pyth)
    ├── FxHubMessageReceiver.t.sol     # CCTP receiver tests
    ├── FxSpoke.t.sol                  # CCTP spoke tests
    ├── MainnetFork.t.sol              # 4 fork tests against Morpho Blue on Ethereum mainnet
    └── mocks/  utils/
```

## Build + test

```bash
forge build

# Unit tests only (fast)
forge test --no-match-contract MainnetForkTest

# Full suite incl. mainnet fork tests against real Morpho Blue
ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test
```

Current root-suite status: **273 tests passing, 1 skipped Tenderly manifest gate**.

## Phase 0 decisions (spec v0.2)

| ID | Decision | Where in code |
|---|---|---|
| D1 | Morpho Blue substrate, two isolated markets | `FxMarketRegistry.sol`, `MorphoOracleAdapter.sol` |
| D2 | Bufi Wallet KYC/KYB pass gates Ghost Mode | Off-chain + pass verifier (Phase 1) |
| D3 | Pyth primary + RedStone secondary, both permissionless | `FxOracle.sol` (RedStone consumer extraction = Phase 0.5) |
| D4 | Ghost Mode uses privacy hooks/routers; Phase 0 = public-only first | `FxHubMessageReceiver.sol` accepts explicit `beneficiary` |

## Implementation guardrails enforced

- `IFxOracle` is the only price-read surface. Pool, hook, liquidator, frontend never call Pyth/RedStone SDK directly.
- `IFxSpoke.enterHub(token, amount, beneficiary, hubCalldata)` takes explicit `beneficiary` (NEVER `msg.sender`-derived) — Ghost Mode flows pass the route-selected Bufi Ghost action account, public mode passes the EOA/SCA.
- `FxHubMessageReceiver.sweepStrandedDeposit(messageNonce)` recovers funds after a 24h grace window when the hub-call reverted on a CCTP-mint hook.
- All Solidity 0.8.26, optimizer 1M runs, `via_ir`, `cancun` EVM.

## Verified Arc testnet addresses

External dependencies:

| Contract | Address |
|---|---|
| USDC (native gas) | `0x3600000000000000000000000000000000000000` |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |
| Pyth | `0x2880aB155794e7179c9eE2e38200202908C17B43` |
| CCTP V2 TokenMessenger | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` |
| CCTP V2 MessageTransmitter | `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` |
| CCTP domain | `26` |

Live Arc basket hub, deployed 2026-05-17:

| Contract | Address |
|---|---|
| FxOracle | `0x625e2870a94F67F575Ed82678C2c619994721D29` |
| FxMarketRegistry | `0xdB59d712a3cD19DccD98F5a245302a94d43f9A8c` |
| FxLiquidator | `0x3DD99ace9ab896C613b47749e6Daae84ceF0433B` |
| FxHubMessageReceiver | `0x4FBe4cc4ab09648d65195f5B9490D20D12D49a2c` |
| FxGatewayHook | `0x412f0CE9cb7697458dF3804d56de259c3e38371B` |
| FxTimelock / receiver owner | `0x6b44F29DFf260D4426116c313a83e10f741A5a7a` |
| MorphoBlue | `0x3c9b95C6E7B23f094f066733E7797C8680760830` |
| AdaptiveCurveIrm | `0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1` |

Mock basket tokens on Arc:

| Token | Address | Decimals |
|---|---|---:|
| mAUDF | `0x4DeB6B4C83588c987C952858225A4725F6e1B1f2` | 6 |
| mJPYC | `0xD9eCFc78BDFbD121E8b07Bf96D6E27a1C11C6331` | 18 |
| mMXNB | `0xdb6EC7E8ad32D2c6fe05c0862d626A84049c24c5` | 6 |
| mKRW1 | `0x204E306FBc71D876E4F105111bBBB1E8113886C3` | 0 |
| mZCHF | `0xF50D7B5B6699f2D1FB7BCFC80261Ae0fca48396C` | 18 |

The Arc basket registry exposes 12 live markets: EURC plus mAUDF/mJPYC/mMXNB/mKRW1/mZCHF against USDC, both directions. Mock asset-loan markets are seeded with 10,000 units, USDC-loan markets are seeded with 1 USDC, and mock faucets are open for UI/API testing. Real issuer testnet token arrivals require new Morpho markets because market IDs depend on token addresses.

Pyth feed ids (verified via Hermes):
- USDC/USD: `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a`
- EURC/USD: `0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c`
- EUR/USD: `0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b`

## Deferred to later phases

- **Phase 0.5** — DONE. RedStone wired via `PrimaryProdDataServiceConsumerBase`; `getMidVerified()` reads signed payload from msg.data tail and runs the deviation gate.
- **Phase 1** — Bufi Wallet KYC/KYB pass verifier + Ghost Mode privacy hooks/routers with commitment/nullifier withdrawal routing.
- **Phase 2** — `FxSwapHook.sol` (Uniswap v4 hook with oracle-anchored PMM + JIT-borrow from Morpho).

## Deploy

### Base Sepolia (recommended for early validation — Morpho Blue is already live there)

```bash
# Simulate (no broadcast)
DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/DeployBaseSepolia.s.sol \
    --fork-url https://base-sepolia-rpc.publicnode.com

# Live deploy (~0.00016 ETH gas)
DEPLOYER_PRIVATE_KEY=<your-funded-key> \
  forge script script/DeployBaseSepolia.s.sol \
    --rpc-url https://base-sepolia-rpc.publicnode.com \
    --broadcast --verify
```

Base Sepolia, Avalanche Fuji, and Arc Testnet use Circle-published testnet EURC
addresses. Do not deploy `MockEURC` on those chains; use `MockStablecoin` only
for the non-Circle basket assets that do not have issuer testnet deployments.

### Arc basket hub

```bash
# Simulate only.
ARC_MORPHO_BLUE=0x3c9b95C6E7B23f094f066733E7797C8680760830 \
ARC_MORPHO_ADAPTIVE_IRM=0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1 \
DEPLOYER_PRIVATE_KEY=<key> \
forge script script/DeployArcBasketHub.s.sol --rpc-url https://rpc.testnet.arc.network

# Live deploy.
ARC_MORPHO_BLUE=0x3c9b95C6E7B23f094f066733E7797C8680760830 \
ARC_MORPHO_ADAPTIVE_IRM=0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1 \
ARC_BASKET_MANIFEST=../deployments/arc-testnet-basket.json \
DEPLOYER_PRIVATE_KEY=<funded-key> \
forge script script/DeployArcBasketHub.s.sol \
  --rpc-url https://rpc.testnet.arc.network \
  --broadcast --slow --legacy
```

### Per-spoke (Ethereum / Base / etc.)

```bash
SPOKE_USDC=... SPOKE_CCTP_TOKEN_MESSENGER=... ARC_HUB_RECEIVER=... ARC_DOMAIN=26 \
  forge script script/DeployFxSpoke.s.sol --rpc-url ethereum --broadcast --verify
```

## License

First-party smart contracts, deployment scripts, hooks, Solidity interfaces, and
protocol libraries in this package are Apache-2.0 unless a file-level SPDX
header says otherwise. Vendored dependencies under `contracts/lib/` keep their
upstream licenses.
