<p align="center">
  <img src="docs/assets/banner.jpg" alt="BU.FI — FX Telaraña Protocol" />
</p>

# FX Telaraña Protocol

> *Telaraña — "spider's web" — for the hub-and-spoke topology that pulls stablecoin FX liquidity from every USDC chain into canonical hub markets, then weaves the hubs together with Circle Gateway.*

Cross-chain onchain forex credit, settlement, and execution. **Two live hubs, 16 spokes across 8 chains**, Circle Gateway bridging hub-to-hub liquidity at sub-second attestor latency. Morpho Blue substrate. Pyth + RedStone oracles. Uniswap V4 hooks. Native USDC, never wrapped.

---

## TL;DR

**Real spider-web — every chain has two spokes, each landing on a different hub depending on intent.**

- **Avalanche Fuji — money-market hub.** Lend, borrow, supply liquidity over Morpho Blue.
- **Arc Testnet — trading-execution hub.** HFT FX + perps. Sub-second finality, native-USDC gas. Also runs the same Morpho stack (lend/borrow works here too).
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
│         money-market substrate  │◀─────▶│      HFT + perp execution      │
│                                 │ Stage │      + same Morpho stack       │
│  FxHubMessageReceiver           │   6   │  FxHubMessageReceiver          │
│   ├─ relayToRemoteHub           │ relay │   ├─ relayToRemoteHub          │
│   └─ relayMintFromRemote        │       │   └─ relayMintFromRemote       │
│  FxGatewayHook                  │       │  FxGatewayHook                 │
│  FxMarketRegistry (Morpho Blue) │       │  FxMarketRegistry (Morpho Blue)│
│  FxOracle (Pyth+RedStone)       │       │  FxOracle (Pyth+RedStone)      │
│  FxReceipt{USDC, EURC} (4626)   │       │  FxReceipt{USDC, EURC} (4626)  │
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
| HFT FX trade or perp | Arc-routed spoke | Land on Arc hub; trade with sub-second finality |
| Bridge funds between hubs (no user action needed) | Protocol does this automatically via Stage 6 + Circle Gateway | Liquidity stays unified |

---

## Live deployments

### Fuji — money-market hub (chain `43113`, CCTP V2 domain 1, Gateway domain 1)

| Contract | Address |
|---|---|
| FxSpoke (Fuji-local) | `0xb7fc291c27f6a7a659d4d229e5d8a55e58f26ab1` |
| FxSpoke (Fuji → Arc) | `0xe22ef07a0996df9ae6252cc9bf491fbe13fd6575` |
| **FxHubMessageReceiver** (Stage 6) | `0x7eAdfD0c08dd6544f763285bBD31be14179d594B` |
| **FxGatewayHook** (Stage 6) | `0x7dA191bfB85D9F14069228cf618519BFb41f371E` |
| FxMarketRegistry | `0x7ba745b979e027992ECFa51207666e3F5B46cF0a` |
| FxOracle | `0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b` |
| FxLiquidator | `0x2900599ff0e6dd057493d62fac856e5a8f93c6eb` |
| FxReceiptEURC | `0xefd7cf5ad5a2db9a3c23e2807f2279de92c730d2` |
| FxReceiptUSDC | `0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e` |
| MorphoBlue (self-deployed) | `0xeF64621D41093144D9ED8aB8327eE381ECdB79E6` |

Full manifest: [`deployments/avalanche-fuji.json`](deployments/avalanche-fuji.json) + [`deployments/hub-config-fuji.json`](deployments/hub-config-fuji.json).

### Arc Testnet — trading-execution hub (chain `5042002`, CCTP V2 domain 26, Gateway domain 26)

| Contract | Address |
|---|---|
| FxSpoke (Arc → Fuji) | `0x13c8463589d460db6f21235eedfd678c22a1ea25` |
| FxSpoke (Arc-local) | `0x5d10d2c3b9951054845534b2f60a68ebc0898cd3` |
| **FxHubMessageReceiver** (Stage 6) | `0x44B50E93eCC7775aF99bcd04c30e1A00da80F63C` |
| **FxGatewayHook** (Stage 6) | `0x2931C50745334d6DFf9eC4E3106fE05b49717DF1` |
| FxMarketRegistry | `0x813232259c9b922e7571F15220617C80581f1464` |
| FxOracle | `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865` |
| FxLiquidator | `0xa50f7D4D4a1A0D3CF418515973545b80E037B379` |
| FxReceiptEURC | `0xF829f57Db8530fa93FCD6e13b00193cbe8cE1493` |
| FxReceiptUSDC | `0xdd22365Bba7330BE537c9BC26da9b1b4Db9aC431` |
| MorphoBlue (self-deployed) | `0x3c9b95C6E7B23f094f066733E7797C8680760830` |

Full manifest: [`deployments/arc-testnet.json`](deployments/arc-testnet.json) + [`deployments/hub-config-arc.json`](deployments/hub-config-arc.json).

Fresh Morpho Labs-backed Arc hub broadcast (2026-05-21) is live for tomorrow's
rewire rehearsal. It uses MorphoBlue
`0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4`, AdaptiveCurveIrm
`0xBD583cc9807980f9e41f7c8250f594fB6173abE3`, and registers both `EURC/USDC`
and `cirBTC/USDC` market directions before timelock handoff. Keep the Stage 6
route above as SDK/default until Circle SCP, spokes, and Gateway wiring are
intentionally switched. Fresh manifest:
[`deployments/arc-testnet-morpho-labs-cirbtc-5042002.json`](deployments/arc-testnet-morpho-labs-cirbtc-5042002.json).

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
| cirBTC test collateral (`fCirBTC`) | `0x44cEe9E472C34b2f0d9710CD8aBd02dadb912761` |
| FxOracle | `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865` |
| Keeper / admin | `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` |

Perps manifest: [`deployments/perps-5042002.json`](deployments/perps-5042002.json). Config manifest: [`deployments/perps-config-5042002.json`](deployments/perps-config-5042002.json), now including `CIRBTC_USDC`. Trading smoke report: [`reports/SMOKE_ARC_PHASE_B_E_TRADING.md`](reports/SMOKE_ARC_PHASE_B_E_TRADING.md).

#### Arc Yield Machine — P1 (`FxReserveYieldRouter`)

The idle-capital sink: subscribes/redeems USYC via the Circle Teller on its own behalf, tier-gated to protocol/institutional only (retail NAV never touches USYC). UUPS proxy, deployer EOA holds `DEFAULT_ADMIN` + timelock/`UPGRADER`. Watermarks 5k/20k USDC.

| Contract | Address |
|---|---|
| **FxReserveYieldRouter** (proxy) | `0x623d0DAfA24B59809a9fBfa3a60148F69aaB8b06` |
| FxReserveYieldRouter (impl) | `0x38dE00A43011d13B10E614Af18737fb3EF33CCd7` |
| USYC | `0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C` |
| USYC Teller | `0x9fdF14c5B14173D74C08Af27AebFf39240dC105A` |
| USYC Entitlements | `0xcc205224862c7641930c87679e98999d23c26113` |

`FUNDER_ROLE` + `KEEPER_ROLE` granted to keeper `0xcA02Be6cDBb806d4a327FC92E094D1A44EC37445`. The USYC sink (`deployToYield` / rebalance-into-USYC) stays dormant until Circle entitles the **proxy** address in Entitlements; Morpho/par-pure paths work today. Deploy script: `contracts/script/DeployReserveYieldRouter.s.sol`.

### Spokes — 16 total, dual-routed per chain

Every chain hosts both a Fuji-routed spoke and an Arc-routed spoke. Users pick by intent.

| Chain | chainId | CCTP V2 | FxSpoke → Fuji | FxSpoke → Arc |
|---|---|---|---|---|
| Ethereum Sepolia | 11155111 | 0 | `0xdabf610c…4fd4` | `0x4e639546…ffa9` |
| OP Sepolia | 11155420 | 2 | `0xef64621d…79e6` | `0x579fccde…e28c` |
| Arbitrum Sepolia | 421614 | 3 | `0x9f0947d7…b88e` | `0x365de300…4362` |
| Polygon Amoy | 80002 | 7 | `0x50c4ba39…4992` | `0x7882d3f0…1e5a` |
| Unichain Sepolia | 1301 | 10 | `0x50c4ba39…4992` | `0x7882d3f0…1e5a` |
| World Chain Sepolia | 4801 | 14 | `0xef64621d…79e6` | `0x579fccde…e28c` |
| Avalanche Fuji (local) | 43113 | 1 | `0xb7fc291c…6ab1` | `0xe22ef07a…6575` |
| Arc Testnet (local) | 5042002 | 26 | `0x13c84635…ea25` | `0x5d10d2c3…8cd3` |

Each chain manifest has a `routes:` block describing both. See e.g. [`deployments/ethereum-sepolia.json`](deployments/ethereum-sepolia.json).

### Circle Gateway (deterministic CREATE2, same on every testnet)

- `GatewayWallet`  `0x0077777d7EBA4688BDeF3E311b846F25870A19B9`
- `GatewayMinter`  `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B`

### Privacy Hook (Ghost Mode) — shielded USDC pools, live on both hubs

0xbow privacy-pools-core ported into fx-Telaraña: per-currency shielded pools with Morpho yield rehypothecation. v1 scope is **USDC-only**, no cross-currency relay wired yet (`relayCrossCurrency` reverts `SwapAdapterNotSet`). Cross-ccy unlocks when a concrete `IFxRouterSwapAdapter` ships against `FxSwapHook`.

| Contract | Fuji | Arc Testnet |
|---|---|---|
| **FxPrivacyEntrypoint** (UUPS proxy) | `0x6d5e3d5be0be2b29d48eda2fa35fa8d787d3c953` | `0xd11cddd1f04e850d3810a71608a49907c80f2736` |
| **FxPrivacyPool (USDC)** | `0xc490be46d2b87b92f146ab4dd907784d9658ec7f` | `0xc11c216c9c7a36848b1d4276d223160c8b51988f` |
| FxPrivacyEntrypoint impl | `0xcd04c6e2277a50c93368da77a28ba917083c205a` | `0x4506441df7960b2cb2b600b0d37dfd3ea79fa92a` |
| WithdrawalVerifier | `0x18bd44dd57661ed746e127b378bf1d8e2ae64bf1` | `0x7f0326cea0796e31ed38f01b1e8660faad7bb6ee` |
| CommitmentVerifier (ragequit) | `0x4c4e1ec5dae12a8cbac7ff4187e2c3e5719ac71b` | `0x9056facd889a94e4acba8cbc4c8a81ed47ba8ea0` |
| Collateral leg (Morpho rehyp) | MockEURC `0x50c4ba39…4992` | **real Circle EURC** `0x89b50855…d72a` |

PSE Poseidon (deterministic across chains, deployed via Arachnid CREATE2):

- `PoseidonT3` — `0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93`
- `PoseidonT4` — `0x4443338EF595F44e0121df4C21102677B142ECF0`

Full manifests: [`deployments/privacy-hook-fuji.json`](deployments/privacy-hook-fuji.json) + [`deployments/privacy-hook-arc.json`](deployments/privacy-hook-arc.json). Deploy scripts: `contracts/script/DeployPoseidon.s.sol`, `DeployPrivacyHookFuji.s.sol`, `DeployPrivacyHookArc.s.sol`. Run with `FOUNDRY_PROFILE=deploy` so the library linker hits the canonical Poseidon addresses.

### Authority

Deployer EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` signs BurnIntents off-chain and owns both hubs until Circle's EIP-1271 support lands (Corey's mid-July 2026 ETA). At that point authority rotates to the local `FxHubMessageReceiver` via `setAuthority(...)` and signing becomes fully contract-bound. See [`CLAUDE.md`](CLAUDE.md) for the rotation plan.

Privacy hub: deployer also holds `OWNER_ROLE` + `ASP_POSTMAN` on both FxPrivacyEntrypoint proxies. The single-writer ASP_POSTMAN role rotates to the relayer EOA once the relayer service has a stable key (see `packages/relayer-privacy/README.md` for the rotation runbook).

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

- **FX money market over Morpho Blue** — isolated USDC↔EURC markets at MVP. JPYC / BRL / MXNB / QCAD / ZCHF on the roadmap (waiting on testnet contract addresses from Circle for the broader StableFx basket).
- **Cross-chain spokes via CCTP V2** — bring USDC and EURC (where Circle supports it) from any CCTP-supported chain. Opens a position on the destination hub atomically inside the hub-message receiver. Dual-routed: one spoke per chain per hub.
- **Cross-hub liquidity via Circle Gateway** — hub-only `FxGatewayHook` on each chain, signed by deployer EOA today, hub-contract-via-1271 from mid-July. Sub-second finality on Arc means cross-hub liquidity moves can happen inside a single FX-trade context.
- **Stage 6 hub-routed relay** — `relayToRemoteHub` + `relayMintFromRemote` on `FxHubMessageReceiver`, gated by `owner` + `relayCallers` whitelist. BUFX (separate repo) calls in here for cross-hub liquidity moves.
- **Decentralized oracle** — Pyth primary + RedStone secondary, the only price-read surface (`IFxOracle`). 24/7. No forex-hours circuit breakers.
- **Uniswap V4 hooks (in progress)** — oracle-anchored quote, dynamic fees, JIT-borrow on output shortfall, afterSwap fee rebalance into Morpho (Bunni pattern). `FxSwapHook.sol` ships as constant-spread MVP; cross-hub orchestration is BUFX's responsibility (its state machine sits on top of Stage 6 primitives — same-tx atomicity is impossible because Gateway is ~349ms async).
- **Ghost Mode (Phase 1)** — Bufi Wallet / RO-KYC pass-gated spoke entry, commitment/nullifier registry, minimal v4 KYC hook scaffolding.
- **BUFX layer** (separate repo) — spot + perps StableFx execution riding on this substrate. Whitelist via `hub.setRelayCaller(bufxAddress, true)` once their contracts deploy.

---

## Capital efficiency — `SharedFxVault` (advancing Aqua0's Hookathon design)

[**Aqua0**](https://github.com/Aqua0-fi) — a recent **Hookathon** participant (YC / Founders Inc credit, incubated by 1inch + Uniswap) — ships a sharp thesis: *one LP deposit should back many pools*, via a shared vault that JIT-injects liquidity into Uniswap v4 pools. Their `avax-aqua0` shared-liquidity hook (MIT) validated the idea on Avalanche for LATAM stablecoins. We took the thesis and **built a leaner, safer version on our oracle-anchored PMM** — `contracts/src/vault/SharedFxVault.sol` (UUPS, ERC-4626, 10/10 tests). Spec: [`docs/architecture/shared-fx-vault-spec.md`](https://github.com/) (BUFX repo).

**Why ours advances theirs:**

| Dimension | Aqua0 (`avax-aqua0`) | BUFX `SharedFxVault` |
|---|---|---|
| **JIT mechanism** | Injects `modifyLiquidity` ranges per swap, then burns them (transient-storage round-trip, backend-signed range authorizations) | **None needed.** Our v4 pools are empty by design — `FxSwapHook` serves 100% of each swap via `beforeSwapReturnDelta` (oracle-anchored PMM). We share *reserves*, not ranges. Fewer moving parts, smaller attack surface. |
| **Accounting** | No on-chain LP balances; a backend signer authorizes withdrawals (single point of failure — a compromised signer drains the vault) | **Real on-chain ERC-4626 ledger.** `totalAssets()` is pure USDC (hot + Morpho) — **no oracle in the share price**, deleting the #1 manipulation vector. No backend signer in the value path. |
| **Risk isolation** | One undifferentiated pool | **Senior / junior tranches.** Senior (lenders) USDC sits in Morpho Blue (overcollateralized, redeemable); a protocol-funded junior buffer takes *all* market-making PnL first. A swap can never reduce senior principal. |
| **Hook trust** | Any contract inheriting the ERC-165 marker is auto-trusted to pull funds (flagged risk) | **Explicit per-hook allowlist** (`HOOK_ROLE`). |
| **Drain guards** | None beyond range bounds | Per-swap + per-block notional **caps** + an oracle-move **circuit breaker** — load-bearing because Arc has only one oracle (no Chainlink/RedStone). |
| **Yield on idle** | Idle capital sits | **Morpho rehypothecation** — idle senior USDC earns lending yield while it waits. |
| **Upgrades** | UUPS, deployer == owner == signer | UUPS with `_authorizeUpgrade` gated by a **TimelockController** (`UPGRADER_ROLE`) — no instant rug. ERC-7201 namespaced storage, `_disableInitializers()`. |
| **Tests** | Zero | Fuzz/unit suite, growing toward invariants; external audit gated before lender deposits. |

Same insight — *one balance, many pools* — but rebuilt for an oracle-anchored PMM with on-chain accounting, tranche-protected lender capital, and a rugproof upgrade path. Designed with `/v4-security-foundations` + `/adversarial-uniswap-hooks` + OpenZeppelin's `/upgrade-solidity-contracts` and `/develop-secure-contracts`. **We don't compete with Uniswap LPs — we make a single deposit back every BUFX FX pool, and let lenders earn on it.**

---

## The Yield Machine

> Every dollar in the protocol is, at every instant, either **earning spread** (serving a swap) or **earning yield** (USYC / Morpho). Never idle. Full spec: `defi-web-app/docs/architecture/yield-machine-spec.md` (BUFX repo).

**Two hard invariants:**
1. **Performance law — the swap hot path never touches yield or Gateway.** `beforeSwap` stays byte-for-byte unchanged (<50k gas, one vault call, zero new external calls). All yield/cross-chain movement is out-of-band.
2. **Compliance law — retail NAV never touches USYC.** USYC is Reg-S (institutions only). Enforced on-chain as `retailAssets ∩ USYC = ∅`, not as a policy note.

### v4 delta-accounting is *why* capital can earn yield at all

`FxSwapHook` uses `beforeSwapReturnDelta` (the "delta hook") with **empty pools**. The pool is just a routable `PoolKey`; the hook prices the swap from the oracle PMM and pulls the fill from the vault **just-in-time**. No concentrated liquidity ever sits in the pool.

That is the enabling trick. **Because the pool is empty, the capital that backs it doesn't have to be in the pool — it can be off in USYC and Morpho earning yield, and the delta hook summons it back only at the instant of a swap.** Without v4 delta-accounting, "no idle capital" is impossible; the liquidity would be trapped in pools. With it, the liquidity lives in the yield machine and the pool is just a window onto it. The delta hook isn't adjacent to the yield machine — **it is the mechanism that frees the capital to be a yield machine.**

### The hooks as machine parts

| Hook | Role in the machine |
|---|---|
| **FxSwapHook** (delta accounting) | The **spread engine + JIT summon.** Earns the 30bps spread on every swap (the "AMM spread" half of honest yield); its empty-pool design lets the backing capital go earn yield between swaps. |
| **FxHedgeHook** (hookathon) | The **IL shield.** Auto-opens BTC short perps to neutralize LP exposure → less IL drag → higher *net* yield to LPs. Links the perps book to the LP book. |
| **FxGatewayHook** `0x2931C50…` | The **cross-hub rail.** Lock/burn on Arc, mint on Fuji/Arbitrum, so working capital can be wherever a swap lands (349ms attestor latency). Becomes fully contract-authorized once Circle ships ERC-1271 on burn intents (authority rotates from the deployer EOA to `FxHubMessageReceiver`). |

### The full machine

```
  SharedFxVault capital (senior working capital + junior backstop + FX inventory)
        │
        ├─ serving a swap?  → FxSwapHook delta-fill → earns SPREAD          ◀ Uniswap v4
        │                                                                      (+ FxHedgeHook trims IL)
        └─ idle right now?  → FxReserveYieldRouter:
                                 ├─ USDC → Morpho lending APY   (retail-OK)   ◀ Arc/Fuji money market
                                 ├─ FX   → Morpho FX-loan APY    (retail-OK)
                                 └─ USDC → USYC T-bill floor     (INSTI ONLY)  ◀ Circle Teller
        +
  TurboFeeVault: 40% of perp + swap fees ──▶ distributed back to LPs (cross-hub via Gateway)
        │
  Permissionless on-chain rebalance() moves dollars between "serving" and "earning",
  and across hubs via Gateway. Swaps never wait on it (local buffer + perSwapCapBps).
```

### The compliance wall — an on-chain invariant, not a policy note

USYC yield can never touch retail. USYC is Reg-S, institutions only. The machine carries tier-aware accounting, enforced in the contract:

| Tier | Eligible yield | NAV rule |
|---|---|---|
| **Retail** (public lenders) | AMM spread + Morpho lending APY + perp-fee share | **Par-pure USDC NAV. USYC NAV is *never* in retail share price.** |
| **Institutional** (KYB'd) | all of the above **+ USYC** | opts into RWA NAV explicitly |
| **Protocol / junior** (treasury, first-loss) | USYC + everything | we own it; no retail exposure |

The router tags capital by tier and **refuses to route retail dollars into the USYC sink.** Audit invariant: `retailAssets ∩ USYC = ∅`. Retail isn't shortchanged — its three sources (lending base + spread + perp fees) are strong on their own; USYC is the institutional/treasury sweetener on top.

### Seamless = it self-operates

No babysitter, no off-chain SaaS. Swaps auto-generate spread and auto-trigger replenishment; idle auto-flows to the best *eligible* sink per tier; fees auto-distribute; the hedge auto-adjusts. The only humans are governance setting params. A permissionless on-chain `rebalance()` + the delta-hook JIT is the seamlessness.

### Build order

- **P1 (now):** `FxReserveYieldRouter` + USYC sink, tier-gated to protocol/institutional only — kills idle USD, sets the retail-exclusion invariant in code before any retail lender exists.
- **P2:** activate Morpho sinks (USDC-loan retail base yield + FX-loan for inventory).
- **P3:** wire TurboFeeVault perp-fee distribution cross-hub via Gateway.
- **P4:** FxHedgeHook IL protection as the net-yield amplifier.

Each phase adds a yield source to the same machine without touching the swap path or the retail/USYC wall.

---

## Repo layout

```
contracts/                        Foundry — protocol contracts, tests, deploy scripts
  src/
    hub/                          FxHubMessageReceiver (Stage 6), FxMarketRegistry, FxOracle,
                                  FxLiquidator, FxReceipt, FxSwapHook, MorphoOracleAdapter,
                                  FxGatewayHook
    vault/                        SharedFxVault (UUPS ERC-4626 shared JIT liquidity) +
                                  interfaces/ISharedFxVault — one deposit backs all FX pools
    spoke/                        FxSpoke
    interfaces/                   IFxOracle, IFxMarketRegistry, IFxSpoke,
                                  IFxHubMessageReceiver, IFxGatewayHook, IGateway
    libraries/                    CctpMessageLib
  script/                         DeployArcTestnet, DeployAvalancheFuji, DeployBaseSepolia,
                                  DeployFxSpoke, DeployFxGatewayHook, …
  test/                           Foundry tests (unit + mainnet fork) — 217/217 passing
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

# tests — 217/217 forge passing
cd contracts && forge test
bun run sdk:test

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

- **217/217 Foundry unit tests** passing (hub + spoke + FxGatewayHook + FxHubMessageReceiverRelay)
- **4/4 ETH mainnet fork tests** against the live Morpho Blue singleton at `0xBBBBBbbBBb…7EEFFCb`
- **128-sim Tenderly regression matrix** across deposit / borrow / withdraw / sweep / liquidate / swap / CCTP-reverse flows
- **2 rounds of Codex adversarial review**, all findings patched
- **End-to-end USDC→EURC swap** via Universal Router V4_SWAP on Base Sepolia (~405k gas)
- **End-to-end Gateway Fuji→Arc liquidity move** — both bypass + hook-routed flows verified live (~349ms attestor)

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
- Full address book + integration reference for BUFX

### Next, in priority order

1. **Real-stablecoin testnet contracts (when Circle ships them).** Replaces MockEURC with the canonical EURC + adds JPYC / BRL / MXNB / QCAD / ZCHF markets. Self-redeploy `FxMarketRegistry` market entries; receipts + liquidators stay the same.
2. **BUFX lands.** Whitelist via `hub.setRelayCaller(bufxAddress, true)` on both hubs. Stage 6 surface is the integration point.
3. **Joint adversarial audit — Telaraña + BUFX working together.** Codex (and external reviewer) drives end-to-end flows: user enters Polygon spoke → routes to Fuji → opens position → BUFX takes Arc-side trade → Stage 6 moves USDC → close position → CCTP back to Polygon. Two rounds: round 1 lifecycle correctness, round 2 adversarial / MEV / front-run scenarios.
4. **EIP-1271 authority rotation** (mid-July 2026). Implement `isValidSignature` on `FxHubMessageReceiver` (gates which BurnIntents the protocol authorizes — domain pair, value cap, deadline). Call `hook.setAuthority(hub)` on both chains. Retire the off-chain EOA signer.
5. **Tenderly Avalanche stress run.** Same contracts on the primed Fuji vnet; Tenderly Pro snapshot branching for parallel scenario coverage; targets multi-million-USDC per intent (we've validated $0.10 live, architecture targets $10M+).
6. **API package + frontend proof-of-concept.** SDK already typed; surface a clean public API for BUFX + integrators. Frontend demo proves the full flow: pick chain → pick hub destination → enter → trade → exit.
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
