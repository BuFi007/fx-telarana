# SPEC — Phase 3: Multi-stablecoin EM-focused FX rail

**Status:** Implementation-ready architecture spec. Composition-only — no bespoke core contracts beyond what already exists.
**Author:** Claude, fx-Telaraña architecture, 2026-05-14.
**Scope:** Onboard StableFX-aligned stablecoins at the *decentralized* level. **Permissionless public rail only.** No KYB, no USYC, no institutional tier in this protocol. EM (emerging-market) pairs are the wedge.
**Branch:** `tcxcx/fx-onchain-hub-arc`.
**Constitutional rule:** **We do not write new core financial logic. We compose audited OpenZeppelin + Morpho + Uniswap v4 + Permit2 + CCTP V2 primitives.** Every new contract is a thin adapter or wrapper. If something else seems necessary, stop and re-architect.

**Companion specs:**
- `docs/SPEC_FX_ROUTER_AND_PASILLO_QUOTE_API.md` (Phase 2.6R) — signed-intent EIP-712 + Permit2 RFQ entry point. Built in parallel; this spec assumes it exists.
- `.context/PASILLO_HANDOFF_USYC_KYB_INSTITUTIONAL.md` — institutional/USYC/KYB content punted to Pasillo (separate repo, separate company). Not built in this protocol.

---

## 0. Goals & non-goals

### Goals
1. **Multi-stablecoin coverage for EM pairs first.** USDC↔BRZ, USDC↔MXNB, USDC↔XSGD before more USDC↔EURC depth. EM borrow demand is where real Morpho APY lives.
2. **One playbook per asset.** Adding stablecoin N+1 is a deterministic checklist (§3), not a new design.
3. **Permissionless throughout.** Anyone deposits. Anyone swaps. No KYB at the protocol layer. Any integrator (Pasillo, third-party aggregators, Hashflow-style RFQ apps) can route through `FxRouter`.
4. **Composition only.** Audit-surface = sum of contracts on the §2 whitelist. Nothing else touches balances.
5. **EM wedge narrative.** Position the protocol as "the on-chain home for EM-stablecoin borrow markets and EM FX," not "yet another USDC/EURC pool."

### Non-goals (defer or punt)
- **USYC integration.** Moved to Pasillo. KYB-gated yield substrate is not a protocol responsibility.
- **KYB token / permission registry.** Moved to Pasillo. Protocol pools accept any address.
- **Permissionless RWA yield substrate** (sUSDS, USDM, etc.). Track in §9 watchlist; do not build now.
- **Two-tier rail.** There is one rail. Permissionless.
- **Sera-style orderbook clone.** Out of scope (settled in prior analysis).
- **Cross-chain SOR.** Compose at the Pasillo / integrator layer, not in this protocol.

---

## 1. Architectural principle — composition only

The protocol's risk surface = sum of all contracts we hold balances in. Three rules enforce minimal risk surface:

### 1.1 Audited contracts only (whitelist in §2)
Every contract that touches our balances must be on §2. Additions require (a) public audit ≤12 months old, (b) ≥6 months in production with ≥$100M TVL, OR (c) explicit governance vote with risk acceptance.

### 1.2 We do not write financial logic
We write:
- **Adapters** (IFxOracle, IFxMarketRegistry — internal-interface adapters over Pyth/RedStone/Morpho).
- **Composition wrappers** (FxSwapHook — Uniswap v4 hook over Morpho; FxRouter — Permit2 + EIP-712 over hook).
- **Deploy + governance scripts.**
- **View-only adapters** for off-chain consumers.

We do not write: token contracts, lending pools, AMM math primitives, signature verification, cross-chain messaging, oracle aggregators, vault primitives.

### 1.3 OpenZeppelin patterns are the default
Where we need an ERC-20 share, ERC-1155 marker, role-based access, pause control, reentrancy guard, or signature checker — use OZ's audited implementations. Custom overrides only when documented and reviewed.

---

## 2. External audited dependencies — the whitelist

Every contract our balances flow through. **No additions without governance vote.**

### 2.1 Stablecoin issuers (asset layer) — confirmed mainnet basket

Sourced from `.context/attachments/pasted_text_2026-05-14_18-33-11.txt` (Tomás's mainnet stablecoin mapping for Forex Telaraña spokes, dated 2026-05-14). All addresses below are mainnet unless flagged. **Status legend: ● live ◐ pending issuer reply △ caveat ✕ no public deployment.**

| Asset | Issuer | Decimals | Status / canonical address | Chains live | Notes |
|---|---|---|---|---|---|
| **USDC** | Circle | 6 (ERC-20) / 18 (Arc native gas) | ● Native on Arc, all CCTP V2 chains | All | Issuer freeze-capable. Decimal mismatch on Arc — see §2.1.1. |
| **EURC** | Circle | 6 | ● `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` on Arc testnet | Arc, Base | Issuer freeze-capable. |
| **AUDF** | Forte (Australia) | 6 | ● `0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b` (same on all EVMs) | Ethereum, Polygon, Avalanche, Base, Redbelly | Testnet: awaiting reply from Forte. 6-dec alignment with USDC. |
| **BRLA** | Avenia (Brazil) | 18 | ● `0xe6a537a407488807f0bbeb0038b79004f19dddfb` on Polygon | Polygon only | Ethereum/Base/Celo/Moonbeam/Gnosis pending issuer reply. **Anchor spoke #1 for BRL pair.** 18-dec — extra care in math. |
| **JPYC** | JPYC Inc (Japan) | 18 (mainnet) / 6 (Sepolia, unofficial) | ● `0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB` | Ethereum, Polygon, Avalanche | △ Sepolia uses 6 dec — mock testnet must use **18 dec** to mirror prod. **Anchor spoke #2 for JPY pair.** |
| **KRW1** | BDACS (South Korea) | TBD (confirm) | ● `0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318` (Avalanche), `0x8304d1b1d04c968270ae66a0c7758f7471b8ec3f` (Plume) | Avalanche, Plume | Polygon/Eth/BNB/Aptos/Arc pending. Confirm decimals before integrating. |
| **MXNB** | Bitso / Juno (Mexico) | 6 | ● `0xF197FFC28c23E0309B5559e7a166f2c6164C80aA` (same on all EVMs) | Arbitrum, Ethereum, Avalanche | Testnet pending Juno reply. 6-dec alignment with USDC. **Wave 2 priority.** |
| **PHPC** | Coins.PH (Philippines) | 6 | ● `0x87a25dc121Db52369F4a9971F664Ae5e372CF69A` on Polygon | Polygon | Ronin pending. Arc testnet rumored — confirm before relying on it. |
| **ZCHF** | Frankencoin DAO (Switzerland) | 18 | ● `0xB58E61C3098d85632Df34EecfB899A1Ed80921cB` (Ethereum native); `0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553` (CCIP-bridged on Base/Arb/OP/Polygon/Avax/Gnosis/Sonic) | 8 chains | **△ Uses Chainlink CCIP for bridging, NOT CCTP V2.** Spoke integration must handle CCIP message attestation, not CCTP. See §5.1 for special handling. |
| **QCAD** | Stablecorp (Canada) | 2 (legacy, deprecated) | △ Legacy `0x4a16baf414b8e637ed12019fad5dd705735db2e0` **DO NOT INTEGRATE**. Post-relaunch contract not yet published. | (legacy only) | **On hold** until post-relaunch contract published. Re-evaluate when Stablecorp publishes. |
| **ZARU** | ZAR Universal Network (South Africa) | TBD | ◐ Solana SPL only, institutional, not yet public | Solana only | **Out of scope.** Solana-only + institutional access; revisit if EVM deployment emerges. Do NOT confuse with xZAR `0x48f07301e9e29c3c38a80ae8d9ae771f224f1054` (different issuer). |

#### 2.1.1 Critical decimal gotchas

- **USDC on Arc:** native gas balance uses 18-decimal scaling (like ETH); ERC-20 interface uses 6 decimals. Code that reads via `IERC20(USDC).balanceOf(x)` gets 6-dec, code that reads `address(x).balance` gets 18-dec. **Never mix.** Already enforced in current `FxSwapHook` / hub contracts — preserve discipline when adding new pairs.
- **18-decimal assets** (BRLA, JPYC, ZCHF): pair math must scale USDC's 6-dec amount up by 1e12 when comparing to these assets. Existing `FxOracle` already handles asymmetric decimals via per-asset scaling — verify the path for each new asset in tests.
- **JPYC Sepolia trap:** their unofficial Sepolia uses 6 dec, mainnet uses 18 dec. **Mock our testnet JPYC at 18 dec** to mirror production. Do not use their Sepolia contract.
- **QCAD legacy:** 2 decimals. **Do not integrate** — explicitly excluded from the post-relaunch prospectus.

#### 2.1.2 Bridging models — CCTP V2 vs CCIP

The protocol assumes **USDC-via-CCTP-V2** as the canonical cross-chain settlement asset. Local stablecoins live on the Hub chain (Arc) and don't need to cross-chain themselves — users send USDC to the Hub, the Hub executes FX into the local stablecoin, then USDC is sent back out via CCTP V2.

**Exception: ZCHF.** Frankencoin uses Chainlink CCIP for cross-chain. If we want to expose ZCHF on multiple chains via the Hub model, the ZCHF contract on the Hub chain (Arc) is fine — but if we ever need to *move* ZCHF cross-chain at the protocol level, we'd need a separate CCIP integration. **For Phase 3, treat ZCHF as a single-chain pair on the Hub.** Do not build a CCIP integration in this phase.

### 2.2 Lending substrate
| Contract | Role | Audit | Notes |
|---|---|---|---|
| **Morpho Blue** singleton | Isolated lending markets (one per loan/collateral/oracle/irm/lltv tuple) | Spearbit, Cantina, Open Zeppelin | We are a *user* of Morpho. Markets are permissionless to create on Morpho's singleton; no fork. |
| **AdaptiveCurveIRM** | Morpho-blessed interest rate model | Audited with Morpho | Use as-is. |

### 2.3 Swap layer
| Contract | Role | Audit | Notes |
|---|---|---|---|
| **Uniswap v4 PoolManager** | Swap singleton | Public audits | Canonical deployment per chain. |
| **Permit2** | Token approvals + signed transfers | Uniswap Labs + audits | `0x000000000022D473030F116dDEE9F6B43aC78BA3` (canonical EVM). |
| **FxSwapHook** (ours) | PMM-style oracle-anchored v4 hook with Morpho rehypothecation | Internal + planned external pre-mainnet | The only meaningful bespoke financial logic. One pair per instance. |
| **FxRouter** (ours, Phase 2.6R) | EIP-712 signed-intent + Permit2 + SignatureChecker entry point | Pending audit | Thin wrapper, no balance custody beyond single-tx. |

### 2.4 Cross-chain
| Contract | Role | Audit | Notes |
|---|---|---|---|
| **CCTP V2 TokenMessenger** | Burn USDC on source | Circle internal + Halborn | Used by FxSpoke. |
| **CCTP V2 MessageTransmitter** | Mint USDC on destination, callback to hook | Same | Same. |

### 2.5 Governance + access (OZ-first)
| Contract | Role | Audit | Notes |
|---|---|---|---|
| **Compound Timelock 0.5.16** | 24-48h admin delay | Battle-tested since 2018 | Vendored in this repo (`vendor/compound-timelock/`). |
| **OZ AccessControl** | Role-based admin | OZ Contracts audits | Default for all roles. |
| **OZ Pausable** | Emergency stop | OZ | Pattern, embedded in admin contracts. |
| **OZ ReentrancyGuardTransient** | EIP-1153 reentrancy guard | OZ | Use on all external state-changing entry points. |
| **OZ SignatureChecker** | EOA + EIP-1271 + EIP-7702 unified verification | OZ | Used by FxRouter. |
| **OZ ERC4626** | Share-based pool accounting | OZ | Used for LP receipt tokens. |
| **OZ SafeERC20** | Safe transfer wrappers | OZ | Required for any ERC-20 interaction (USDT-style approve race). |
| **OZ EIP712** (or Solady's) | Typed data hashing | OZ / Solady (both audited) | Solady is faster, OZ is more conservative. Match Phase 2.6R choice (Solady, per Sera pattern). |

### 2.6 Oracles
| Contract | Role | Audit | Notes |
|---|---|---|---|
| **Pyth Network** | Primary FX feeds | Multiple audits | Permissionless pull. Per-pair feed IDs. |
| **RedStone** | Secondary (deviation cross-check) | Public audits | evm-connector requires Cancun — already in foundry.toml. |
| **`IFxOracle`** (ours) | Single internal price-read adapter | Internal | The *only* oracle surface for hooks. Hard rule from CLAUDE.md. |

**That's the whitelist.** Anything not above does not touch our balances.

---

## 3. Per-stablecoin onboarding playbook

Adding a stablecoin = deterministic checklist. No new architecture per asset.

### 3.1 Pre-flight due diligence (off-chain)

- [ ] Issuer's public audit available, ≤12 months old.
- [ ] Documented freeze/blacklist policy (Circle: yes; Mento: no — affects per-pool risk profile).
- [ ] Canonical address on the target chain confirmed.
- [ ] Pyth feed ID for the FX pair exists (e.g., `MXN/USD`, `BRL/USD`). If not — **block this asset** until available. Document in `docs/BLOCKED_PAIRS.md`.
- [ ] RedStone feed for same pair exists (deviation cross-check).
- [ ] Stablecoin has ≥$10M circulating supply on target chain.

### 3.2 On-chain steps

For each new stablecoin `X` paired with `Y` (typically USDC):

1. **Register oracle feeds** in `FxOracle.sol`:
   - Primary: Pyth feed IDs for `X/USD` and `Y/USD`.
   - Secondary: RedStone feed IDs for same.
   - Deviation gate: max 50 bps between primary/secondary, max 5 min staleness.
2. **Create Morpho markets** (two, one per loan-token direction):
   - Market A: loan = `X`, collateral = `Y`, oracle = `MorphoOracleAdapter(IFxOracle)`, irm = `AdaptiveCurveIRM`, lltv = `86%` (default; tighter for new assets).
   - Market B: mirrored.
   - Created permissionlessly via `Morpho.createMarket(params)`.
3. **Deploy `FxSwapHook` instance** locked to the `(X, Y)` pair. Mine the deploy address via `HookMiner` for v4 permission bits.
4. **Register pair in `FxRouter`** via `setPairAllowed(X, Y, true)` (assumes Phase 2.6R chose multi-pair router; see open question §13.3 of Phase 2.6R spec).
5. **Register pool in `FxMarketRegistry`** for discovery by monitoring/liquidator tools.
6. **Circle SCP registration** via `bun run sdk:circle:register deployments/<chain>.json` (idempotent).
7. **Update SDK addresses** in `packages/sdk/src/addresses/index.ts`.
8. **Seed the pool** with treasury LP (anti-rounding, prevents ERC-4626 share-inflation attack — standard hygiene).
9. **Tenderly vnet smoke-test** before mainnet: deposit, swap both directions, redeem.
10. **14-day monitoring period** before public announcement.

### 3.3 Per-asset risk parameters

In `FxMarketRegistry`:

```solidity
struct AssetRiskParams {
    uint96  perPoolCapUsd;          // $1M for tier-1 new asset, $50M for USDC
    uint16  maxOracleDeviationBps;  // 50 bps default; tighter for thinner pairs
    uint16  hookFeeBps;             // 5-15 bps typical
    uint16  protocolShareBps;       // % of fee to protocol vs LPs
    uint16  lltv;                   // 86% default, 80% for new/EM
    bool    isLive;                 // per-pair pause without affecting others
}
```

Conservative on first listing. Relax after 30 days clean operation + ≥$1M cumulative volume.

---

## 4. Stablecoin sequencing — anchor pairs first

Sequencing reflects Tomás's mainnet research (`.context/attachments/pasted_text_2026-05-14_18-33-11.txt`). EM pairs are the wedge because Morpho borrow APY + AMM spreads are *naturally* higher there than on G7 pairs.

### Tier 0 — already in scope
- USDC ↔ EURC (Phase 2.5/2.6). Proves the architecture. Thin yield.

### Tier 1 — anchor spokes (Q3 2026)
The two pairs that prove the FX-trial thesis:

- **USDC ↔ JPYC** — Japanese Yen, 18-dec asset, deep mainnet liquidity (Ethereum, Polygon, Avalanche). Deposit USDC, borrow JPY for hedging/payments use cases. Anchor for Asia corridor.
- **USDC ↔ BRLA** — Brazilian Real, 18-dec, currently Polygon-only mainnet. Avenia is processing wider EVM deployment (awaiting reply). Brazil corridor — Selic policy rate 13% drives natural borrow demand for USDC against BRL collateral.

### Tier 2 — second wave (Q4 2026)
Multi-chain footprint, 6-dec alignment with USDC, cleaner integration:

- **USDC ↔ MXNB** — Mexican Peso, 6-dec, live on Arbitrum + Ethereum + Avalanche. Mexico remittance corridor (~$60B/yr).
- **USDC ↔ AUDF** — Australian Dollar, 6-dec, live on 5 chains (same address). Establishes G10 baseline pair for institutional flow.

### Tier 3 — SEA + CHF basket (Q1 2027)
- **USDC ↔ PHPC** — Philippine Peso, 6-dec, Polygon. Southeast Asia remittance.
- **USDC ↔ ZCHF** — Swiss Franc / Frankencoin, 18-dec, 8 chains via CCIP. **Treat as single-chain pair on Hub** (no CCIP integration in this phase).

### Tier 4 — opportunistic / awaiting issuer
- **USDC ↔ KRW1** — Korean Won, live on Avalanche + Plume, awaiting BDACS reply for Arc and others. Add when ready.
- **USDC ↔ QCAD** — On hold until Stablecorp publishes post-relaunch contract. Do NOT integrate the legacy contract.
- Other StableFX-listed pairs within 60 days of their launch (so Pasillo / integrators can route consistently).

### Out of scope this phase
- **ZARU** — Solana-only, institutional. Revisit if EVM deployment emerges.
- Cross-stable pairs (e.g., BRLA ↔ JPYC) — Tier 5+. First, all pairs need ≥$5M TVL against USDC.

**Cadence:** 1 pair per 4 weeks (oracle, Morpho market, hook deploy, internal review, seed, 14-day monitor). Faster only via co-deploy batches with shared oracle setup. Tier 1 (JPYC + BRLA) deployed in parallel as a single batch.

### 4.1 Per-pair oracle reality check

Confirm Pyth + RedStone feed availability for **every pair** before scheduling:

| Pair | Pyth feed needed | RedStone feed needed | Likely available? |
|---|---|---|---|
| USDC/EURC | EUR/USD | EUR/USD | ✅ Both, deep coverage |
| USDC/JPY | JPY/USD | JPY/USD | ✅ Both, deep coverage |
| USDC/BRL | BRL/USD | BRL/USD | ⚠️ Pyth yes, RedStone confirm — fallback path needed if RedStone missing |
| USDC/MXN | MXN/USD | MXN/USD | ✅ Both |
| USDC/AUD | AUD/USD | AUD/USD | ✅ Both, deep coverage |
| USDC/PHP | PHP/USD | PHP/USD | ⚠️ Confirm both — thin coverage risk |
| USDC/CHF | CHF/USD | CHF/USD | ✅ Both |
| USDC/KRW | KRW/USD | KRW/USD | ⚠️ Confirm both |

For any pair where Pyth or RedStone is missing, **do not list it.** Document in `docs/BLOCKED_PAIRS.md` and escalate to oracle teams. Listing without a deviation cross-check breaks our oracle discipline.

---

## 5. Cross-chain coverage

CCTP V2 chains supported (existing): Avalanche (HUB MAINNET), Arc (testnet hub + future migration target), Base, Ethereum, Arbitrum, Optimism, Polygon, Unichain, Solana (Spoke-only).

Rules:
- **Hub mainnet:** **Avalanche C-Chain** — 5-6 of 7 basket stablecoins live natively. Morpho Blue + Pyth + RedStone + CCTP V2 Domain 1 all available. Decisive for v1.
- **Hub testnet:** **Arc testnet** (StableFX-compatible dev environment) + **Avalanche Fuji** (cheap iteration; already migrated per `bbb0302`).
- **Spokes:** every CCTP V2 chain. Spoke logic is thin (CCTP burn + `enterHub` post). Already implemented.
- **Stablecoin coverage:** Tier 1-2 pairs deployed on Hub chain only. Spokes accept USDC (CCTP-universal); local stablecoins live on Hub.
- **Arc mainnet (future):** when Arc GA + Morpho-on-Arc converge, decide: spoke-into-Avalanche-Hub OR second institutional Hub for StableFX-native flow. Hub-and-spoke architecture supports both.

See `docs/DEPLOY_MAINNET_HUB.md` for the detailed Hub-chain decision matrix and per-chain spoke deployment plan.

---

## 6. Integrator-facing surface (for Pasillo + third parties)

This protocol is permissionless. Any integrator can build on top. The surface they consume:

### 6.1 Read endpoints (RPC + view calls)
- `FxSwapHook.quoteExactInput(sellToken, sellAmount)` → `(buyAmount, oraclePrice, ...)` (per Phase 2.6R spec §5.1).
- `FxMarketRegistry.listPools()` → all `(chain, pair, pool address, risk params)` tuples.
- `IFxOracle.priceOf(token)` → canonical FX price for off-chain quote calculation.

### 6.2 Write paths
- `FxRouter.executeIntent(intent, sig, permit, permitSig)` — signed-intent entry. Any integrator can construct an envelope and submit.
- Direct `FxSwapHook` swap via Uniswap v4 Universal Router — alternative for wallet-direct flow.

### 6.3 Event surface (for indexers)
- `IntentExecuted` (FxRouter) — quote-id, taker, recipient, amounts, fee.
- `FxSwapHook` swap / deposit / redeem events.
- `FxMarketRegistry` pool registration events.

### 6.4 What integrators (Pasillo and others) handle, NOT this protocol
- KYB onboarding (Pasillo / their concern).
- Quote aggregation across multiple protocols / RFQ rails.
- Compliance reporting per jurisdiction.
- Yield wrapping (USYC, sUSDS, etc.) — integrators wrap LP shares with off-protocol yield products if they want to.
- Customer billing.
- Sanctions screening.

**This protocol is pure infrastructure.** Anyone can integrate. Pasillo is one integrator. They don't get protocol-level privileges.

---

## 7. Watchlist — permissionless yield substrates (do not build, track)

The narrow product has no Fed-rate yield substrate. LP yield = Morpho borrow APY + AMM spread. Honest framing in product copy.

When a permissionless yield substrate matures, we *could* adopt it via a thin adapter. Conditions for triggering adoption:

| Candidate | Status (2026-05) | Watch trigger |
|---|---|---|
| **sUSDS / sDAI** (Sky) | Live, ~$1.5B TVL, permissionless | If TVL > $3B AND public insurance + 18mo clean record |
| **Mountain USDM** | Live, permissionless | If TVL > $500M AND ≥1 major DeFi integration AND insurance |
| **Ondo USDY** | Permissionless ex-US | If Pasillo's US-exposure issue resolves AND TVL > $1B |
| **OpenEden TBILL** | KYC required | Skip — not permissionless |
| **Maple syrupUSDC** | Permissionless | Different risk class (credit, not T-bill) — skip for now |

**Decision rule:** when ≥1 candidate hits all triggers, governance vote to add via a new thin adapter mirroring the pattern of `FxUsycAdapter` *in the Pasillo handoff doc*. Until then, public rail is FX-spread-plus-Morpho-only. **State this honestly in LP UI: "Yield = Morpho lending APY + AMM spread. No RWA backing in protocol pools."**

---

## 8. Per-asset oracle requirements

Per pair `X/Y`:

- **Pyth feed:** confirm feed IDs for `X/USD` and `Y/USD`. Cross-derive `X/Y = (X/USD) / (Y/USD)`.
- **RedStone feed:** same as cross-check, via evm-connector (Cancun required).
- **Deviation gate:** ≤ 50 bps between Pyth and RedStone, else revert swap.
- **Staleness gate:** price age ≤ 5 min Pyth / equivalent RedStone.
- **Fallback:** if primary stale, secondary becomes primary; if both stale, pause that pair.

**Hard constraint:** if Pyth OR RedStone lacks the pair, **do not list it**. Track blocked pairs in `docs/BLOCKED_PAIRS.md` and lobby oracle teams.

---

## 9. Test plan

Per new pair, ship with:
- Unit tests (mocked external deps) — fast loop.
- Fork tests (real Morpho + real Pyth + real Permit2 on chain fork) — pre-deploy gate.
- Tenderly vnet integration — end-to-end with primed state, pre-mainnet gate.

Test surface additions:

### 9.1 Multi-pair pool tests
- Parameterized per pair (template + per-asset config): deploy, deposit, swap each direction, redeem.
- Oracle staleness: swap reverts when feed > 5 min old.
- Oracle deviation: swap reverts when Pyth vs RedStone > 50 bps.
- Per-pool cap: deposit reverts at cap.
- LP share-inflation defense: pre-seeded pool resists first-LP attacks.

### 9.2 Cross-chain (new stablecoin via Spoke)
- Spoke → Hub on new stablecoin: CCTP V2 burn, mint, hook callback.
- Stranded-deposit recovery: `sweepStrandedDeposit` 24h grace works.

### 9.3 Asset-specific edge cases
- Non-freezable Mento assets: confirm pool operates if upstream Mento mint mechanics change.
- Freezable Circle assets: pool behavior if issuer freezes a counterparty mid-swap (should: revert cleanly, no stuck state).

---

## 10. Deployment + governance

### 10.1 Deploy order (per new pair)
1. Register Pyth + RedStone feeds (timelock-gated, pre-stageable).
2. Create Morpho markets (permissionless).
3. Deploy hook (HookMiner).
4. Register pair in FxRouter.
5. Register pool in FxMarketRegistry.
6. Circle SCP registration.
7. Seed pool with treasury LP.
8. Tenderly vnet smoke-test.
9. 14-day monitoring before public announcement.

### 10.2 Governance roles (OZ AccessControl)
- `DEFAULT_ADMIN_ROLE` = Compound Timelock (24-48h delay).
- `OPERATIONS_ROLE` = multisig (3-of-5 hot actions, no timelock — pause, per-pair allowlist toggle).
- `EXECUTOR_ROLE` (FxRouter) = scoped EOAs for integrators that prefer relayed flow (optional; users can also self-submit).

### 10.3 Timelock-gated (24h+)
- Add asset to whitelist.
- Change per-asset risk params.
- Add new oracle source.
- Transfer admin role.

### 10.4 Hot actions (no timelock)
- Pause (any pair / global).
- Emergency parameter freeze.

---

## 11. Risk register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| USDC freeze on a counterparty mid-swap | Low | Medium | Permissionless rail: trades fail cleanly, no protocol custody held across blocks. |
| Local stablecoin depeg (regional bank event) | Medium | Medium | Per-pool caps tight on first listing; oracle deviation gate; pause on alert. |
| Morpho Blue critical bug | Very Low | Catastrophic | Multiple audits + $2B+ TVL + 18-mo track record. Industry-wide event if it happens. |
| Pyth + RedStone joint manipulation | Very Low | High | Deviation gate + pause-on-disagreement. |
| Smart contract bug in FxSwapHook / FxRouter | Medium | High | Pre-mainnet audit (CertiK or Spearbit); bounty; gradual TVL ramp via per-pool caps. |
| CCTP V2 failure | Very Low | High | `sweepStrandedDeposit` 24h recovery in Spoke; Circle SCP monitoring. |
| Pasillo (or any integrator) compromised | N/A to protocol | N/A | Integrator concern. Protocol exposes permissionless surface; their compromise doesn't reach our balances unless they hold an `EXECUTOR_ROLE` — and that role is narrow + rotatable. |
| Regulatory pressure on protocol | Low | Low | Pure DeFi posture, no KYB, no MSB, no fiat custody. No US-entity legal exposure at the protocol layer. |

---

## 12. Done = ?

This phase completes when:

1. Tier 0 (USDC↔EURC) public pool live on Hub chain, audited.
2. Tier 1 (USDC↔MXNB, USDC↔BRZ-or-BRLA) deployed per §3 playbook, both directions, 14-day clean operation.
3. All §9 test categories green.
4. `docs/BLOCKED_PAIRS.md` exists and is up to date.
5. Pasillo (or another integrator) has successfully integrated as a customer via `FxRouter.executeIntent` and `FxMarketRegistry` views — proving the integrator surface works.
6. LP UI honestly states "Yield = Morpho APY + AMM spread. No RWA backing."
7. Risk register reviewed quarterly.

---

## 13. Open questions

1. **BRZ vs BRLA** for the Brazil corridor. Pasillo has market data we don't. Decide by Tier-1 deploy date.
2. **Multi-pair vs one-pair-per-router** — Phase 2.6R open question. For multi-stablecoin economics, multi-pair is required. Finalize before building.
3. **EM pair cap defaults** — $1M initial / $5M after 30 days / $25M after 90 days reasonable? Conservative is fine for v1.
4. **`OPERATIONS_ROLE` multisig members** — defined per the Pasillo legal structure. Out of scope here; flag for governance kickoff.

— end of spec —
