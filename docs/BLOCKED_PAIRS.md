# Blocked pairs — fx-Telaraña stablecoin basket

Tracks FX pairs that cannot be onboarded yet, why, and the unblock criteria.
Per `docs/SPEC_PHASE_3_MULTI_STABLECOIN.md` §4.1, a pair is blocked if **either** Pyth or RedStone lacks a feed for it (oracle deviation cross-check is a hard requirement), or if the issuer contract doesn't exist on the Hub chain, or if there's a regulatory / decimal / bridging caveat we haven't resolved.

Each entry includes: pair, reason, status as of last review, what unblocks it, owner.

Last reviewed: 2026-05-14.

---

## Active blocks

No Phase 3 basket pair is blocked on oracle/decimal readiness as of the 2026-05-15 review. KRW1 moved to "Recently unblocked" below.

## Recently unblocked

### USDC ↔ KRW (KRW1)

- **Resolution — decimals confirmed.** KRW1 is **natively live on Avalanche mainnet** at `0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318` (and on Plume at `0x8304d1b1d04c968270ae66a0c7758f7471b8ec3f`). On 2026-05-14, `decimals()` was probed on Avalanche and returned `0`; `name()`, `symbol()`, and `totalSupply()` returned `KRW1`, `KRW1`, and `10000000`.
- **Resolution — oracle coverage confirmed.** Pyth publishes `USD/KRW` (`0xe539120487c29b4defdf9a53d337316ea022a2688978a468f9efd847201be7e3`) and RedStone publishes `KRW`. `FxOracle.setPythFeedConfig(token, feed, true)` now supports this inverse-feed shape.
- **Status:** Avalanche-native — Phase 3 Hub gets KRW1 with issuer decimals = 0. Arc testnet can deploy `mKRW1` at 0 decimals until BDACS deploys to Arc.

### USDC ↔ CAD (QCAD)

- **Reason — issuer relaunched 2025-11-20.** Legacy QCAD at `0x4a16baf414b8e637ed12019fad5dd705735db2e0` (2 decimals!) is explicitly excluded from the new prospectus per Stablecorp. Pre-relaunch tokens are NOT transferable into the new trust structure.
- **Reason — post-relaunch contract not yet published.** Stablecorp has not published the post-relaunch CAD-token addresses on any chain.
- **Unblock criteria:**
  1. Stablecorp publishes the post-relaunch contract address(es).
  2. Confirm decimals on the new contract — likely 18, but the legacy used 2; do not assume.
  3. Confirm chain availability (Ethereum, Stellar, Algorand listed in Tomás's reference as "pending — contact Stablecorp").
- **Owner:** Tomás (Stablecorp chase). **Do not integrate legacy under any circumstance.**

### USDC ↔ ZAR (ZARU)

- **Reason — Solana-only + institutional gated.** ZARU launched 2026-02-03 by ZAR Universal Network, distributed via Luno and EasyEquities. No public EVM deployment.
- **Reason — xZAR confusion risk.** xZAR (`0x48f07301e9e29c3c38a80ae8d9ae771f224f1054` on Ethereum) is a **different** issuer and asset. Tomás flags explicitly: do not conflate.
- **Unblock criteria:**
  1. ZAR Universal publishes an EVM deployment that's eligible for permissionless protocol use (unlikely near-term).
  2. OR a different regulated ZAR-stablecoin issuer emerges with EVM support.
- **Owner:** N/A — out of scope this phase.

---

## Excluded from Phase 3 basket (deliberate scope reduction)

These were on earlier drafts of the Phase 3 basket but cut from the production scope. Different from "blocked" — these will NOT be re-added without an explicit basket-expansion decision.

### USDC ↔ PHP (PHPC) — **dropped from Phase 3 basket**

- **Reason — basket trim, 2026-05-14.** PHPC is not natively live on Avalanche mainnet (the chosen Phase 3 Hub). Listing it would require either bridging from Polygon (adds CCIP-class risk surface, off-strategy) or maintaining a permanent mock on the Hub (off-strategy for production). Combined with the unverified RedStone PHP/USD signer coverage on Avalanche, the leverage isn't there for Phase 3.
- **Re-evaluation:** When (a) Coins.PH deploys PHPC natively on Avalanche, AND (b) RedStone confirms PHP/USD production signers on Avalanche.

### USDC ↔ BRL (BRLA) — **dropped from Phase 3 basket**

- **Reason — basket trim, 2026-05-14.** BRLA is Polygon-native (`0xe6a537a407488807f0bbeb0038b79004f19dddfb`), not on Avalanche mainnet. Avenia is processing wider EVM deployment but hasn't shipped Avalanche. Adding it to the Phase 3 Hub would mean bridging or mocking; same off-strategy logic as PHPC.
- **Re-evaluation:** When Avenia deploys BRLA natively on Avalanche mainnet. Brazil corridor remains a Tier 4+ candidate but does not block Phase 3.

---

## Watch list (not blocked, but not yet scheduled)

### USDC ↔ EUR (EURC) — additional chain depth
- Already live as anchor Tier 0 pair on Hub. Track if EURC native deployment expands to chains where we want spokes (e.g., Polygon, Avalanche) for capital-efficiency reasons.

### Cross-stable pairs (e.g., BRLA ↔ JPYC, MXNB ↔ AUDF)
- Tier 5+. Per `SPEC_PHASE_3_MULTI_STABLECOIN.md` §4, deferred until all USDC-paired sides have ≥$5M TVL.

### USDC ↔ ZCHF — multi-chain settlement
- ZCHF uses Chainlink CCIP for cross-chain bridging (not CCTP V2). Phase 3 treats ZCHF as a single-chain pair on Hub. If later we want ZCHF on a spoke chain *as the cross-chain output asset*, we'd need a CCIP integration. **Deferred** — re-evaluate in Phase 4+ if Frankencoin demand justifies.

---

## How to add a new entry

1. Document the **reason** specifically (not "we don't have time" — that's not a block, it's a priority).
2. List **unblock criteria** as concrete, verifiable steps.
3. Assign **owner** — the human (or agent) responsible for the next action.
4. Re-review at quarterly cadence per `SPEC_PHASE_3_MULTI_STABLECOIN.md` §11.

If a pair leaves this file (gets unblocked), open a PR adding it to the Tier sequencing in `SPEC_PHASE_3_MULTI_STABLECOIN.md` §4 and removing the entry here.
