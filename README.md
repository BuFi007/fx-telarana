<p align="center">
  <img src="docs/assets/banner.jpg" alt="BU.FI — FX Telaraña Protocol" />
</p>

# FX Telaraña Protocol

> *Telaraña — "spider's web" — for the hub-and-spoke topology that pulls stablecoin FX liquidity from every USDC chain into canonical hub markets, then weaves those hubs together with Circle Gateway.*

Cross-chain onchain forex credit, settlement, and execution. Two live hubs bridged by Circle Gateway. Eight spokes routing into the primary hub via CCTP V2. Morpho Blue substrate. Pyth + RedStone oracles. Uniswap V4 hooks. Native USDC, never wrapped.

---

## TL;DR

**Two-hub, multi-spoke architecture, all live on testnet.**

- **Avalanche Fuji — primary hub.** All user deposits route here via CCTP V2 spokes. Holds the borrow/lend money market over Morpho Blue.
- **Arc Testnet — trading-execution hub.** Receives USDC liquidity from Fuji via `FxGatewayHook`. Sub-second finality + native-USDC gas = built for HFT-grade FX execution.
- **8 spokes — Ethereum / OP / Arbitrum / Polygon / Unichain / World Chain / Arc / Fuji-on-Fuji** — each lets users enter USDC and route to the Fuji hub through CCTP V2.
- **Circle Gateway** bridges the two hubs at the protocol level (never user-initiated). Verified end-to-end: real attestation, real cross-chain mint, **~500ms** Circle attestor latency. See [`docs/GATEWAY_E2E.md`](docs/GATEWAY_E2E.md).
- **BUFX** — separate spot+perps execution layer riding on this substrate. See [`docs/BUFX_INTEGRATION.md`](docs/BUFX_INTEGRATION.md) for the address book + integration interface.

---

## Topology

```
                            ┌──────────────────────────────┐
                            │   Circle Gateway (USDC)      │
                            │   <500ms attestor latency    │
                            │                              │
                            ▼                              │
┌─────────────────────────────────┐       ┌───────────────┴────────────────┐
│         FUJI HUB (chain 43113)  │       │      ARC HUB (chain 5042002)   │
│         primary deposit venue   │◀─────▶│      trading execution hub     │
│                                 │ FxGw  │                                │
│  FxHubMessageReceiver           │ Hook  │  FxHubMessageReceiver          │
│  FxMarketRegistry (Morpho Blue) │       │  FxMarketRegistry (Morpho Blue)│
│  FxOracle (Pyth+RedStone)       │       │  FxOracle (Pyth+RedStone)      │
│  FxReceipt{USDC, EURC} (4626)   │       │  FxReceipt{USDC, EURC} (4626)  │
│  FxLiquidator                   │       │  FxLiquidator                  │
│  FxSpoke (local)                │       │  FxSpoke (local)               │
│  FxGatewayHook                  │       │  FxGatewayHook                 │
└──────▲──────▲──────▲──────▲──────┘       └────────────────────────────────┘
       │      │      │      │
       │      │      │      └─── Polygon Amoy FxSpoke (CCTP V2 domain 7)
       │      │      └────────── Worldchain Sepolia FxSpoke (domain 14)
       │      └───────────────── Optimism Sepolia FxSpoke (domain 2)
       │                                                    
   Ethereum Sepolia, Arbitrum Sepolia, Unichain Sepolia, Arc Testnet
   (all 8 spokes pin HUB_RECEIVER to the Fuji address)
```

User flow (deposit/borrow):
1. User enters any spoke chain → `FxSpoke.enterHub(token, amount, beneficiary, hubCalldata)`
2. CCTP V2 burn on source + hookData
3. `FxHubMessageReceiver.executeDeposit(...)` mints USDC on Fuji + atomically calls `FxMarketRegistry`
4. User has supply/borrow position on the Fuji hub

Protocol flow (cross-hub liquidity for FX execution):
1. Trader requests an FX swap that needs Arc-side depth
2. Fuji hub calls `FxGatewayHook.lockForRemote(amount)` → `GatewayWallet.depositFor`
3. Off-chain signer service builds + signs BurnIntent (deployer EOA today; hub-via-EIP-1271 from mid-July)
4. Circle's operator attests in <500ms
5. Arc hub calls `FxGatewayHook.mintFromRemote(attestation, signature)` → USDC lands at Arc hub
6. Arc-side Uniswap V4 hook executes the FX leg against local Morpho markets

---

## Live deployments

### Fuji — primary hub (chain `43113`, CCTP V2 domain 1, Gateway domain 1)

| Contract | Address |
|---|---|
| FxSpoke (local) | `0xcD1621B6118416AB4A43accEFdF44485519135B8` |
| **FxHubMessageReceiver** | `0x365DE300dDa61C81a33bcE3606A5d524eD964362` |
| **FxGatewayHook** | `0xc63634ebc99f9c9616ee126971CCa486f3AFfF6E` |
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
| FxSpoke | `0x729fe51fa88eae24cbcff7a192c5a91e937ceb68` |
| **FxHubMessageReceiver** | `0x07db64fb19C6c4a1eBB1B7bfdaFd4676b43Cf276` |
| **FxGatewayHook** | `0x004cfa0305c365b1d9b2365f85acf216c96b0e13` |
| FxMarketRegistry | `0x813232259c9b922e7571F15220617C80581f1464` |
| FxOracle | `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865` |
| FxLiquidator | `0xa50f7D4D4a1A0D3CF418515973545b80E037B379` |
| FxReceiptEURC | `0xF829f57Db8530fa93FCD6e13b00193cbe8cE1493` |
| FxReceiptUSDC | `0xdd22365Bba7330BE537c9BC26da9b1b4Db9aC431` |
| MorphoBlue (self-deployed) | `0x3c9b95C6E7B23f094f066733E7797C8680760830` |

Full manifest: [`deployments/arc-testnet.json`](deployments/arc-testnet.json) + [`deployments/hub-config-arc.json`](deployments/hub-config-arc.json).

### Spokes (all route to Fuji hub)

| Chain | chainId | CCTP V2 domain | FxSpoke |
|---|---|---|---|
| Ethereum Sepolia | 11155111 | 0 | `0xdabf610c279d900b40ca4df62f1e86cc2d0a4fd4` |
| OP Sepolia | 11155420 | 2 | `0xef64621d41093144d9ed8ab8327ee381ecdb79e6` |
| Arbitrum Sepolia | 421614 | 3 | `0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e` |
| Polygon Amoy | 80002 | 7 | `0x50c4ba39caa7f56152d0df4914e1f6b907194992` |
| Unichain Sepolia | 1301 | 10 | `0x50c4ba39caa7f56152d0df4914e1f6b907194992` |
| World Chain Sepolia | 4801 | 14 | `0xef64621d41093144d9ed8ab8327ee381ecdb79e6` |
| Arc Testnet | 5042002 | 26 | `0x729fe51fa88eae24cbcff7a192c5a91e937ceb68` |
| Avalanche Fuji (local) | 43113 | 1 | `0xcD1621B6118416AB4A43accEFdF44485519135B8` |

### Circle Gateway (deterministic CREATE2, same on every testnet)

- `GatewayWallet`  `0x0077777d7EBA4688BDeF3E311b846F25870A19B9`
- `GatewayMinter`  `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B`

### Authority

Deployer EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` signs BurnIntents off-chain until Circle's EIP-1271 support lands (mid-July 2026). At that point authority rotates to the local `FxHubMessageReceiver` via `setAuthority(...)` and signing becomes fully contract-bound. See [`CLAUDE.md`](CLAUDE.md) for the rotation plan.

---

## Proof of life — Gateway end-to-end

Real testnet, real Circle attestation, no mocks. Run via [`packages/sdk/scripts/gateway-signer.ts`](packages/sdk/scripts/gateway-signer.ts):

| Step | Tx | Latency |
|---|---|---|
| 1. Approve GatewayWallet on Fuji | `0x7de6daa2…92ca` | — |
| 2. `depositFor($2 → Gateway, depositor=EOA)` on Fuji | `0x84966b1e…5937` | — |
| 3. Circle operator picks up deposit | — | ~12s |
| 4. Build + EIP-712 sign BurnIntent (local) | — | <1ms |
| 5. POST to `https://gateway-api-testnet.circle.com/v1/transfer` | — | **397ms** |
| 6. `gatewayMint(attestation, sig)` on Arc | `0x60418160…ac1b` | — |
| 7. Verify USDC delta on Arc | — | ✓ |

Fee: $0.020005 per $0.10 transfer (~20bps). Confirms the architect's "Gateway as HFT primitive" thesis — sub-500ms attestor latency means you can use it as a sub-block cross-chain settlement layer.

Full walkthrough: [`docs/GATEWAY_E2E.md`](docs/GATEWAY_E2E.md).

---

## What it is

- **FX money market over Morpho Blue** — isolated USDC↔EURC markets at MVP (plus the rest of the listed-stablecoin basket on the roadmap: JPYC, BRL, MXNB, QCAD, ZCHF). Borrowers post one stablecoin, take the other.
- **Cross-chain spokes via CCTP V2** — bring USDC and EURC (where Circle supports it) from any CCTP-supported chain. Opens a position on the Fuji hub atomically inside the hub-message receiver.
- **Cross-hub liquidity via Circle Gateway** — hub-only `FxGatewayHook` on each chain, signed by deployer EOA today, hub-contract-via-1271 from mid-July. Sub-second finality on Arc means cross-hub liquidity moves can happen inside a single FX-trade context window.
- **Decentralized oracle** — Pyth primary + RedStone secondary, the only price-read surface (`IFxOracle`). 24/7. No forex-hours circuit breakers. USDC and EURC are ERC-20s onchain.
- **Uniswap V4 hooks (in progress)** — oracle-anchored quote, dynamic fees, JIT-borrow on output shortfall, afterSwap fee rebalance into Morpho (Bunni pattern). `FxSwapHook.sol` ships as constant-spread MVP; full PMM + Gateway-routed cross-hub trades land next.
- **Ghost Mode (Phase 1)** — Bufi Wallet / RO-KYC pass-gated spoke entry, commitment/nullifier registry, minimal v4 KYC hook scaffolding. No third-party privacy wallet dependency.
- **BUFX layer** (separate repo) — spot + perps StableFx execution riding on this substrate.

---

## Repo layout

```
contracts/                        Foundry — protocol contracts, tests, deploy scripts
  src/
    hub/                          FxHubMessageReceiver, FxMarketRegistry, FxOracle, FxLiquidator,
                                  FxReceipt, FxSwapHook, MorphoOracleAdapter, FxGatewayHook
    spoke/                        FxSpoke
    interfaces/                   IFxOracle, IFxMarketRegistry, IFxSpoke, IFxHubMessageReceiver,
                                  IGateway (minimal Circle Gateway interfaces)
    libraries/                    CctpMessageLib
  script/                         DeployArcTestnet, DeployAvalancheFuji, DeployBaseSepolia,
                                  DeployFxSpoke, DeployFxGatewayHook, …
  test/                           Foundry tests (unit + mainnet fork)
packages/sdk/                     @bu/fx-engine — TypeScript SDK
  src/
    gateway.ts                    Gateway types, ABIs, route configs, EIP-712 helpers
    addresses/                    Per-chain address book
    abis/                         Auto-synced contract ABIs
  scripts/
    gateway-signer.ts             ⭐ Off-chain BurnIntent signer service
    migrate-hub.ts                Hub-migration orchestrator (preflight + state-file audit trail)
    simulator/                    Tenderly Simulator regression suite
    tenderly-*.sh                 Tenderly vnet management (priming, restoration, verification)
deployments/                      Per-chain manifests (avalanche-fuji.json, arc-testnet.json, …)
                                  + hub-config-{fuji,arc}.json (migrate-hub targets)
docs/
  SPEC.md                         Engineering spec
  BUFX_INTEGRATION.md             ⭐ BUFX integration reference (addresses + interfaces)
  GATEWAY_E2E.md                  ⭐ Gateway end-to-end procedure (bypass + hook-routed)
  whitepaper/                     LaTeX source
reports/                          Simulator matrices, eval reports, attestation logs
```

---

## Quick start

```bash
# install
bun install
git submodule update --init --recursive

# tests
bun run contracts:test                  # unit
bun run contracts:test:fork             # + ETH mainnet fork (against real Morpho Blue)
bun run sdk:test

# explore the live deployments
bun packages/sdk/scripts/gateway-signer.ts info        # Circle's supported chains
bun packages/sdk/scripts/gateway-signer.ts balances    # deployer's Gateway USDC across both routes
```

### Gateway end-to-end (live testnet, ~$0.10 USDC, ~30 seconds)

Requires deployer wallet funded with ≥2 USDC on Fuji via [faucet.circle.com](https://faucet.circle.com):

```bash
source .env.local
bun packages/sdk/scripts/gateway-signer.ts deposit fuji 2000000
# wait ~12s for Circle to pick up the deposit
bun packages/sdk/scripts/gateway-signer.ts balances
bun packages/sdk/scripts/gateway-signer.ts sign-and-attest gateway-fuji-to-arc-usdc 100000 --bypass
# copy the printed attestation + signature
bun packages/sdk/scripts/gateway-signer.ts gateway-mint arc <attestation> <signature>
```

Full walkthrough: [`docs/GATEWAY_E2E.md`](docs/GATEWAY_E2E.md).

---

## Testing summary

- **94/94 Foundry unit tests** passing (covers all hub + spoke contracts + FxGatewayHook)
- **4/4 ETH mainnet fork tests** passing against the live Morpho Blue singleton at `0xBBBBBbbBBb…7EEFFCb`
- **22/22 FxGatewayHook unit tests** (hub-only gates, deposit/mint/withdrawal flows, balance-delta invariant)
- **128-sim Tenderly regression matrix** across deposit / borrow / withdraw / sweep / liquidate / swap / CCTP-reverse flows
- **2 rounds of Codex adversarial review**, all findings patched ([commits `603af9c`, `f857d8e`](https://github.com/BuFi007/fx-telarana/commits/main))
- **End-to-end USDC→EURC swap** via Universal Router V4_SWAP on Base Sepolia (~405k gas)
- **End-to-end Gateway Fuji→Arc liquidity move** on real testnet (~30s wallclock, ~500ms attestor)

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

## Status

### Live
- Two-hub topology on Fuji + Arc
- 8 spokes routing to Fuji
- Circle Gateway integration (bypass-mode e2e verified end-to-end on real testnets)
- Off-chain BurnIntent signer service
- FxSwapHook MVP on Base Sepolia (constant-spread, real v4 + Pyth)

### In flight
- **Stage 6 plumbing** — `relayToRemoteHub` + `relayMintFromRemote` shims on `FxHubMessageReceiver` so the hook-routed Gateway path (`onlyHub`-gated) works from BUFX + protocol triggers. ~50 LOC + 1 test + hub redeploy.
- **FxSwapHook before/after wiring** — invoke `lockForRemote` / `mintFromRemote` from inside v4 hook callbacks so cross-hub FX trades are protocol-atomic.
- **EIP-1271 authority rotation** — flips the BurnIntent signer from deployer EOA to `FxHubMessageReceiver` contract once Circle ships 1271 support (Corey's mid-July 2026 ETA).
- **Stablecoin FX basket expansion** — JPYC, BRL, MXNB, QCAD, ZCHF markets on top of the USDC↔EURC pair.
- **Phase 2.5 swap hook** — DODO PMM curve math, LP rehypothecation via `FxMarketRegistry`, JIT-borrow on output shortfall.

### Next
- Live Gateway dogfood at higher scale (we ran $0.10; the architecture targets multi-million per intent)
- BUFX (separate repo) starts integrating against the surface in [`docs/BUFX_INTEGRATION.md`](docs/BUFX_INTEGRATION.md)
- 10B-TVL stress matrix on the Fuji vnet (Tenderly Pro snapshot branching)
- Mainnet deploy gated on completing the audit + 1271 rotation

---

## Attribution

The hook roadmap and the current truncated-observation / volatility-spread implementation are inspired by public Uniswap v4 hook examples, including the truncated oracle, volatility oracle, and TWAMM work by Austin Adams (`aadams`) and the Uniswap builders. The Ghost Mode direction also learns from the `blackbera/privacy-hook-univ4` privacy-hook concept and public KYC hook examples, while avoiding unsafe patterns like `tx.origin` authorization.

The dual-hub Gateway architecture is informed by direct conversations with the Circle Gateway team — particularly the framing of Gateway as a sub-block HFT primitive — and built on top of the open-source contracts at [`circlefin/evm-gateway-contracts`](https://github.com/circlefin/evm-gateway-contracts).

Thank you to those builders for publishing useful reference work. Where we vendor or derive from third-party sources, we keep their SPDX headers, copyright notices, and NOTICE requirements with the imported files.

---

## License

Mixed-license by path and artifact type:

- **Apache-2.0** — smart contracts, Uniswap v4 hooks, public Solidity protocol libraries, and the public `@bu/fx-engine` SDK.
- **AGPL-3.0-only** — backend services, Hono APIs, indexers, monitors, simulators, deployment/registration workflows, and agent/workflow services.
- **MIT** — examples, templates, frontend demo components, and throwaway integration samples.

See [`LICENSE`](LICENSE) for the repo policy and `LICENSES/` for full license texts. Per-file SPDX headers are authoritative where present.
