# Yield Substrate Watchlist — fx-Telaraña

**Status:** Tracking document. Companion to `docs/SPEC_PHASE_3_MULTI_STABLECOIN.md` §7.
**Last revision:** 2026-05-14.
**Cadence:** Quarterly review.

This is the list of permissionless yield substrates we are **NOT** building against today, but are tracking. If/when a candidate meets all triggers in its row, governance can vote to add it via a thin adapter mirroring the pattern of `FxUsycAdapter` *in the Pasillo handoff doc*.

Why a watchlist instead of building now: the protocol's honest yield is `Morpho borrow APY + AMM spread`. Adding RWA backing changes the risk profile (issuer freeze, regulatory, jurisdictional). Each substrate gets vetted on its own timeline against fixed triggers — no ad-hoc "this seems mature enough" decisions.

---

## Candidates

| Candidate | Issuer | Yield source | Status (2026-05) | Permissionless? | Watch trigger |
|---|---|---|---|---|---|
| **sUSDS / sDAI** | Sky (formerly MakerDAO) | T-bills + USDC LP | Live, ~$1.5B TVL | ✅ Yes | TVL > $3B AND ≥18 mo clean record AND public insurance |
| **Mountain USDM** | Mountain Protocol (BVI) | T-bills | Live | ✅ Yes (ex-US) | TVL > $500M AND ≥1 major DeFi integration (Morpho / Aave / Pendle / similar) AND insurance |
| **Ondo USDY** | Ondo Finance | T-bills | Live | ✅ Yes (ex-US) | Pasillo's US-exposure issue resolves AND TVL > $1B |
| **OpenEden TBILL** | OpenEden | T-bills | Live, growing | ❌ KYC required | **Skip — not permissionless.** Pasillo concern, not protocol. |
| **Maple syrupUSDC** | Maple Finance | Permissioned credit pools | Live | ✅ Permissionless wrapper | Different risk class (credit, not T-bill) — **skip for now.** Revisit when Maple has a fully-permissionless T-bill product. |

---

## Decision rule

When ≥1 candidate hits all triggers in its row:

1. Open a governance proposal naming the candidate + the proposed `FxYieldAdapter` design (thin wrapper around the substrate's deposit/redeem; balance tracked via `IFxReceipt`-style ERC-4626).
2. Reference the substrate's most recent audit + insurance terms in the proposal.
3. 14-day comment window.
4. If approved by timelock + `OPERATIONS_ROLE`, deploy the adapter behind the same §3.2 onboarding playbook used for stablecoins.

**No off-cycle additions.** A candidate that becomes attractive between quarterly reviews waits until the next review.

---

## Honest framing

Until ≥1 candidate triggers in, the LP UI must say:

> Yield = Morpho lending APY + AMM spread. No RWA backing in protocol pools.

This is the spec §7 hard constraint. Marketing that implies otherwise is a compliance + trust violation.

---

## Out of scope this phase

- **USYC** — KYB-gated. Moved to Pasillo (`.context/PASILLO_HANDOFF_USYC_KYB_INSTITUTIONAL.md`). Not a protocol concern.
- **Aave aTokens / Compound cTokens as yield substrate** — possible Phase 4+ if the LP pool needs idle-liquidity utilization beyond Morpho rehypothecation. Not on this list because LP pool already supplies idle to Morpho via FxSwapHook's rehypothecation path — adding Aave on top is double-counting.

---

## Review log

| Date | Reviewer | Changes |
|---|---|---|
| 2026-05-14 | criptopoeta (PR-7 closure) | Initial document; ports `SPEC_PHASE_3_MULTI_STABLECOIN.md` §7 table into a standalone tracking doc with quarterly cadence. |
