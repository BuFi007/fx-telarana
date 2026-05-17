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

#### Arc Phase B-E perps stack

Trading is Arc-only for this stack. These contracts were deployed on Arc Testnet and smoke-tested through market config, funding config, liquidation config, protocol liquidity seed, quote, EIP-712 signed order settlement, funding poke, liquidation scan, flag, and liquidation.

| Contract | Address |
|---|---|
| FxPerpClearinghouse | `0x25cDf2ad4Fd446e85273c4D7C77a03F22C742865` |
| FxMarginAccount | `0x1869D0253286dF29ce0AB8d29207772C7fD9dc35` |
| FxFundingEngine | `0x725822e8BC6edbcBa52914149e25f2671290C6D2` |
| FxHealthChecker | `0x9cc0D71e2Af1532e74C2Af8aE7248ACB501039d5` |
| FxLiquidationEngine | `0x01f71c1E74350633bBC9d554ca35DA40412DCFB7` |
| FxOrderSettlement | `0x49ad97Fa2b67252373f4683bD4a4B49AA3AF5565` |

Supporting Arc addresses:

| Contract | Address |
|---|---|
| USDC | `0x3600000000000000000000000000000000000000` |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |
| FxOracle | `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865` |
| Keeper / admin | `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` |

Perps manifest: [`deployments/perps-5042002.json`](deployments/perps-5042002.json). Trading smoke report: [`reports/SMOKE_ARC_PHASE_B_E_TRADING.md`](reports/SMOKE_ARC_PHASE_B_E_TRADING.md).

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

### Authority

Deployer EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` signs BurnIntents off-chain and owns both hubs until Circle's EIP-1271 support lands (Corey's mid-July 2026 ETA). At that point authority rotates to the local `FxHubMessageReceiver` via `setAuthority(...)` and signing becomes fully contract-bound. See [`CLAUDE.md`](CLAUDE.md) for the rotation plan.

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
