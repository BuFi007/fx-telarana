<p align="center">
  <img src="docs/assets/banner.jpg" alt="BU.FI — FX Telaraña Protocol" />
</p>

# FX Telaraña Protocol

> *Telaraña — "spider's web" — for the hub-and-spoke topology that pulls stablecoin FX liquidity from every USDC chain into canonical hub markets, then weaves the hubs together with Circle Gateway.*

Cross-chain onchain forex credit, settlement, and execution. **Two live hubs, 16 spokes across 8 chains**, Circle Gateway bridging hub-to-hub liquidity at sub-second attestor latency. Morpho Blue substrate. Pyth + RedStone oracles. Uniswap V4 hooks. Native USDC, never wrapped.

---

## TL;DR

**Real spider-web — every chain has two spokes, each landing on a different hub depending on intent.**

- **Avalanche Fuji — canonical EURC money-market hub.** Lend, borrow, supply liquidity over Morpho Blue for USDC/EURC.
- **Arc Testnet — basket money-market + trading-execution hub.** Sub-second finality, native-USDC gas, and 12 live Morpho markets: EURC plus mock AUDF/JPYC/MXNB/KRW1/ZCHF against USDC, both directions.
- **8 chains × 2 spokes = 16 spokes total.** Each chain has one `FxSpoke` routing to Fuji (`contracts.FxSpoke`) and one routing to Arc (`contracts.FxSpokeToArc`). User picks the destination per intent.
- **Circle Gateway bridges the two hubs at the protocol level** — never user-initiated. **Verified end-to-end live**, both bypass and hook-routed flows. Real attestation, real cross-chain mint, **349ms** Circle attestor latency. See [`docs/GATEWAY_E2E.md`](docs/GATEWAY_E2E.md) + [`reports/gateway-fuji-to-arc-bypass.md`](reports/gateway-fuji-to-arc-bypass.md).
- **Stage 6 plumbing (`hub.relayToRemoteHub` / `relayMintFromRemote`) LIVE** on both hubs — BUFX (spot+perps execution layer, separate repo) can now trigger cross-hub liquidity moves through the hubs once whitelisted via `hub.setRelayCaller(bufxAddress, true)`. See [`docs/BUFX_INTEGRATION.md`](docs/BUFX_INTEGRATION.md).

---

## Topology

```
                            ┌──────────────────────────────┐
                            │   Circle Gateway (USDC)      │
                            │   349ms attestor latency     │
                            │                              │
                            ▼                              │
┌─────────────────────────────────┐       ┌───────────────┴────────────────┐
│         FUJI HUB (chain 43113)  │       │      ARC HUB (chain 5042002)   │
│         EURC money market       │◀─────▶│      Basket money markets      │
│                                 │ Stage │      + low-latency execution   │
│  FxHubMessageReceiver           │   6   │  FxHubMessageReceiver          │
│   ├─ relayToRemoteHub           │ relay │   ├─ relayToRemoteHub          │
│   └─ relayMintFromRemote        │       │   └─ relayMintFromRemote       │
│  FxGatewayHook                  │       │  FxGatewayHook                 │
│  FxMarketRegistry (Morpho Blue) │       │  FxMarketRegistry (Morpho Blue)│
│  FxOracle (Pyth+RedStone)       │       │  FxOracle (Pyth+RedStone)      │
│  FxReceipt{USDC, EURC} (4626)   │       │  FxReceipt per basket market   │
│  FxLiquidator                   │       │  FxLiquidator                  │
└──────▲──────────────────▲───────┘       └──────▲──────────────────▲──────┘
       │                  │                       │                  │
       │ Fuji-routed       │                      │ Arc-routed        │
       │ FxSpoke           │                      │ FxSpoke           │
       │ (lend / borrow)    │                      │ (HFT trade)       │
       │                  │                       │                  │
       └─ 8 chains ────────┴─────  same 8 chains ─┴──────────────────┘
       (eth / op / arb / poly / uni / world / fuji-local / arc-local)
```

User flow — pick your destination:

| Intent | Use this spoke | Result |
|---|---|---|
| Lend or borrow USDC↔EURC at the lowest rate | Whichever route has better rates that day (read both `FxOracle`s) | Land on that hub's Morpho market |
| Basket-market testing, HFT FX trade, or perp | Arc-routed spoke | Land on Arc hub; use the Arc basket markets and low-latency execution |
| Bridge funds between hubs (no user action needed) | Protocol does this automatically via Stage 6 + Circle Gateway | Liquidity stays unified |

---

## Live deployments

### Fuji — money-market hub (chain `43113`, CCTP V2 domain 1, Gateway domain 1)

| Contract | Address |
|---|---|
| FxSpoke (Fuji-local) | `0x6EC2197aC1c35Fbe64533101a3DFf081BD45Ed99` |
| FxSpoke (Fuji → Arc) | `0x225cca22879593b41c7dcceb9e961b7881061368` |
| **FxHubMessageReceiver** (Stage 6) | `0xbBc9AE9dbd3F6D3dB672F0CA2419d0f4C8513062` |
| **FxGatewayHook** (Stage 6) | `0x1527f0230e07B202812A0F0E437995323A1a98cB` |
| FxMarketRegistry | `0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9` |
| FxOracle | `0x4178F9D64F64eD05C25B0D6284f64522436A2a1F` |
| FxLiquidator | `0x113A539625D208b5EcC59f300Be14b9b3508E559` |
| FxReceiptEURC | `0x971b6ED14521f354eD13d64506Bf47D84E70F4fc` |
| FxReceiptUSDC | `0x629144FDC1d0A6f9F2B12d9747557Cc508728739` |
| MorphoBlue (self-deployed) | `0xeF64621D41093144D9ED8aB8327eE381ECdB79E6` |

Full manifest: [`deployments/avalanche-fuji.json`](deployments/avalanche-fuji.json) + [`deployments/hub-config-fuji.json`](deployments/hub-config-fuji.json).

### Arc Testnet — basket money-market + trading-execution hub (chain `5042002`, CCTP V2 domain 26, Gateway domain 26)

| Contract | Address |
|---|---|
| FxSpoke (Arc → Fuji) | `0xf93834070e4e4e7ff0e161feca2aeba65c2c6a38` |
| FxSpoke (Arc-local) | `0x10b1ddc4a061991d44643893a24b754b8fc0dc98` |
| **FxHubMessageReceiver** (Stage 6) | `0x4FBe4cc4ab09648d65195f5B9490D20D12D49a2c` |
| **FxGatewayHook** (Stage 6) | `0x412f0CE9cb7697458dF3804d56de259c3e38371B` |
| FxMarketRegistry | `0xdB59d712a3cD19DccD98F5a245302a94d43f9A8c` |
| FxOracle | `0x625e2870a94F67F575Ed82678C2c619994721D29` |
| FxLiquidator | `0x3DD99ace9ab896C613b47749e6Daae84ceF0433B` |
| FxReceiptEURC | `0x8A88024AE640B26b082E5D01BF0BDea9e0F89f3d` |
| FxReceiptUSDC | `0x3b94E6A9Dc100CC390B56D1f0BB6a0B706ad3aAA` |
| MorphoBlue (self-deployed) | `0x3c9b95C6E7B23f094f066733E7797C8680760830` |
| AdaptiveCurveIrm | `0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1` |
| FxTimelock / receiver owner | `0x6b44F29DFf260D4426116c313a83e10f741A5a7a` |

Full manifest: [`deployments/arc-testnet.json`](deployments/arc-testnet.json), basket manifest: [`deployments/arc-testnet-basket.json`](deployments/arc-testnet-basket.json), hub config: [`deployments/hub-config-arc.json`](deployments/hub-config-arc.json).

#### Arc basket markets

Arc testnet is the UI/API proof-of-concept hub for the wider FX basket. EURC is the Circle testnet token. AUDF, JPYC, MXNB, KRW1, and ZCHF are **testnet mocks** until issuer testnet contracts exist. When real issuer tokens arrive, new Morpho markets must be deployed because market IDs commit to token addresses.

| Asset | Token address | Decimals | Asset-loan market | USDC-loan market |
|---|---|---:|---|---|
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | 6 | `0xfd39280abf7d487fdacb075964282ef40cfbc05d29f3dd0de33fd106f999e321` | `0xcd92ddbcde6eac8b696f8f55cff1e0a397c43a10b9c5ea62d3a134333961853b` |
| mAUDF | `0x4DeB6B4C83588c987C952858225A4725F6e1B1f2` | 6 | `0xdecc6eac359fccc90312bcc10d4e3f041b24499e6f5fc6c9b979c63ed3324827` | `0x30b2b4f9a060a4106af7d648ee2997af663dba4a13a80bdaa3b7dcdd86ad024e` |
| mJPYC | `0xD9eCFc78BDFbD121E8b07Bf96D6E27a1C11C6331` | 18 | `0x45af7bde15cc90c3d746c5c33ffe8f841d9a13691d4b61b37488f0728c6d3c4b` | `0x85bd7c3e24560aa9e9e92b38b343f30e7699bd40b5c8623a9da6dddb3fa37c61` |
| mMXNB | `0xdb6EC7E8ad32D2c6fe05c0862d626A84049c24c5` | 6 | `0x2a9537d6924829e4885754f4d5bc162540c85215edcd2a617e4b44237ceb5b03` | `0x44cd73ea5727fab16c3f4eeb4e33d61e3679709ec026423a7cedd135b0fd2a9c` |
| mKRW1 | `0x204E306FBc71D876E4F105111bBBB1E8113886C3` | 0 | `0x9128daa773043c0356fd98ff060eef6cc149eca6efb55b147c600d62d170d379` | `0x19a08dbc14b7db6dbe151ac2bdc5fb7490acc8e2f95ccb8eea768486c93b0b89` |
| mZCHF | `0xF50D7B5B6699f2D1FB7BCFC80261Ae0fca48396C` | 18 | `0x175e4e8d24841d73e51f118e6318e429ff9c772df512de1168a3b8f666647ae3` | `0xa900dd90f3d9e8de4546a2be44c54ff6d0ece155766cd4480e5ec9b20c2e98bb` |

Seed state for UI/API testing: each mock asset-loan market has 10,000 units supplied, each USDC-loan market has 1 USDC supplied, EURC asset-loan has 1 EURC supplied, mock faucets are open, and the deployer retains 1,000 units of each mock.

Per-market `FxReceipt` addresses are recorded in [`deployments/arc-testnet-basket.json`](deployments/arc-testnet-basket.json) under `receipt_*`. UI/API position views should still treat Morpho `position(marketId, account)` as the primary source of truth.

#### Arc Phase B-E perps stack

Trading is Arc-only for this stack. These contracts were deployed on Arc Testnet and smoke-tested through market config, funding config, liquidation config, protocol liquidity seed, quote, EIP-712 signed order settlement, funding poke, liquidation scan, flag, and liquidation.

| Contract | Address |
|---|---|
| FxPerpClearinghouse | `0x6A265045D9A3291D2881d77DDC62e2781A2418c5` |
| FxMarginAccount | `0x35c7cD02cFa0c2889547482B71c1a5114d8439C6` |
| FxFundingEngine | `0x88B70872759E1aA24858746779Cb15ca9F2cdcf3` |
| FxHealthChecker | `0x272305e821D810eC5741761F98DbDC273efD47E6` |
| FxLiquidationEngine | `0xD384560E5f8CE969BF4C1BDfAFACc5304AFbe8f2` |
| FxOrderSettlement | `0x0F62FCdA2de63d905Cb167301C00251A9bB6dAa1` |

Supporting Arc addresses:

| Contract | Address |
|---|---|
| USDC | `0x3600000000000000000000000000000000000000` |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |
| FxOracle | `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865` |
| Keeper / admin | `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` |

Perps manifest: [`deployments/perps-5042002.json`](deployments/perps-5042002.json). Config manifest: [`deployments/perps-config-5042002.json`](deployments/perps-config-5042002.json). Trading smoke report: [`reports/SMOKE_ARC_PHASE_B_E_TRADING.md`](reports/SMOKE_ARC_PHASE_B_E_TRADING.md).

### Spokes — 16 total, dual-routed per chain

Every chain hosts both a Fuji-routed spoke and an Arc-routed spoke. Users pick by intent.

| Chain | chainId | CCTP V2 | FxSpoke → Fuji | FxSpoke → Arc |
|---|---|---|---|---|
| Ethereum Sepolia | 11155111 | 0 | `0xf4556f31cace9a80aa584059c81638a5cd344dde` | `0xb912a78e5dbb0848501e1d643bda2193ec64aebc` |
| OP Sepolia | 11155420 | 2 | `0x2552e1027ff27a285635a9593825e3da8f25808b` | `0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b` |
| Arbitrum Sepolia | 421614 | 3 | `0xaa875a68b0155da4bd6a528ee9e1137017d18b41` | `0xfa999ca0392523a915e6bbc0026825090ed1a207` |
| Polygon Amoy | 80002 | 7 | `0x58c1a04bc4e25db2f8474c9df41907cffc894a4b` | `0x71e85194f57338d854eabd158f0cd2c376b9f966` |
| Unichain Sepolia | 1301 | 10 | `0x58c1a04bc4e25db2f8474c9df41907cffc894a4b` | `0x71e85194f57338d854eabd158f0cd2c376b9f966` |
| World Chain Sepolia | 4801 | 14 | `0x2552e1027ff27a285635a9593825e3da8f25808b` | `0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b` |
| Avalanche Fuji (local) | 43113 | 1 | `0x6EC2197aC1c35Fbe64533101a3DFf081BD45Ed99` | `0x225cca22879593b41c7dcceb9e961b7881061368` |
| Arc Testnet (local) | 5042002 | 26 | `0xf93834070e4e4e7ff0e161feca2aeba65c2c6a38` | `0x10b1ddc4a061991d44643893a24b754b8fc0dc98` |

Each chain manifest has a `routes:` block describing both. See e.g. [`deployments/ethereum-sepolia.json`](deployments/ethereum-sepolia.json).

### Circle Gateway (deterministic CREATE2, same on every testnet)

- `GatewayWallet`  `0x0077777d7EBA4688BDeF3E311b846F25870A19B9`
- `GatewayMinter`  `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B`

### Authority

Deployer EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` signs BurnIntents off-chain until Circle's EIP-1271 support lands. Arc receiver ownership is already on `FxTimelock`; Fuji still needs the planned multisig/timelock owner rotation before production. Gateway authority remains EOA on both hubs for the pre-1271 phase. At 1271 cutover, authority rotates to the local hub path via `setAuthority(...)` and signing becomes contract-bound. See [`CLAUDE.md`](CLAUDE.md) for the rotation plan.

---

## Proof of life — two end-to-end Gateway flows, both live

Real testnet, real Circle attestation, no mocks. Driven via [`packages/sdk/scripts/gateway-signer.ts`](packages/sdk/scripts/gateway-signer.ts).

### Flow 1: bypass (EOA → Gateway → EOA, no hooks involved)

Validates that our EIP-712 typed-data layout + signature recovery + wire format are Circle-compatible. Used as a sanity check before exercising the contracts.

| Step | Tx | Latency |
|---|---|---|
| `depositFor($2 → Gateway, depositor=EOA)` on Fuji | `0x84966b1e…5937` | — |
| Circle attestor (POST `/transfer`) | — | **397ms** |
| `gatewayMint($0.10)` on Arc | `0x60418160…ac1b` | — |

### Flow 2: full hook-routed (Stage 6, what BUFX will call)

Every USDC move goes through our contracts. Gateway is invisible to the caller.

| Step | Tx | Chain |
|---|---|---|
| Approve hub | `0x9e963708…5e63` | Fuji |
| `hub.relayToRemoteHub($0.10)` → pulls USDC, calls `hook.lockForRemote`, scrubs approvals | `0x35b646a2…e040` | Fuji |
| Circle attestor (POST `/transfer`) — **349ms** | — | — |
| `hub.relayMintFromRemote(attestation, sig)` → hook receives USDC + forwards to hub | `0xe430d026…9aaa` | Arc |
| Arc hub USDC balance after → `100000` ($0.10) ✓ | — | — |

Fee: $0.020005 per $0.10 transferred (~20bps Circle operator fee). Confirms Gateway as the sub-block HFT primitive the Circle architect described.

Full walkthrough + event chains: [`reports/gateway-fuji-to-arc-bypass.md`](reports/gateway-fuji-to-arc-bypass.md).

---

## What it is

- **FX money market over Morpho Blue** — isolated markets per direction. Fuji has USDC↔EURC. Arc has EURC plus mock AUDF / JPYC / MXNB / KRW1 / ZCHF against USDC for UI/API proof-of-concept testing. Real issuer token arrivals require new Morpho markets because market IDs depend on token addresses.
- **Cross-chain spokes via CCTP V2** — bring USDC and EURC (where Circle supports it) from any CCTP-supported chain. Opens a position on the destination hub atomically inside the hub-message receiver. Dual-routed: one spoke per chain per hub.
- **Cross-hub liquidity via Circle Gateway** — hub-only `FxGatewayHook` on each chain, signed by deployer EOA today, hub-contract-via-1271 from mid-July. Sub-second finality on Arc means cross-hub liquidity moves can happen inside a single FX-trade context.
- **Stage 6 hub-routed relay** — `relayToRemoteHub` + `relayMintFromRemote` on `FxHubMessageReceiver`, gated by `owner` + `relayCallers` whitelist. BUFX (separate repo) calls in here for cross-hub liquidity moves.
- **Decentralized oracle** — Pyth primary + RedStone secondary, the only price-read surface (`IFxOracle`). 24/7. No forex-hours circuit breakers.
- **Uniswap V4 hooks (in progress)** — oracle-anchored quote, dynamic fees, JIT-borrow on output shortfall, afterSwap fee rebalance into Morpho (Bunni pattern). `FxSwapHook.sol` ships as constant-spread MVP; cross-hub orchestration is BUFX's responsibility (its state machine sits on top of Stage 6 primitives — same-tx atomicity is impossible because Gateway is ~349ms async).
- **Ghost Mode (Phase 1)** — Bufi Wallet / RO-KYC pass-gated spoke entry, commitment/nullifier registry, minimal v4 KYC hook scaffolding.
- **BUFX layer** (separate repo) — spot + perps StableFx execution riding on this substrate. Whitelist via `hub.setRelayCaller(bufxAddress, true)` once their contracts deploy.

---

## Repo layout

```
contracts/                        Foundry — protocol contracts, tests, deploy scripts
  src/
    hub/                          FxHubMessageReceiver (Stage 6), FxMarketRegistry, FxOracle,
                                  FxLiquidator, FxReceipt, FxSwapHook, MorphoOracleAdapter,
                                  FxGatewayHook
    spoke/                        FxSpoke
    interfaces/                   IFxOracle, IFxMarketRegistry, IFxSpoke,
                                  IFxHubMessageReceiver, IFxGatewayHook, IGateway
    libraries/                    CctpMessageLib
  script/                         DeployArcBasketHub, DeployArcTestnet, DeployAvalancheFuji,
                                  DeployBaseSepolia, DeployFxSpoke, DeployFxGatewayHook, …
  test/                           Foundry tests (unit + mainnet fork) — 273 passing, 1 skipped
packages/sdk/                     @bu/fx-engine — TypeScript SDK
  src/
    gateway.ts                    Gateway types, ABIs, route configs, EIP-712 helpers
    addresses/                    Per-chain address book
    abis/                         Auto-synced contract ABIs
  scripts/
    gateway-signer.ts             Off-chain BurnIntent signer service (CLI + library)
    deploy-spokes-to-arc.sh       Reproducible Arc-routed spoke deploy across all chains
    migrate-hub.ts                Hub-migration orchestrator (preflight + state-file audit)
    simulator/                    Tenderly Simulator regression suite (128 sims)
    tenderly-*.sh                 Tenderly vnet management
deployments/                      Per-chain manifests (16 spokes + 2 hub-configs + arc/fuji root)
                                  Each chain manifest has a `routes:` block w/ both hubs
docs/
  SPEC.md                         Engineering spec
  BUFX_INTEGRATION.md             BUFX integration reference (addresses + interfaces)
  GATEWAY_E2E.md                  Gateway end-to-end procedure (bypass + hook-routed)
  whitepaper/                     LaTeX source
reports/
  gateway-fuji-to-arc-bypass.md   Proof-of-life — both flows with tx hashes + event chains
  sim-matrix-latest.md            128-sim regression matrix
```

---

## Quick start

```bash
# install
bun install
git submodule update --init --recursive

# tests — 273 forge tests passing, 1 skipped Tenderly manifest gate
bun run contracts:test
bun run sdk:test

# assert live hub registry surfaces
cd packages/sdk && bun run assert:lending-surface

# explore the live deployments
bun packages/sdk/scripts/gateway-signer.ts info        # Circle's supported chains
bun packages/sdk/scripts/gateway-signer.ts balances    # deployer's Gateway USDC across both routes
```

### Gateway end-to-end (live testnet, ~$0.10 USDC, ~30 seconds)

Requires deployer wallet funded with ≥2 USDC on Fuji via [faucet.circle.com](https://faucet.circle.com).

```bash
source .env.local

# Bypass mode (no hooks) — sanity check
bun packages/sdk/scripts/gateway-signer.ts deposit fuji 2000000
bun packages/sdk/scripts/gateway-signer.ts sign-and-attest gateway-fuji-to-arc-usdc 100000 --bypass
bun packages/sdk/scripts/gateway-signer.ts gateway-mint arc <attestation> <signature>

# Hook-routed (Stage 6) — what BUFX will call
cast send $FUJI_HUB 'relayToRemoteHub(uint256)' 100000 --rpc-url $FUJI_RPC --private-key $PK
bun packages/sdk/scripts/gateway-signer.ts sign-and-attest gateway-fuji-to-arc-usdc 100000
cast send $ARC_HUB 'relayMintFromRemote(bytes,bytes)' <attestation> <signature> --rpc-url $ARC_RPC --private-key $PK
```

Full walkthrough: [`docs/GATEWAY_E2E.md`](docs/GATEWAY_E2E.md).

---

## Testing summary

- **273 Foundry tests** passing, 1 Tenderly manifest gate skipped (hub + spoke + Gateway + basket smoke + swap hook invariants)
- **4/4 ETH mainnet fork tests** against the live Morpho Blue singleton at `0xBBBBBbbBBb…7EEFFCb`
- **128-sim Tenderly regression matrix** across deposit / borrow / withdraw / sweep / liquidate / swap / CCTP-reverse flows
- **2 rounds of Codex adversarial review**, all findings patched
- **End-to-end USDC→EURC swap** via Universal Router V4_SWAP on Base Sepolia (~405k gas)
- **End-to-end Gateway Fuji→Arc liquidity move** — both bypass + hook-routed flows verified live (~349ms attestor)
- **Arc basket live-read verification** — 12 registered live pools, registry unpaused, receiver owner = timelock, mock faucets open, all 12 Morpho markets seeded.

---

## Tenderly Virtual TestNet

Pro-tier vnets for parallel stress simulation. Avalanche Fuji vnet currently primed at block 55,355,022 with the full hub stack. Useful admin RPC extensions:

- `tenderly_setBalance(address, amountHex)` — fund any address with native gas
- `tenderly_setErc20Balance(token, holder, amountHex)` — fund any ERC-20
- `tenderly_setStorageAt(address, slot, value)` — mutate state directly
- `tenderly_simulateBundle(...)` — atomic multi-tx simulation
- `evm_increaseTime` / `evm_mine` — time travel for grace-period tests

Tenderly does **not** yet support Arc Testnet (chain 5042002) — on-chain verification only for Arc until they add it. We're pushing for that listing.

---

## What's left

### Locked in this session ✅
- Stage 6 plumbing (hub-routed Gateway via `relay*` shims) — both hubs, live
- Spider-web topology — 16 spokes across 8 chains, dual-routed per chain
- Gateway end-to-end proven both bypass + hook-routed on real testnets
- Arc basket money-market hub — EURC plus mAUDF/mJPYC/mMXNB/mKRW1/mZCHF against USDC, both directions, seeded for UI/API testing
- Full address book + integration reference for BUFX

### Next, in priority order

1. **UI/API integration against live surfaces.** The app should list only Fuji USDC/EURC and Arc EURC + mAUDF/mJPYC/mMXNB/mKRW1/mZCHF markets; no BRLA/PHPC and no fictional `x` tokens.
2. **Real basket testnet issuer contracts.** When AUDF/JPYC/MXNB/KRW1/ZCHF issuer testnet contracts arrive, deploy new Morpho markets because market IDs depend on token addresses. Do not replace token addresses in-place.
3. **BUFX lands.** Whitelist via `hub.setRelayCaller(bufxAddress, true)` on both hubs. Stage 6 surface is the integration point.
4. **Joint adversarial audit — Telaraña + BUFX working together.** Codex (and external reviewer) drives end-to-end flows: user enters Polygon spoke → routes to Fuji → opens position → BUFX takes Arc-side trade → Stage 6 moves USDC → close position → CCTP back to Polygon. Two rounds: round 1 lifecycle correctness, round 2 adversarial / MEV / front-run scenarios.
5. **EIP-1271 authority rotation** (mid-July 2026). Implement `isValidSignature` on `FxHubMessageReceiver` (gates which BurnIntents the protocol authorizes — domain pair, value cap, deadline). Call `hook.setAuthority(hub)` on both chains. Retire the off-chain EOA signer.
6. **Tenderly Avalanche stress run.** Same contracts on the primed Fuji vnet; Tenderly Pro snapshot branching for parallel scenario coverage; targets multi-million-USDC per intent (we've validated $0.10 live, architecture targets $10M+).
7. **Tenderly listing for Arc.** On the Tenderly team's side. Unlocks vnet stress testing on Arc itself; currently on-chain verification only there.

### Status of things mentioned earlier
- **Phase 2.5 swap hook** — DODO PMM curve math, LP rehypothecation, JIT-borrow. Constant-spread MVP shipped on Base Sepolia. Full curve math + cross-hub orchestration is BUFX's responsibility on top of Stage 6.
- **Ghost Mode (Phase 1)** — scaffold in place, Bufi Wallet integration pending.

---

## Attribution

The hook roadmap and the current truncated-observation / volatility-spread implementation are inspired by public Uniswap v4 hook examples — particularly the truncated oracle, volatility oracle, and TWAMM work by Austin Adams (`aadams`) and the Uniswap builders. Ghost Mode also learns from `blackbera/privacy-hook-univ4` and public KYC hook examples, while avoiding unsafe patterns like `tx.origin` authorization.

The dual-hub Gateway architecture is informed by direct conversations with the Circle Gateway team — particularly the framing of Gateway as a sub-block HFT primitive — and built on top of the open-source contracts at [`circlefin/evm-gateway-contracts`](https://github.com/circlefin/evm-gateway-contracts).

Thank you to those builders for publishing useful reference work. Where we vendor or derive from third-party sources, we keep their SPDX headers, copyright notices, and NOTICE requirements with the imported files.

---

## License

Mixed-license by path and artifact type:

- **Apache-2.0** — smart contracts, Uniswap v4 hooks, public Solidity protocol libraries, and the public `@bu/fx-engine` SDK.
- **AGPL-3.0-only** — backend services, Hono APIs, indexers, monitors, simulators, deployment/registration workflows, and agent/workflow services.
- **MIT** — examples, templates, frontend demo components, and throwaway integration samples.

See [`LICENSE`](LICENSE) for the repo policy and `LICENSES/` for full license texts. Per-file SPDX headers are authoritative where present.
