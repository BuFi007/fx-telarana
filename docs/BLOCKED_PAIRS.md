# Blocked pairs — fx-Telaraña stablecoin basket

Tracks FX pairs that cannot be onboarded yet, why, and the unblock criteria.
Per `docs/SPEC_PHASE_3_MULTI_STABLECOIN.md` §4.1, a pair is blocked if **either** Pyth or RedStone lacks a feed for it (oracle deviation cross-check is a hard requirement), or if the issuer contract doesn't exist on the Hub chain, or if there's a regulatory / decimal / bridging caveat we haven't resolved.

Each entry includes: pair, reason, status as of last review, what unblocks it, owner.

Last reviewed: 2026-05-14.

---

## Active blocks

### USDC ↔ KRW (KRW1)

- **Reason — decimals unknown.** Tomás's mainnet reference (`.context/attachments/pasted_text_2026-05-14_18-33-11.txt`) lists KRW1 on Avalanche and Plume but does not specify decimals. Mock testnet contract cannot be deployed at the wrong decimals — JPYC's Sepolia/mainnet decimal mismatch is the cautionary tale.
- **Reason — Arc deployment pending.** BDACS has not yet deployed KRW1 to Arc, Polygon, Ethereum, BNB, or Aptos (per Tomás's reference, "awaiting reply from BDACS").
- **Unblock criteria:**
  1. Confirm KRW1 mainnet decimals via BDACS or via `cast call <KRW1_addr> "decimals()"` against Avalanche or Plume.
  2. Arc deployment available, OR Pasillo / project owner approves mock-only KRW1 for the testnet phase.
- **Owner:** Tomás (issuer chase) + implementing agent (decimal confirmation via on-chain call).

### USDC ↔ PHP (PHPC) — Arc availability

- **Reason — Arc testnet deployment rumored, not confirmed.** PHPC is live on Polygon at `0x87a25dc121Db52369F4a9971F664Ae5e372CF69A` (6 decimals confirmed). Tomás's reference flags Arc Testnet as "rumored / awaiting confirmation" and Coins.PH has not replied on Ronin.
- **Reason — RedStone PHP/USD feed coverage uncertain.** Pyth has PHP/USD; RedStone production signer set coverage for PHP/USD must be verified before we list.
- **Unblock criteria:**
  1. Confirm PHPC on Arc — if absent, deploy `mPHPC` mock at 6 dec for Arc testnet (per `DEPLOY_MAINNET_HUB.md` §3.2).
  2. Verify RedStone PHP/USD published by production signers on Arc.
- **Owner:** Implementing agent (mock deploy) + Tomás (Coins.PH chase).

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
