# fx-Telaraña — Engineering Spec (v0.2)

**Status**: Post-`/plan-eng-review` decisions locked
**Date**: 2026-05-13
**Owner**: criptopoeta
**Supersedes**: v0.1 (2026-05-13)

**Locked in v0.2**:
- D1 Lending substrate: **Morpho Blue** (isolated markets per pair)
- D2 KYC model: **Pasillo proxies Bufi-KYC → Hinkal AccessToken issuance** (partner-gated)
- D3 Oracle: **Pyth primary + RedStone secondary**, both permissionless, both pull-mode
- D4 Privacy detail: **Fresh SCA per deposit** (unlinkability); **Phase 0 = public-only first**

---

## 1. Product thesis

Arc concentrates stablecoin liquidity globally. Circle's StableFX is the institutional, KYB-gated, RFQ leg. **fx-Telaraña is the DeFi-native parallel:** a permissionless cross-currency money market + FX swap on Arc, hub-and-spoke across all CCTP V2 chains, with optional wallet-level confidentiality for Bufi-verified users.

One sentence: **Aave-style money market for USDC + EURC where the lending pool also backs a Uniswap v4 FX swap hook, with one spoke route that auto-flips to confidential mode for KYC'd Bufi wallets.**

---

## 2. Tiering (wallet-level, not contract-level)

Two operating modes, **one set of contracts**. The mode is determined at the client layer based on wallet state.

| Mode | Trigger | Spoke path | Hub interaction |
|---|---|---|---|
| **Public** | Default — any wallet, no Hinkal AccessToken | Plain `IFxSpoke` calls; CCTP V2 `depositForBurn` for USDC | Direct call to Morpho Blue market on `FxHub` |
| **Confidential** | Wallet holds a Hinkal AccessToken (auto-routed) | Hinkal Emporium wraps the same `IFxSpoke` call via `actionPrivateWallet` | Same call, wrapped; on Arc mainnet GA, Arc native confidentiality wraps Hub state automatically |

**Detection happens at the wallet level.** Client-side: `hinkalSdk.hasAccessToken(wallet, chainId)` → if true, auto-route through Emporium. No user-facing toggle.

**KYC pipeline** (D2): pasillo proxies Bufi KYC/KYB → Hinkal AccessToken issuance (via partner API agreement with Hinkal). User completes KYC once inside Bufi; pasillo provisions Hinkal AccessTokens for all linked wallets under the Bufi workspace, on demand. Subscription gate (`@bu/plan-limits`) controls eligibility for AccessToken provisioning; revocation triggers token-rotation request to Hinkal.

No Hinkal AccessToken → public path. AccessToken present → confidential path is automatic. Bufi subscription tier is what *grants* the AccessToken, not what gates routing at tx time.

---

## 3. Contracts (on Arc)

All contracts privacy-agnostic. Privacy is at the call boundary.

### 3.1 Lending substrate — Morpho Blue (D1)

**Use Morpho Blue as the lending primitive.** Two isolated markets at MVP:

| Market | Loan asset | Collateral asset | Oracle | IRM |
|---|---|---|---|---|
| M1 | EURC | USDC | `FxOracle` (Pyth+RedStone EUR/USD) | Adaptive Curve IRM (Morpho default) |
| M2 | USDC | EURC | `FxOracle` (inverted) | Adaptive Curve IRM |

Per Morpho Blue: each market is an immutable singleton parameterized by `(loanToken, collateralToken, oracle, irm, lltv)`. We deploy two markets through `MorphoBlue.createMarket(...)` on Arc. No fork, no custom code in the lending substrate.

**FX-aware layer** (our code, sits *above* Morpho Blue):
- `FxMarketRegistry.sol` — maps pair → Morpho market id; exposes one API (`supply/withdraw/borrow/repay`) that routes to the correct market.
- `FxLiquidator.sol` — keeper interface; reads `FxOracle`, computes ratio, calls Morpho's `liquidate(...)`.
- `FxReceipt.sol` (optional MVP) — single ERC-4626 wrapper per asset that aggregates lender positions across markets (improves UX; lenders see one balance per asset).

**Receipt tokens**: Morpho Blue issues no aTokens — positions are tracked in storage. The `FxReceipt` ERC-4626 wrapper exists only for UX. Confidential mode wraps the ERC-4626 share token in Hinkal (cleaner than wrapping raw Morpho positions).

**Why Morpho not Aave fork / not Spooky refactor** (recorded for posterity):
- ~1k LOC core, audited, formally verified parts
- Isolated markets fit FX-pair risk (USDC depeg in M1 doesn't cascade into M2)
- Cross-currency collateral is achieved by *running two markets*, not by retrofitting cross-collateral into a single pool
- Innovation tokens saved here go to the v4 hook + Hinkal wrappers
- Adaptive Curve IRM eliminates piecewise IRM tuning effort

**Trade-off accepted**: a single user holding USDC supplied + EURC borrowed in M1 is the *same position* as USDC borrowed + EURC supplied in M2's mirror — Aave would unify these. UX layer in `apps/app` shows the user one consolidated view; on-chain they're separate.

### 3.2 `FxSwapHook.sol`
Uniswap v4 hook. Oracle-anchored PMM-style curve.

- One pool per pair (USDC/EURC at MVP).
- `beforeSwap`: read oracle mid from `IFxOracle`, compute quote with deterministic spread + size-adjusted impact (PMM curve params: `k`, `i`, `B0`, `Q0` à la DODO Classical PMM).
- `beforeAddLiquidity` / `beforeRemoveLiquidity`: route LP funds into the Morpho Blue markets via `FxMarketRegistry` (rehypothecation; LPs earn supply APY on top of swap fees — Bunni pattern).
- **JIT-borrow** for swap depth beyond hook-held liquidity: hook borrows the output leg from the appropriate Morpho market (M1 for EURC-out, M2 for USDC-out) within the same tx (EulerSwap pattern). Position closed at next LP rebalance.
- `afterSwap`: write swap fees back as additional Morpho supply on the deficit side (boosts LP yield).
- Slippage protection: hook reverts if oracle staleness > `MAX_ORACLE_AGE` (60s) or oracle deviation > `MAX_ORACLE_DEVIATION_BPS` (50 bps).

**Pre-implementation gate**: verify Uniswap v4 `PoolManager` deployment on Arc testnet. If absent, decide between (a) waiting for official deploy, (b) self-deploying v4 core under DAO-style timelocked ownership. Phase 2 cost +2 weeks if (b).

### 3.3 `FxOracle.sol` — `IFxOracle` interface (D3)
Permissionless, decentralised, pull-based. **No market-hours logic. 24/7.**

All Hub contracts (Pool registry, hook, liquidator, frontend SDK) read through the `IFxOracle` interface — never call Pyth/RedStone SDK directly. Single read path enables fallback rotation and Arc-native confidentiality drop-in.

```solidity
interface IFxOracle {
    function getMid(address base, address quote) external view returns (uint256 midE18, uint256 publishedAt);
    function getMidWithUpdate(address base, address quote, bytes[] calldata pythUpdate, bytes[] calldata redstoneUpdate)
        external payable returns (uint256 midE18, uint256 publishedAt);
}
```

- **Primary**: Pyth pull oracle (`updatePriceFeeds` + `getPriceNoOlderThan`). Confirmed on Arc testnet. Covers EUR/USD, USDC/USD, EURC/USD at sub-second cadence. Use Pyth EMA + confidence band for sanity check.
- **Secondary**: RedStone pull oracle (Arc-supported, decentralized, permissionless). Same pair coverage. Pulled in the same tx as Pyth.
- **Both are permissionless**: any caller can push fresh prices for any feed. No allowlist.
- Deviation check: if `|pyth - redstone| / pyth > MAX_ORACLE_DEVIATION_BPS` (default 50 bps), `getMid` reverts with `OracleDeviation()`. Block borrows/swaps until reconvergence.
- Pyth confidence band check: revert if `pyth.confidence > MAX_CONFIDENCE_BPS * pyth.price` (default 30 bps).
- Staleness: revert if `publishedAt < block.timestamp - MAX_ORACLE_AGE` (60s default).
- No owner-controlled writes. Feed registry (which Pyth feed id / RedStone data feed maps to which token pair) is admin-set behind a 48h timelock.

USDC↔EURC are both stablecoins floating vs. USD/EUR. The "FX risk" is the EUR/USD rate plus each issuer's peg deviation. Both are quoted onchain 24/7 — no forex-hours gate, no weekend pause.

### 3.4 `FxLiquidator.sol`
Permissionless keeper interface to Morpho Blue `liquidate(...)`. Bots pull oracle (Pyth + RedStone) in the same tx as the liquidate call (one tx, atomic). On-Hub positions are public even for confidential users — mitigation is fresh SCA per deposit (see § 7).

### 3.5 `FxSpoke.sol` (per spoke chain)
Thin contract on Ethereum / Base / Arbitrum / Optimism / Polygon / Avalanche / Solana.

```solidity
interface IFxSpoke {
    function enterHub(
        uint256 amount,
        address beneficiary,   // who owns the resulting Hub position
        bytes calldata hubCalldata
    ) external payable returns (bytes32 messageNonce);

    function exitHub(
        bytes calldata cctpMessage,
        bytes calldata attestation,
        address recipient
    ) external;
}
```

- `enterHub` semantics:
  - Public mode: caller sets `beneficiary = msg.sender` (or another address).
  - Confidential mode: Hinkal Emporium relay is `msg.sender`, but `beneficiary` is the user's fresh per-deposit SCA on Arc Hub. The adapter passes this in.
  - For USDC: calls CCTP V2 `TokenMessenger.depositForBurn` with `destinationCaller = FxHubMessageReceiver`, `hookData = abi.encode(beneficiary, hubCalldata)`.
  - For EURC: bridge-then-swap interim until EURC CCTP GA.
- `exitHub`: receives CCTP V2 burn from Arc, forwards USDC to `recipient`.

**Stranded-deposit recovery** (critical gap from review): CCTP V2 burn-mint is atomic, but the destination hook can revert independently — USDC mints on Arc with no Hub position. Add:

```solidity
function sweepStrandedDeposit(bytes32 messageNonce, address beneficiary) external;
```

Anyone can call after `STRANDED_DEPOSIT_GRACE` (24h). Reads the recorded `(messageNonce, beneficiary, amount)` from `FxHubMessageReceiver` storage, transfers minted USDC to `beneficiary`. Replay-protected by `messageNonce`. This is the only escape path if the hook reverts.

Identical contract for public and confidential modes. The Hinkal Emporium adapter wraps the *call* to `enterHub` from a shielded balance and sets `beneficiary` to a fresh-per-deposit SCA owned by the user.

---

## 4. Off-chain — `apps/pasillo` Worker

New routes added to existing Hono OpenAPI surface:

```
POST /fx/quote                 // input: from/to pair, amount, slippage; output: quote + route plan
POST /fx/swap/prepare          // returns calldata or Hinkal action plan
POST /fx/lend/prepare          // supply / withdraw / borrow / repay (Morpho-Blue-routed)
POST /fx/liquidation/calldata  // for keeper bots
POST /fx/hinkal/accesstoken    // Bufi-KYC → Hinkal AccessToken provisioning (D2 partner API)
GET  /fx/pools                 // market stats: total supply/borrow, utilization, APY per Morpho market
GET  /fx/positions/:wallet     // user positions (public mode) — confidential users read via Hinkal balance API client-side
GET  /fx/eligibility/:wallet   // returns { public: true, confidential: bool, reason: EligibilityReason }
```

**Eligibility enum** (machine-readable, exported from `@bu/fx-engine`):

```typescript
export enum EligibilityReason {
  OK = "OK",
  NO_BUFI_WORKSPACE = "NO_BUFI_WORKSPACE",
  NO_SUBSCRIPTION = "NO_SUBSCRIPTION",
  NO_HINKAL_ACCESS_TOKEN = "NO_HINKAL_ACCESS_TOKEN",
  KYC_PENDING = "KYC_PENDING",
  COMPLIANCE_BLOCK = "COMPLIANCE_BLOCK",
}
```

Eligibility check pipeline (cached 60s at edge, invalidated on subscription/compliance events):
1. `wallet → bufiWorkspace` via `@bu/customers`
2. `workspace.subscription` via `@bu/plan-limits` (must include Ghost mode tier)
3. `compliance.screen(wallet)` via `@bu/compliance` (fail-closed)
4. `hinkal.hasAccessToken(wallet, chainId)` via Hinkal SDK
   - If steps 1–3 pass and step 4 fails: trigger `POST /fx/hinkal/accesstoken` provisioning (asynchronous, returns `KYC_PENDING` until ready)

Reuses: `@bu/transfer-core`, `@bu/private-transfer-core`, `@bu/circle-kit`, `@bu/compliance`, `@bu/plan-limits`, `@bu/blockchain-data`, `@bu/customers`.

New: `@bu/fx-engine` package (contract SDK + types + ABIs + addresses + Morpho Blue market id registry + `EligibilityReason` enum).

---

## 5. Frontend — `apps/app` and/or `defi-web-app` adaptation

- **Connect**: Dynamic Labs + Bufi workspace SSO. Dynamic native Circle wallet integration for SCAs.
- **Ghost mode toggle**: appears only when `/fx/eligibility` returns `confidential: true`. Toggle drives whether tx calldata is wrapped in Hinkal Emporium.
- **Pool view**: TVL, APY, utilization per asset, plus swap-hook stats.
- **Position view**: borrow / supply positions, health factor, liquidation price.
- **Swap view**: standard pair UI; route shows whether the v4 hook is JIT-borrowing or fully covered by hook liquidity.

Reuse from `BuFi007/defi-web-app`: money-market components, swap, chain-select, token-selector, currency, claim-og, LiFi widget (optional bridge fallback), Peanut SDK (optional).

---

## 6. Cross-chain flows

### 6.1 Public — supply USDC from Base
1. User on Base → `FxSpoke.enterHub(amount, supplyCalldata)`
2. CCTP V2 `depositForBurn` → Arc Hub message receiver
3. Hub receiver decodes hook → `FxLendingPool.supply(USDC, amount, user)`
4. User holds `aFxUSDC` on Arc

### 6.2 Confidential — same flow, KYC'd Bufi user on Base
1. User in `defi-web-app` with Ghost mode on, connected through Bufi workspace
2. Same `FxSpoke.enterHub(amount, supplyCalldata)` call
3. Client wraps the spoke call: `hinkal.actionPrivateWallet(chainId, [USDC], [-amount], onChainCreation, [{ contract: FxSpoke, func: 'enterHub', args: [amount, calldata] }], emporiumTokenChanges)`
4. Emporium unshields amount → calls `enterHub` → message goes to Arc identically
5. Position on Arc Hub is held under user's SCA (not their Hinkal wallet) — origin private, position public
6. On Arc mainnet GA, Arc native opt-in confidentiality wraps the Hub-side balance reads

### 6.3 Swap USDC → EURC on Arc Hub
1. Universal Router → `PoolManager.swap` → `FxSwapHook.beforeSwap`
2. Hook reads oracle mid, quotes
3. If hook-held EURC sufficient → settle from hook reserves
4. Else → hook calls `FxLendingPool.borrow(EURC, delta, ...)` with input USDC as collateral; settle; close JIT loan at next rebalance
5. Confidential variant: same call wrapped in `actionPrivateWallet`

### 6.4 Borrow EURC against USDC collateral
1. User has `aFxUSDC` on Hub (from any source — direct supply or via spoke)
2. `FxLendingPool.borrow(EURC, amount, variableRateMode, user)`
3. Health factor computed via `FxOracle.getMid(USDC, USD)` and `FxOracle.getMid(EURC, USD)`
4. Optional: route borrowed EURC back to spoke chain via `FxSpoke.exitHub`

### 6.5 Liquidation
Standard. Public mode. Confidential users' positions on Hub are public (origin only is private).

---

## 7. Privacy detail

| Layer | Public mode | Confidential mode |
|---|---|---|
| Wallet → Spoke | Plain calldata, `beneficiary = msg.sender` | `hinkal.actionPrivateWallet` wraps the same calldata; `beneficiary = fresh per-deposit SCA` |
| Spoke → CCTP V2 | Public deposit-for-burn | Same; sender = Emporium relay |
| CCTP V2 → Hub | Public message | Same |
| Hub-side position owner | User's primary SCA | **Fresh SCA per deposit** (D4) via Circle MSCA factory — positions sharded |
| Hub state | Public | Public today; Arc native opt-in privacy at Arc mainnet GA encrypts amounts |
| Position health | Public per-SCA | Public per-fresh-SCA, but pattern analysis is meaningfully harder |
| Cross-user transfers of receipt tokens | Public ERC-20 / ERC-4626 | `hinkal.transfer` between Hinkal recipientInfos |
| User-facing aggregate view | One position per pair | `@bu/fx-engine` SDK aggregates all owned fresh-SCAs into one user view client-side |

**Fresh-SCA-per-deposit (D4 lock)**: every confidential deposit instantiates a new Circle MSCA on Arc via the factory. Cost ~$0.02 per SCA. The Bufi workspace owns the SCA via passkey/WebAuthn — the user accesses all of them through the workspace login. Liquidator sees N small positions instead of one large one; pattern analysis is significantly harder. v2 (custom Hinkal circuits) collapses this entirely to shielded positions.

Confidential mode requires:
- Bufi workspace (any wallet linked to it)
- Active `@bu/plan-limits` subscription that includes Ghost mode
- Compliance clear via `@bu/compliance`
- Hinkal AccessToken on the target chain — **provisioned by pasillo via the partner API agreement (D2)**, not by the user going through aiPrise separately
- Per-deposit SCA factory access on Arc

---

## 8. Stack + dependencies

| Layer | Choice |
|---|---|
| Contracts | Solidity, Foundry |
| Lending base | **Morpho Blue** (D1) — two isolated markets (USDC-collat/EURC-loan, EURC-collat/USDC-loan); FX-aware registry + liquidator + ERC-4626 receipt wrapper sit above |
| v4 | Uniswap v4 core + hooks framework (verify Arc deployment first; self-deploy if needed) |
| Bridge | CCTP V2 (Circle) — Wormhole NTT deferred to phase 4 for non-Circle assets |
| Oracle | **Pyth primary + RedStone secondary** (D3) — both permissionless pull oracles, deviation gate + Pyth confidence band |
| KYC plumbing | Pasillo proxies Bufi-KYC → Hinkal AccessToken issuance (D2 partner API) |
| SCA factory | Circle MSCA factory on Arc — fresh SCA per confidential deposit (D4) |
| Privacy SDK | `@bu/private-transfer-core` + `@hinkal/common@0.2.29` |
| Identity | `@bu/compliance` + `BUAttestation` contract |
| Subscription gate | `@bu/plan-limits` |
| Wallet | Dynamic Labs + Circle MSCA + Bufi workspace SSO |
| Server | `apps/pasillo` Cloudflare Worker (Hono + Zod OpenAPI) |
| Frontend | Adapted `apps/app` and/or `defi-web-app` (Next.js) |

---

## 9. Repo layout

Monorepo extension under `BuFi007/fx-Telaraña` (or inside `desk-v1` monorepo as `packages/fx-engine` + `apps/fx-hub`):

```
contracts/                # Foundry
  src/
    hub/
      FxMarketRegistry.sol     # maps (loan, collat) → Morpho market id
      FxReceipt.sol            # ERC-4626 wrapper per asset (UX aggregate)
      FxSwapHook.sol           # Uniswap v4 hook, oracle-anchored PMM + JIT
      FxOracle.sol             # IFxOracle: Pyth + RedStone
      FxLiquidator.sol         # keeper interface to Morpho liquidate()
      FxHubMessageReceiver.sol # CCTP V2 hook decoder + sweep storage
    spoke/
      FxSpoke.sol              # enterHub(amount, beneficiary, hubCalldata) + sweepStrandedDeposit
    interfaces/
      IFxOracle.sol
      IFxSpoke.sol
      IFxMarketRegistry.sol
  script/
    DeployMorphoMarkets.s.sol  # createMarket for M1, M2
  test/

packages/fx-engine/        # TS SDK
  src/
    abis/
    addresses/
    morpho-market-ids.ts       # well-known Morpho market id registry per chain
    eligibility.ts             # EligibilityReason enum + types
    quote.ts
    plan.ts                    # public vs hinkal-wrapped calldata routing (driven by Hinkal AccessToken presence)
    types.ts

apps/pasillo/              # extended (existing Hono worker)
  src/routes/fx/
    quote.ts
    swap-prepare.ts
    lend-prepare.ts
    liquidation-calldata.ts
    pools.ts
    positions.ts
    eligibility.ts
    hinkal-accesstoken.ts      # Bufi-KYC → Hinkal AccessToken provisioning

apps/app/                  # existing — money-market + swap routes added (Ghost mode auto-routed, no user toggle)
```

---

## 10. Phasing

**Phase 0 — now → Arc testnet ship, PUBLIC ONLY (D4)** (~6 weeks)
- Hub: deploy Morpho Blue markets (M1, M2) on Arc; build `FxMarketRegistry`, `FxOracle` (Pyth+RedStone), `FxLiquidator`, `FxReceipt`, `FxHubMessageReceiver`
- Spoke contract for Ethereum + Base (CCTP V2) with explicit `beneficiary` arg + `sweepStrandedDeposit`
- `@bu/fx-engine` SDK (public-mode plan paths)
- `apps/pasillo` routes (no Hinkal accesstoken route yet)
- Frontend adaptation (public mode only, no Ghost mode UI)
- Deploy: Arc testnet + 2 spokes, end-to-end verified

**Phase 1 — confidential mode** (~4 weeks, depends on Hinkal partner agreement)
- Hinkal partner deal: Bufi KYC ↔ Hinkal AccessToken issuance (D2 prerequisite — block until signed)
- 5 wrappers added to `@bu/private-transfer-core`: `shieldedSupplyCollateral`, `shieldedBorrow`, `shieldedRepay`, `shieldedFxSwap`, `shieldedCrossChainEnter` — all use `beneficiary = fresh-SCA-from-factory` (D4)
- Circle MSCA factory integration for per-deposit fresh SCAs
- Ghost mode auto-routing (no toggle) — `hasAccessToken` detection
- `/fx/eligibility` + `/fx/hinkal/accesstoken` routes in pasillo
- Frontend aggregated view of multi-SCA positions

**Phase 2 — v4 hook live** (~4 weeks)
- `FxSwapHook` on Uniswap v4 testnet, then Arc
- Hook ↔ pool integration tests
- PMM curve parameter tuning

**Phase 3 — Arc mainnet GA + Arc native privacy** (when Circle ships)
- Migrate Hub contracts to wire Arc native confidentiality precompile when published
- Audit
- Mainnet deploy

**Phase 4 — post-MVP**
- Partner stables (BRLA, MXNB, JPYC) — non-CCTP entry
- Wormhole NTT for non-Circle assets
- Bufi invoice factoring credit-delegation layer
- Custom Hinkal circuits for shielded-position health-factor proofs (Tier 3 v2)

---

## 11. Open risks

1. **Arc native confidentiality spec gap.** Smart-contract composability over Arc's confidential state is not yet specified by Circle. Mitigation: all price/balance reads route through `IFxOracle` and Morpho Blue (already encapsulated). Arc precompile drops in cleanly when published.
2. **EURC CCTP GA timing.** EURC cross-chain announced, not GA. Mitigation: spoke supports CCTP-USDC path + canonical-bridge-then-swap for EURC interim.
3. **Hinkal closed-source circuits.** No way to extend their proof system for shielded positions without cooperation. Mitigation: v1 ships with public positions (mitigated by fresh-SCA-per-deposit, D4); v2 escalates to Hinkal team.
4. **Hinkal partner agreement is a blocker for Phase 1 (D2).** Pasillo→Hinkal AccessToken issuance requires a partner API and a deal where Bufi KYC substitutes for aiPrise. If Hinkal won't agree, Phase 1 falls back to double-KYC UX (D2 option B). Mitigation: pursue partnership now, design SDK to support either path.
5. **v4 hook gas on Arc.** PoolManager + hook + JIT borrow is heavy. Mitigation: Arc fees USDC-denominated; gate Phase 2 ship on <500K gas per swap.
6. **v4 PoolManager Arc deployment unverified.** If absent on Arc, Phase 2 +2 weeks to self-deploy v4 core under timelocked governance.
7. **Oracle deviation under pegs.** When USDC or EURC depeg, Pyth and RedStone may temporarily diverge >50 bps. Mitigation: deviation gate trips, swap pauses; Morpho liquidation continues with whichever feed is within Pyth confidence band.
8. **MEV on hook swaps.** Oracle-anchored PMM is sandwich-able if oracle update is mempool-visible. Mitigation: Arc sub-second finality + Pyth pull semantics (price embedded in same tx) minimize the window.
9. **CCTP-V2 hook revert strands USDC on Hub.** Mitigation: `sweepStrandedDeposit(messageNonce, beneficiary)` after 24h grace (in `FxSpoke` / `FxHubMessageReceiver`).
10. **Pattern analysis on confidential positions.** Mitigation: fresh SCA per deposit (D4). v2: custom Hinkal circuits for shielded positions.
11. **Hinkal aiPrise downtime.** Even with partner provisioning, Hinkal's upstream KYC may go down. Mitigation: queued provisioning + UI message; user can fall back to public mode for time-sensitive actions.

---

## 12. Decisions still open

1. **Brand name.** Working title `fx-Telaraña` / `Bufi FX Engine`. Need final.
2. **Repo home.** Standalone `BuFi007/fx-Telaraña` org repo *or* live inside `desk-v1` monorepo as `packages/fx-engine` + `apps/fx-hub` (closer to pasillo + private-transfer-core).
3. **Governance / token.** Default: governance-minimized v1, no token. Reopen post-mainnet.
4. **Initial spoke set.** Phase 0: Ethereum + Base. Phase 1+: Arbitrum, Optimism, Polygon, Avalanche, Solana.
5. **Uniswap v4 PoolManager on Arc** — verify before Phase 2.
6. **Morpho Blue deployment on Arc** — verify before Phase 0 implementation. If not deployed, options: (a) wait, (b) deploy Morpho Blue ourselves (it's permissionless and immutable — anyone can deploy a Morpho Blue singleton), (c) deploy our own minimal singleton if Morpho Labs hasn't shipped to Arc.

## 13. Decisions locked in v0.2 (this revision)

| ID | Decision | Value |
|---|---|---|
| D1 | Lending substrate | Morpho Blue (two isolated markets) |
| D2 | KYC model | Pasillo proxies Bufi-KYC → Hinkal AccessToken issuance via partner API |
| D3 | Oracle | Pyth primary + RedStone secondary (both permissionless, both pull) |
| D4 | Confidential position unlinkability + phasing | Fresh SCA per deposit; Phase 0 ships public-only first |

## 14a. Arc testnet known addresses (verified 2026-05-13)

```
Chain id:                        5042002 (Arc testnet)
RPC:                             https://rpc.testnet.arc.network
CCTP domain:                     26
Native gas token:                USDC (6 decimals)

# Tokens
USDC:                            0x3600000000000000000000000000000000000000
EURC:                            0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a

# CCTP V2 (verified Arc-side)
TokenMessengerV2:                0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA
MessageTransmitterV2:            0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275
TokenMinterV2:                   0xb43db544E2c27092c107639Ad201b3dEfAbcF192
MessageV2:                       0xbaC0179bB358A8936169a63408C8481D582390C4

# Oracles
Pyth Hub:                        0x2880aB155794e7179c9eE2e38200202908C17B43
  EUR/USD feed:                  0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b
  USDC/USD feed:                 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a
  EURC/USD feed:                 0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c
RedStone:                        Pull-mode is chain-agnostic — no Arc deployment dependency (signed price payload bundled with user tx via RedstoneConsumerBase library)

# Common
Permit2:                         0x000000000022D473030F116dDEE9F6B43aC78BA3
Multicall3:                      0xcA11bde05977b3631167028862bE2a173976CA11
CREATE2 Factory:                 0x4e59b44847b379578588920cA78FbF26c0B4956C

# Reference (Circle's institutional FX, we're the DeFi parallel)
StableFX FxEscrow:               0x867650F5eAe8df91445971f14d89fd84F0C9a9f8

# External partners on Arc (no addresses published yet)
Morpho Blue:                     official Arc testnet partner; address TBD (coordinate w/ Morpho or self-deploy — Morpho Blue is immutable and permissionless)
Uniswap v4 PoolManager:          Uniswap Labs is an Arc partner; v4 address TBD
Chainlink Data Feeds:            brand partnership confirmed; price feeds for EUR/USD on Arc not yet live (RedStone pull-mode used as secondary instead per D3)
Hinkal Protocol:                 Arc testnet support confirmed in @bu/private-transfer-core (HINKAL_PHASE1_EVM_CHAIN_IDS)
```

## 14. Implementation guardrails added in v0.2

- `IFxOracle` is the single read path for ALL contracts. No direct Pyth/RedStone SDK calls outside `FxOracle.sol`.
- `IFxSpoke.enterHub(amount, beneficiary, hubCalldata)` — explicit beneficiary, never `msg.sender`-derived for confidential mode.
- `sweepStrandedDeposit(messageNonce, beneficiary)` after 24h — mandatory recovery path for CCTP hook reverts.
- `EligibilityReason` enum exported from `@bu/fx-engine` — backend gates, frontend renders.
- ASCII data-flow diagrams in each contract file (deposit, swap, borrow, liquidation) before implementation begins.
