# Incident Response Runbook — fx-Telaraña

**Status:** Operations document. Updated as the on-call rotation matures.
**Last revision:** 2026-05-14.
**Scope:** What to do when something breaks on the live protocol.

This is a runbook, not a strategy document. Each section answers: **what signal fired?** → **what do I look at?** → **what action takes the protocol back to safe state?**

The protocol is testnet-first (Avalanche Fuji vnet + Arc Testnet) — but the patterns here apply identically once Avalanche mainnet ships. Pause buttons exist on testnet too; rehearse them.

---

## 0. Severity ladder

| Level | Meaning | Pager? | Response window |
|---|---|---|---|
| **P0** | Funds at risk OR protocol invariant violated. Examples: oracle delivers manipulated price, FxHubMessageReceiver drains, Morpho debt math diverges, USDC issuer freezes counterparty mid-swap. | Yes — page on-call + incident channel | < 15 min |
| **P1** | Service degraded, no funds at immediate risk. Examples: Pyth feed stale > 10 min, Tenderly Alerts firing, oracle deviation > 50 bps but trades reverting cleanly. | Slack ping on-call | < 1 hour |
| **P2** | Cosmetic / monitoring artifact. Examples: SDK address mismatch, indexer gap, dashboard down. | Best-effort | Next business day |

Default to escalating up, not down. A P2 that becomes a P0 because nobody looked is the failure mode.

---

## 1. Pause — the single most important button

Three pause surfaces exist. Use the narrowest one that contains the incident.

| Surface | Effect | Caller | Notes |
|---|---|---|---|
| `FxMarketRegistry.setPoolLive(loanToken, collateralToken, false)` | Halts `supply`, `supplyCollateral`, `borrow` on that single pair. **Exit-side (`withdraw`, `repay`) remains open.** | `owner` (PR-6 → `OPERATIONS_ROLE`) | Use for single-pair oracle / depeg / cap-breach incidents. |
| `FxRouter.setPaused(true)` | Halts new signed-intent executions. Already-pending swaps in-flight at the v4 hook continue. | `owner` (PR-6 → `OPERATIONS_ROLE`) | Use when the issue is in the router envelope path (signature flow, permit2). |
| `FxSwapHook` (none in MVP) | No hook-level pause in Phase 2.5/3 MVP. Defer to FxRouter pause + per-pair Registry pause. | n/a | Adding a hook-level pause is a Phase 4 candidate. |

**Hot rule:** if you can't tell which surface to flip, flip *both* the relevant pair on Registry AND `FxRouter.setPaused(true)`. The cost of a too-wide pause is operator embarrassment; the cost of a too-narrow pause is fund loss.

---

## 2. P0 playbook — funds at risk

### 2.1 Diagnose (under 5 min)

Open three things in parallel:

1. **Tenderly Alerts dashboard** — which contract emitted the alarm event? Common offenders:
   - `OracleDeviation` from `FxOracle.getMidVerified` (Pyth vs RedStone gap > 50 bps).
   - `DepositStranded` from `FxHubMessageReceiver` (CCTP-side hook revert).
   - `NotAuthorizedForOnBehalf` from `FxMarketRegistry` (someone tried to drain a victim — gate held).
2. **Circle SCP event monitor** — same events, redundant source.
3. **Snowtrace / Arcscan** — pull the offending tx, read internal-call trace.

### 2.2 Contain (under 15 min)

Run the narrowest pause that covers the affected surface (see §1). Notify the team in `#fx-incidents` Slack with:
- One-line: what fired, which contract, what action you took.
- Snowtrace link + Tenderly trace link.

### 2.3 Investigate (1-4 hours)

Branch a Tenderly Pro vnet from the current Avalanche head. Reproduce the failing tx + try the patch in isolation. **Do NOT push a fix to mainnet without a vnet reproduction first.**

### 2.4 Recover (timeline depends)

| Scenario | Recovery path |
|---|---|
| Stranded CCTP V2 deposit | `FxHubMessageReceiver.sweepStrandedDeposit(messageNonce)` after 24h grace. Beneficiary signs the call. |
| Oracle deviation transient | Wait for feeds to converge; trades naturally revert during the deviation window. Optionally update `maxDeviationBps` via timelock if the gate is too tight. |
| Oracle deviation persistent | Pause the affected pair via `setPoolLive(..., false)`. Investigate which feed is wrong. If Pyth is wrong, file with Pyth + temporarily lean on RedStone-only via `getMidFromPyth` skip (requires code change — see PR-3 work for the split). |
| Morpho bad-debt event | Socialized via Morpho's existing mechanism. Confirm `FxLiquidator` is operational; LP haircut is realized via `FxReceipt.totalAssets()` reading lower `expectedSupplyAssets`. |
| FxRouter signature bypass | `setPaused(true)` immediately. Investigate via Tenderly trace. **Never modify `FX_INTENT_TYPEHASH` post-launch** — invalidates every signed envelope. |

---

## 3. P1 playbook — service degraded

### 3.1 Pyth / RedStone staleness alert

Off-chain monitor (Tenderly Alerts or Grafana) fires when either feed > 5 min stale.

1. Check `pyth.network/price-feeds` for the affected pair's update cadence. Some EM pairs have slower cadence than G7.
2. If cadence is normal but our feed-read reverts: most likely `FxOracle.maxOracleAge` is set tighter than the network's natural update gap. Either:
   - Submit a fresh Pyth payload yourself via `getMidWithUpdate(...pythUpdate)` paying the Pyth fee, OR
   - Relax `maxOracleAge` via timelock (24-48h delay — not for hot incidents).
3. Document the cadence finding in `docs/BLOCKED_PAIRS.md` if persistent.

### 3.2 Tenderly Alert firing on Stranded events

`FxHubMessageReceiver.DepositStranded` fires when CCTP V2 mint succeeded but the hub-side `hubCalldata` execution didn't fully consume the bridged USDC. Either:

- The user's `hubCalldata` was malformed (their problem; sweep returns funds via `sweepStrandedDeposit` after 24h).
- The Registry/Morpho action reverted (our problem; investigate the registry-side call).

For the second case: look at the `ret` bytes emitted in the `DepositStranded` event — that's the revert reason from `MARKET_REGISTRY.call(hubCalldata)`.

### 3.3 Per-pool cap breach

`PerPoolCapExceeded` revert in `supply()`. Expected behavior — the cap is doing its job. Confirm via Tenderly that the would-be-total matches the cap and bump the cap via `setAssetRiskParams` if growth justifies it.

---

## 4. P2 playbook — cosmetic / monitoring

- **SDK address out of sync:** edit `packages/sdk/src/addresses/index.ts`, `bun run sdk:build`, publish.
- **Tenderly Alert dashboard gap:** verify alert config still points at the live addresses (after deploys, monitoring addresses can drift).
- **Indexer lag:** restart the indexer; not a protocol concern.

---

## 5. Communication

### 5.1 Internal

- Incidents post to `#fx-incidents` Slack with the standard four-line template:
  ```
  P{0,1,2} | {date-time UTC} | {one-line summary}
  Trigger: {event name + contract addr + tx hash}
  Action taken: {pause flips, etc.}
  Owner / on-call: {handle}
  ```

### 5.2 External

For P0/P1 with user impact, post to the protocol's status page within 30 min. Template:

> **{Date-time UTC} — Incident on Avalanche mainnet hub**
> We have temporarily paused {pair name} pool. Withdrawals and repays remain open. Diagnostic in progress; ETA for resolution: {X} hours. Updates here every 30 min.

Never speculate on cause in the first post. Stick to: what's paused, what still works, when the next update lands.

---

## 6. Post-incident review

Within 72 hours of resolution:

1. Timeline reconstruction in `reports/INCIDENT_{date}_{slug}.md`.
2. Root cause + contributing factors. Include the Tenderly tx hash and the vnet branch where the patch was first reproduced.
3. Action items: code changes, monitor additions, runbook updates. Each with an owner.
4. Update this runbook if a new failure mode was discovered.

---

## 7. Drills

Quarterly: a planned drill exercises the pause + recovery path on the staging vnet (Avalanche Fuji or Tenderly-forked Avalanche). The drill is "real" — operators must follow this runbook, not a special-case script.

Drill scenarios to rotate through:
1. Oracle deviation > 50 bps (forced via `tenderly_setStorageAt` on the mock Pyth).
2. Stranded CCTP V2 deposit (force a Registry-side revert via state override).
3. Per-pool cap breach mid-supply.
4. Compromised admin key (rotate timelock admin under fire — PR-6 prerequisite).

After each drill: PR-update this doc with anything that surprised you.

---

## 8. On-call rotation

- TBD — defined per the operating entity's structure.
- Until rotation is staffed: incidents page the deployer EOA's contact + the GitHub repo's `CODEOWNERS`.

---

## Reference

- `docs/SPEC_PHASE_3_MULTI_STABLECOIN.md` §11 (Risk register) — predicted failure modes.
- `docs/DEPLOY_MAINNET_HUB.md` §6.5–§6.6 — pre-deploy monitoring checklist.
- `reports/AUDIT_REPORT.md` v1.2.2 — known classes of incident from the defensive + adversarial audit passes.
- Tenderly Pro Web3 Actions docs — for auto-mitigation patterns (e.g. auto-`sweepStrandedDeposit` keeper).
