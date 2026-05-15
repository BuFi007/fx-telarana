# Mainnet Hub Deployment Plan — fx-Telaraña on Avalanche

**Status:** Mainnet launch readiness plan. Companion to `docs/SPEC_PHASE_3_MULTI_STABLECOIN.md`.
**Last revision:** 2026-05-14 — Hub mainnet target = **Avalanche C-Chain** (was Arc-when-GA).
**Scope:** Hub deployment on Avalanche mainnet, Arc testnet as the staging tier, spoke deployment on chains hosting target stablecoins, mock testnet strategy on Arc until issuer-side deployments land.
**Constraint:** Code is deployment-portable — `script/Deploy.s.sol` reads addresses from env vars. Switching to Arc mainnet later, when Circle ships it, is a deploy-config change.

---

## 0. Headline strategy

1. **Hub mainnet = Avalanche C-Chain (`chainId 43114`).** 5 of 6 basket stablecoins are natively live on Avalanche (USDC, AUDF, JPYC, MXNB, KRW1) + ZCHF via CCIP. Zero mocks at mainnet — live demo with real assets.
2. **Hub testnet = Arc Testnet (`chainId 5042002`).** All Phase 2.5 / 2.6 / 2.6R / Phase 3 work iterates here. `MockStablecoin` instances stand in for the basket where issuer-canonical contracts don't exist on Arc.
3. **Spokes = every EVM chain that hosts Circle-supported USDC/EURC routes or is a major USDC/EURC entry point.** Spokes are thin: CCTP V2 burn-and-mint of USDC/EURC into the Hub, plus stranded-deposit recovery. Existing `FxSpoke` contract handles this lane.
4. **Local basket stablecoins live on the Hub or use Hyperlane / issuer-specific routes.** Users don't bridge AUDF / JPYC / MXNB / KRW1 / ZCHF through CCTP. They send USDC/EURC from any supported Circle spoke → Hub mints local stablecoin liquidity via Morpho borrow → FX swap → return USDC/EURC via CCTP where Circle supports it.
5. **No new contracts at mainnet.** Every contract used is already on the §2 whitelist of `SPEC_PHASE_3_MULTI_STABLECOIN.md`. This doc is deployment plumbing only.

---

## 1. Arc testnet — confirmed contracts (current development target)

Source: official Circle/Arc docs, last verified 2026-05-14.

### 1.1 Stablecoins (live on Arc testnet)

| Asset | Address | Decimals | Notes |
|---|---|---|---|
| USDC | `0x3600000000000000000000000000000000000000` | 6 (ERC-20) / 18 (native gas) | Native gas token on Arc. Faucet at faucet.circle.com. |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | 6 | Faucet at faucet.circle.com (select Arc Testnet). |
| USYC | `0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C` | 6 | **Gated** — KYB allowlist via Circle Support ticket. Not used in this protocol; flagged for Pasillo. |

### 1.2 CCTP V2 (Arc testnet — Domain 26)

| Contract | Address |
|---|---|
| TokenMessengerV2 | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` |
| MessageTransmitterV2 | `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` |

### 1.3 Other infrastructure (Arc testnet)

| Contract | Address | Notes |
|---|---|---|
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Canonical, same across EVM. Required for FxRouter (Phase 2.6R). |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` | Batched read aggregation. |
| CREATE2 Factory (Arachnid) | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | Deterministic deploys. |

### 1.4 Missing on Arc (mocks required for Phase 3 testnet)

| Asset | Status on Arc | Action |
|---|---|---|
| JPYC | Not deployed | **Deploy MockJPYC (18 dec)** on Arc testnet. |
| MXNB | Not deployed | **Deploy MockMXNB (6 dec)** on Arc testnet. |
| AUDF | Not deployed | **Deploy MockAUDF (6 dec)** on Arc testnet. |
| ZCHF | Not deployed | **Deploy MockZCHF (18 dec)** on Arc testnet. |
| KRW1 | Not deployed on Arc; Avalanche-native at `0x25a8…0318` | Deploy MockKRW1 at 0 decimals; Avalanche `decimals()` probe completed 2026-05-14. |
| Morpho Blue | Not deployed | Confirmed blocker. Either wait for Morpho Labs or self-deploy (immutable singleton, ~3KB). |
| AdaptiveCurveIRM | Not deployed | Same — co-deploy with Morpho self-deploy if going that route. |
| Pyth | Confirm per pair | `0x2880aB155794e7179c9eE2e38200202908C17B43` per current SDK. Feed IDs confirmed for Phase 3 FX basket; inverse feeds use `FxOracle.setPythFeedConfig(..., true)`. |
| RedStone | Confirm signer set | Feed symbols confirmed (`AUD`, `JPY`, `MXN`, `KRW`, `CHF`); verify production signer payload path on Arc during broadcast rehearsal. |

---

## 2. Mainnet target addresses — Avalanche C-Chain (Hub) + spokes

### 2.1 Phase 3 basket on Avalanche mainnet

All addresses below are Avalanche C-Chain (`chainId 43114`) unless flagged. Issuer-canonical where available; cross-reference Circle's [USDC](https://developers.circle.com/stablecoins/usdc-contract-addresses) + each issuer's docs at deploy time.

| Asset | Avalanche address | Decimals | Phase 3 tier | Notes |
|---|---|---|---|---|
| **USDC** | `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` | 6 | Tier 0 | Circle-native on Avalanche. |
| **EURC** | `0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD` | 6 | Tier 0 | Circle-native on Avalanche C-Chain. |
| **AUDF** | `0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b` | 6 | Tier 2 | Forte; same address on all EVMs. |
| **JPYC** | `0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB` | 18 | Tier 1 anchor | JPYC Inc. |
| **KRW1** | `0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318` | 0 | Tier 2 | BDACS; Avalanche `decimals()` probe returned 0 on 2026-05-14. |
| **MXNB** | `0xF197FFC28c23E0309B5559e7a166f2c6164C80aA` | 6 | Tier 1 anchor | Bitso/Juno; same address on all EVMs. |
| **ZCHF** | `0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553` | 18 | Tier 3 | Frankencoin CCIP-bridged on Avalanche; treat as single-chain pair on Hub. |

**Excluded from Phase 3:** PHPC, BRLA, QCAD (legacy), ZARU — see `docs/BLOCKED_PAIRS.md`.

### 2.2 CCTP V2 — Avalanche mainnet domain

| Field | Value |
|---|---|
| CCTP V2 Domain | 1 |
| TokenMessenger | per Circle docs at deploy time |
| MessageTransmitter | per Circle docs at deploy time |

**Source addresses programmatically** from Circle's docs at deploy time. Hardcoding rotates with chain additions and creates deploy-time drift.

### 2.3 Pyth + RedStone on Avalanche

| Provider | Avalanche mainnet address | Notes |
|---|---|---|
| Pyth Network | per [pyth.network](https://docs.pyth.network/price-feeds/contract-addresses/evm) at deploy time | Permissionless pull |
| RedStone | evm-connector pattern (no fixed address) | Cancun-required; already in foundry.toml |

Confirmed Phase 3 Pyth feed IDs:

| Asset | Feed | Feed id | `FxOracle` config |
|---|---|---|---|
| USDC | `USDC/USD` | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` | direct |
| EURC | `EURC/USD` | `0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c` | direct |
| AUDF | `AUD/USD` | `0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80` | direct |
| JPYC | `USD/JPY` | `0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52` | inverted |
| MXNB | `USD/MXN` | `0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca` | inverted |
| KRW1 | `USD/KRW` | `0xe539120487c29b4defdf9a53d337316ea022a2688978a468f9efd847201be7e3` | inverted |
| ZCHF | `USD/CHF` | `0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8` | inverted |

RedStone feed symbols confirmed through the public price API: `USDC`, `EUR`, `AUD`, `JPY`, `MXN`, `KRW`, `CHF`. `EURC` still uses the existing deploy-time config path and should be rechecked before Tier 0 if Avalanche EURC is used.

---

## 3. Mock testnet strategy (Arc only)

### 3.1 Mock contracts (LANDED)

`contracts/src/test-helpers/MockStablecoin.sol` — single parameterized contract using OZ ERC20 + ERC20Burnable + ERC20Permit (EIP-2612) + Ownable. Per-call faucet payout, gated by `faucetOpen`.

**Why this is allowed under "no new contracts" rule:** test helper, deployed under `test-helpers/`, never reachable from mainnet deploy script. Audit-line zero risk surface. Extends OZ audited primitives.

### 3.2 Mock deployment instances on Arc testnet

| Symbol | Name | Decimals | Mock purpose |
|---|---|---|---|
| `mAUDF` | "Mock AUDF (test)" | 6 | Stand in for Forte AUDF on Arc testnet. |
| `mJPYC` | "Mock JPYC (test)" | **18** | **Mirror mainnet 18-dec, NOT Sepolia 6-dec.** |
| `mMXNB` | "Mock MXNB (test)" | 6 | Stand in for Bitso/Juno MXNB. |
| `mKRW1` | "Mock KRW1 (test)" | 0 | Stand in for BDACS KRW1. |
| `mZCHF` | "Mock ZCHF (test)" | 18 | Stand in for Frankencoin ZCHF. |

PHPC + BRLA explicitly excluded from Phase 3.

Deploy script: `contracts/script/DeployArcTestnetMocks.s.sol`. Logs all addresses to `deployments/arc-testnet-mocks.json`.

### 3.3 Mock-to-real switching

The Hub deploy script reads stablecoin addresses from env vars per chain. Testnet env points to mock addresses; mainnet env points to real issuer addresses. Switching is a deploy-config change, no contract change:

```bash
# Arc testnet (current)
export FXT_TOKEN_AUDF=$(jq -r .mocks.mAUDF deployments/arc-testnet-mocks.json)
export FXT_TOKEN_JPYC=$(jq -r .mocks.mJPYC deployments/arc-testnet-mocks.json)
export FXT_TOKEN_MXNB=$(jq -r .mocks.mMXNB deployments/arc-testnet-mocks.json)
export FXT_TOKEN_KRW1=$(jq -r .mocks.mKRW1 deployments/arc-testnet-mocks.json)
export FXT_TOKEN_ZCHF=$(jq -r .mocks.mZCHF deployments/arc-testnet-mocks.json)

# Avalanche mainnet (production)
export FXT_TOKEN_AUDF=0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b
export FXT_TOKEN_JPYC=0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB
export FXT_TOKEN_MXNB=0xF197FFC28c23E0309B5559e7a166f2c6164C80aA
export FXT_TOKEN_KRW1=0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318
export FXT_TOKEN_ZCHF=0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553
```

### 3.4 Mock oracle handling

For testnet pairs that use mocks, we need a mock-friendly Pyth/RedStone path. Two options:

- **Option A (preferred):** still use real Pyth on Arc testnet (assuming feed exists). Mock stablecoin price tracks the real-world rate. This is most realistic.
- **Option B (fallback):** use `MockOracle.sol` (extends `IFxOracle`) that returns admin-set prices. Use only when real Pyth feed not available on Arc testnet for that FX pair.

Pre-deploy check per pair: confirm Pyth feed exists on Arc testnet and configure inverse feeds where Pyth publishes `USD/X` instead of `X/USD`. If yes → Option A. If no → log to `docs/BLOCKED_PAIRS.md` and use Option B for development only; production deploy waits for real feed.

---

## 4. Hub deployment matrix

### 4.1 Hub-chain options

| Hub chain | Status | Use case |
|---|---|---|
| **Avalanche C-Chain (mainnet)** | 🎯 Production target | 5/6 basket assets natively live. Real-asset demo. CCTP V2 domain 1. |
| **Arc Testnet** | ✅ Current development hub | Daily iteration target — all Phase 2.5 / 2.6 / 2.6R / Phase 3 work happens here. Uses mocks for non-Avalanche assets. |
| **Avalanche Fuji** | ✅ Current Tenderly-hub | Live vnet hub already wired (per `bbb0302` + `ccb1568` commits). Use for primed-vnet simulations against Avalanche-shaped state. |
| **Tenderly vnet (forked Avalanche)** | Recommended pre-mainnet | Fork live Avalanche mainnet, run the full deploy + smoke matrix before broadcast. |
| **Arc mainnet** | Future migration target | When Circle ships Arc mainnet GA, migrate the Hub via env-var swap. Code is portable. |

### 4.2 Hub contracts to deploy (no changes — same set as today)

| Contract | Purpose | Already audited? |
|---|---|---|
| `FxOracle` | Pyth + RedStone deviation-gated price reads | Internal review |
| `MorphoOracleAdapter` | Adapts IFxOracle for Morpho Blue's `IOracle` interface | Internal |
| `FxMarketRegistry` | Pool discovery + per-asset risk params | Internal |
| `FxLiquidator` | Liquidation routing | Internal |
| `FxReceipt` | LP receipt token (ERC-4626 wrapper) | Internal |
| `FxSwapHook` | Per-pair Uniswap v4 hook (one instance per pair) | Pre-mainnet audit pending |
| `FxHubMessageReceiver` | CCTP V2 hook callback on Hub side | Internal |
| `FxRouter` | Phase 2.6R signed-intent entry (deployed once, multi-pair) | Pre-mainnet audit pending |

Total: 8 core contracts + N hook instances (one per pair).

### 4.3 Deploy order (Avalanche mainnet)

1. `FxOracle` → register Pyth feed IDs + RedStone signer set per pair.
2. `MorphoOracleAdapter` → wraps FxOracle for Morpho.
3. `FxMarketRegistry` → initial per-asset risk params (conservative).
4. `FxLiquidator` + `FxReceipt` → liquidation + receipt token.
5. Per pair: deploy `FxSwapHook` (HookMiner for v4 perm bits), create 2 Morpho markets via `Morpho.createMarket()`.
6. `FxHubMessageReceiver` → registered with Hub-side CCTP V2 MessageTransmitter (Avalanche domain 1).
7. `FxRouter` → register all pair pool keys via `setPairAllowed`.
8. Transfer admin to Compound Timelock per `script/Deploy.s.sol` pattern.
9. Register all contracts with Circle SCP via `bun run sdk:circle:register`.
10. Update `packages/sdk/src/addresses/index.ts` under `ChainId.AvalancheMainnet`.

Fresh basket deploy script: `contracts/script/DeployAvalancheBasketHub.s.sol`.

```bash
export DEPLOYER_PRIVATE_KEY=...
export AVALANCHE_PYTH=...
export AVALANCHE_MORPHO_BLUE=...
export AVALANCHE_MORPHO_IRM=...
export AVALANCHE_POOL_MANAGER=...
export AVALANCHE_CCTP_MESSAGE_TRANSMITTER=...

forge script contracts/script/DeployAvalancheBasketHub.s.sol:DeployAvalancheBasketHub \
  --rpc-url $TENDERLY_AVALANCHE_VNET_RPC \
  --broadcast
```

Optional seed env vars are raw token units, e.g. `FXT_SEED_USDC_JPYC=10000000000` and `FXT_SEED_JPYC=1562500000000000000000000`.

Cold local smoke drill:

```bash
bun run contracts:smoke:basket
```

This deploys all five Phase 3 pairs, creates the two Morpho markets per pair, mines and initializes the v4 hook pool, seeds LP, verifies Morpho rehypothecation, and executes a v4 hook swap callback for USDC→JPYC/MXNB/AUDF/KRW1/ZCHF.

---

## 5. Spoke deployment matrix

Spokes are thin — each chain that holds Circle-supported USDC/EURC routes, or is a major USDC/EURC entry point, gets a CCTP `FxSpoke` deployment. Basket assets outside that CCTP scope use Hyperlane or issuer-specific routes instead.

### 5.1 Spoke priorities (chains)

Order by usefulness for the basket. Avalanche is the Hub; spokes feed USDC into it from elsewhere.

| Chain | Why | Stablecoins exposed off-chain | CCTP V2 status |
|---|---|---|---|
| **Avalanche** | Hub — not a spoke | All 6 basket assets reside here | N/A (Hub) |
| **Ethereum** | All native issuance: AUDF, JPYC, MXNB, ZCHF + USDC | AUDF, JPYC, MXNB, ZCHF native | ✅ Live (domain 0) |
| **Arbitrum** | MXNB native, ZCHF CCIP | MXNB, ZCHF | ✅ Live (domain 3) |
| **Base** | AUDF, ZCHF (CCIP), USDC depth | AUDF, ZCHF | ✅ Live (domain 6) |
| **Polygon** | JPYC, AUDF, ZCHF (CCIP) | JPYC, AUDF, ZCHF | ✅ Live (domain 7) |
| **Optimism** | ZCHF (CCIP) | ZCHF | ✅ Live (domain 2) |
| **Unichain** | USDC entry point | — | ✅ Live (domain 10) |
| **Plume** | KRW1 | KRW1 | Confirm CCTP V2 status |
| **Arc (when mainnet GA)** | USDC native | USDC | Live testnet (domain 26); mainnet TBD |
| **Solana** | If JPYC/KRW1 SPL emerge | Future | ✅ Live (Spoke-only model) |

### 5.2 What changes per spoke

Nothing in the CCTP spoke contract for basket assets outside USDC/EURC. The CCTP lane burns USDC/EURC via CCTP V2 to the Hub and receives USDC/EURC back via CCTP V2 where Circle supports the asset and route. **AUDF / JPYC / MXNB / KRW1 / ZCHF are never bridged through CCTP.** They exist on the Hub (Avalanche) or arrive through a separately approved Hyperlane/issuer route, get FX'd there, and the user receives the Circle output asset back via CCTP when available.

### 5.3 Spoke deploy commands

Per-spoke needs:
- Faucet drip for the deployer EOA (`0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`).
- Source `.env.local` with `HUB_RECEIVER` + `HUB_DOMAIN=1` (Avalanche mainnet) set.
- `forge script` with the spoke's RPC.
- Persist to `deployments/<chain>.json`.

---

## 6. Pre-mainnet checklist (extends `docs/PRE_DEPLOY_CHECKLIST.md`)

### 6.1 Hub readiness (Avalanche mainnet)

- [ ] Avalanche mainnet RPC pinned + funded deployer EOA confirmed.
- [x] Circle USDC + EURC addresses on Avalanche verified (see `docs/CIRCLE_USDC_EURC_ADDRESSES.md`).
- [ ] CCTP V2 TokenMessenger + MessageTransmitter addresses on Avalanche pinned.
- [ ] Permit2 canonical address verified (`0x000000000022D473030F116dDEE9F6B43aC78BA3`).
- [ ] Morpho Blue deployed to Avalanche (verify Morpho Labs status; self-deploy if absent).
- [x] Pyth Network feed IDs confirmed for: EUR/USD, EURC/USD, AUD/USD, USD/JPY, USD/MXN, USD/KRW, USD/CHF.
- [x] RedStone public symbols confirmed for: USDC, EUR, AUD, JPY, MXN, KRW, CHF.
- [ ] Smart-contract audit complete (CertiK or Spearbit) for FxSwapHook + FxRouter + adapter layer. Findings remediated.

### 6.2 Per-pair readiness (Tier 1 anchors — JPYC, MXNB)

- [ ] Issuer-canonical address on Avalanche confirmed (JPYC `0x431D…7BDB`, MXNB `0xF197…C80aA`).
- [ ] Issuer contacted, communication channel established for incident response.
- [x] Pyth + RedStone feeds verified for the pair; JPYC/MXNB use inverse Pyth feeds.
- [ ] Risk params set in `FxMarketRegistry`: cap $1M initial, lltv 80%, fee 5-15 bps, max oracle deviation 50 bps.
- [ ] Morpho markets created (both directions), market IDs recorded.
- [ ] FxSwapHook deployed at HookMiner-mined address, permission bits verified.
- [ ] Pool seeded with treasury LP (anti-share-inflation hygiene — `_decimalsOffset()=6` already landed per `reports/AUDIT_REPORT.md` v1.2.2).
- [ ] Tenderly vnet smoke test against forked Avalanche mainnet: deposit, swap both directions, redeem.

### 6.3 Per-pair readiness (Tier 2 — AUDF, KRW1)

- [ ] AUDF: same checklist as Tier 1 (address `0xd2a5…7456b`).
- [x] AUDF/KRW1 oracle feeds verified; KRW1 uses inverse Pyth `USD/KRW`.
- [x] KRW1: decimals probe complete (`decimals() == 0` on Avalanche mainnet, 2026-05-14); mock-vs-real switch decision logged.

### 6.4 Spoke readiness (per chain)

- [ ] CCTP V2 mainnet addresses confirmed for that chain.
- [ ] Deployer EOA funded with chain-native gas (Polygon: MATIC; Eth: ETH; etc.).
- [ ] `HUB_RECEIVER` + `HUB_DOMAIN=1` env vars updated.
- [ ] `deployments/<chain>.json` template ready.
- [ ] Faucet/funding drip path documented for ongoing ops.

### 6.5 Governance + ops (PR-6 work)

- [ ] Compound Timelock deployed on Avalanche mainnet (vendor sub-project 0.5.16 build path).
- [ ] Multisig (Safe / Circle Modular Wallet) configured with 3-of-5 ops members.
- [ ] Admin transfer atomic in `script/Deploy.s.sol` — post-condition asserts succeed.
- [ ] Pause + emergency-stop runbook in `docs/INCIDENT_RESPONSE.md` (PR-7).
- [ ] On-call rotation defined.

### 6.6 Monitoring (PR-7)

- [ ] Circle SCP event monitors set up for: `DepositStranded`, `DepositSwept`, `OracleDeviation`, `MarketRegistered`, `Entered`, `Exited`, `IntentExecuted`, `Pause`.
- [ ] Tenderly Alerts as redundant notification path.
- [ ] Pyth / RedStone feed-staleness monitor (off-chain, alerts if either feed > 5 min stale).
- [ ] Per-pair TVL + utilization dashboard published.

---

## 7. Testnet mock deploy sequence (current immediate work)

This is the immediate work. Mainnet waits on §6 checklist completion.

### 7.1 Mock token deploy (Arc testnet) — code LANDED

1. ✅ Implement `contracts/src/test-helpers/MockStablecoin.sol` (PR-1 gift).
2. ✅ Implement `contracts/script/DeployArcTestnetMocks.s.sol` (mAUDF / mJPYC / mMXNB / mKRW1 / mZCHF basket).
3. ⏳ `forge script ... --broadcast` against Arc testnet RPC (operator step).
4. ⏳ Log addresses to `deployments/arc-testnet-mocks.json`.
5. ⏳ Update `packages/sdk/src/addresses/index.ts` `ChainId.ArcTestnet` token map.

### 7.2 Hub deploy on Arc testnet (once Morpho available)

1. Resolve Morpho Blue Arc testnet (await Morpho Labs OR self-deploy via vendored singleton).
2. Run existing `DeployArcTestnet.s.sol` with env pointing to:
   - Real USDC (`0x3600…0000`)
   - Real EURC (`0x89B5…D72a`)
   - Mock JPYC / MXNB / AUDF / KRW1 / ZCHF addresses (from `deployments/arc-testnet-mocks.json`)
   - Real Pyth + RedStone (if feeds confirmed)
   - Real CCTP V2 (Domain 26)
   - Real Permit2 (canonical)
3. Per pair, run the §3.2 onboarding playbook from `SPEC_PHASE_3_MULTI_STABLECOIN.md`.
4. Smoke-test each pair end-to-end via Tenderly vnet forked from Arc testnet.
5. 14-day clean monitoring window.

### 7.3 Faucet setup

- Mock contracts have `faucet()` method open on testnet (gate via owner before mainnet rehearsal).
- Test users `cast send <mockAddr> "faucet()"` to receive 1000 units (decimal-adjusted).
- Document in `docs/TESTNET_USAGE.md` (PR-7).

---

## 8. Mainnet launch sequence (Avalanche)

Triggered when all checkboxes in §6 are green. Estimated path:

1. **Week T-2:** Final audit findings closed, address book frozen.
2. **Week T-1:** Tenderly vnet forked from Avalanche mainnet, full deploy dry-run, gas accounting confirmed.
3. **Week T:**
   - Day 0: Deploy hub contracts to Avalanche mainnet via `script/Deploy.s.sol`. Transfer admin to Timelock atomically. Verify on Snowtrace.
   - Day 0: Register with Circle SCP. Set event monitors.
   - Day 0: Deploy spoke contracts to Ethereum, Polygon, Arbitrum, Base, Optimism, Unichain in parallel.
   - Day 1: Deploy FxSwapHook for USDC↔EURC (Tier 0) + USDC↔JPYC (Tier 1 anchor #1).
   - Day 2: Deploy FxSwapHook for USDC↔MXNB (Tier 1 anchor #2).
   - Day 3-14: Closed beta — protocol team only, $25k cap per pool, watch for any oracle / Permit2 / hook anomaly.
   - Day 14+: Open public access. Cap raised to $1M per pool. Monitor.
4. **Week T+4:** First risk-param relax (if clean). Caps to $5M, lltv potentially loosened by 2-4%.
5. **Week T+8:** Wave 2 deploy (AUDF, KRW1).
6. **Week T+16:** Wave 3 deploy (ZCHF).

---

## 9. What we are NOT doing in this plan

- ❌ Bridging local stablecoins cross-chain. Local stables live on Hub. Period.
- ❌ Integrating Chainlink CCIP at the protocol level. The CCIP-bridged ZCHF on Avalanche is a Hub-resident ERC-20; we read its `balanceOf`, we don't drive its bridge.
- ❌ Deploying USYC integration. KYB-gated, Pasillo concern.
- ❌ Integrating QCAD legacy. Wait for post-relaunch contract.
- ❌ Integrating ZARU. Solana-only, out of scope.
- ❌ Self-deploying any stablecoin. We use issuer-canonical addresses on mainnet, or mocks on Arc testnet.
- ❌ Hardcoding mainnet addresses. All from env vars resolved at deploy time.
- ❌ Listing PHPC or BRLA in Phase 3 (deliberate basket trim — see `docs/BLOCKED_PAIRS.md` §Excluded).

---

## 10. Open questions for project owner

1. **EURC on Avalanche mainnet address.** Pinned from Circle's canonical page: `0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD`.
2. **Morpho on Avalanche.** Confirm Morpho Labs deployment status; self-deploy fallback path if absent.
3. **Arc/Tenderly broadcast prep.** Oracle feeds and KRW1 decimals are confirmed; next code-facing blocker is a deployment script that creates all basket Morpho markets/hooks and runs the Tenderly smoke matrix.
4. **Per-pair launch cap.** Default $1M conservative — confirm or adjust based on Pasillo's institutional pipeline.
5. **Audit firm.** CertiK vs Spearbit vs Sherlock contest. Recommend Spearbit + a Sherlock contest before mainnet.

— end of deploy plan —
