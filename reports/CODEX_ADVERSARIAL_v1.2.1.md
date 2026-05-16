# Codex Adversarial Review — fx-Telaraña v1.2.1
Date: 2026-05-14
Reviewer: Claude Opus 4.7 (general-purpose subagent, contrarian posture)
First-pass author: Claude Opus 4.7 (reports/AUDIT_REPORT.md v1.2.1)
Tenderly vnet: `5ea52b4d-fe5a-4026-828c-d9b8fa08cec6` (Avalanche Fuji, chainId 43113 — testnet only)
Snapshot root: `0x681228b28ba16c12868bf49e1af8acad858cbac9c50e3a7f650c315edadafa50`
Concordance bias caveat: same model on both passes — Codex attempted first, blocked by OpenAI moderation 3x and sandbox-RPC isolation. This is second-best.

---

## Delta table (the headline)

| Item | First-pass verdict | This-pass verdict | Δ |
|---|---|---|---|
| R1 first-depositor inflation (direct-donation variant) | Medium → potentially High | **DISPUTED — mechanism inoperative** | -2 (downgraded) |
| R1 first-depositor inflation (Morpho-side donation variant) | Not enumerated | **NEW-FINDING — same severity class** | new |
| Production-oracle delta (RedStone calldata-tail) | "Exists, not measured; R7 operational" | **CONFIRMED with sharper scope: N/A for `executeDeposit`+supply path; affects only borrow/withdraw-with-health/liquidate** | scoping refined |
| R5 uint96 truncation | Low (Circle-gated) | **CONFIRMED Low + path (b) is real fund-stuck hazard, not "cosmetic"** | mechanism clarified |
| Q8 ordering | Open Question, no severity | **BLOCKED — Tenderly Pro write-quota exhausted mid-pass** | unresolved |
| S7b accrueInterest path | Inferred Panic(0x11) per code identity | **BLOCKED — `simulate_vnet_transaction.state_overrides.stateDiff` is ignored by Tenderly VNet API; `setStorageAt` quota-blocked** | unresolved |
| 18-decimal S7 | TO BE MEASURED | **BLOCKED — quota + deployment effort** | unresolved |

**Headline finding:** The R1 attack mechanism described in the defensive pass does NOT work. The donation must go through Morpho, not directly to the wrapper. The vulnerability class still exists, but with different ergonomics and a different mitigation.

---

## Item 1: R1 — ERC-4626 first-depositor inflation property

**Hypothesis (defensive pass)**: "Attacker deposits 1 wei, donates USDC directly to wrapper, then victim's deposit rounds to 0 shares."

**Reproducer (empirical, run on the live vnet)**:
1. Snapshot baseline (`0x681228b28ba16c12868bf49e1af8acad858cbac9c50e3a7f650c315edadafa50`).
2. Reset `FxReceiptUSDC` (`0x9f0947d7…b88e`) to fresh-vault state:
   - Slot 2 (`_totalSupply`) → 0
   - Morpho `position[M2][wrapper].supplyShares` slot `0xb7829efe…40c1` → 0
   - Morpho `market[M2]` slot 0 (`totalSupplyAssets|totalSupplyShares` packed) at `0x4ed92523…85a3` → 0
3. ActorA = `0xA11ce0…A11c`, ActorB = `0xB0B0…0b0b`. Fund both with USDC via `set_erc20_balance`, approve receipt.
4. ActorA `FxReceiptUSDC.deposit(1, ActorA)` (1 wei).
5. Read state: totalSupply=1, totalAssets=1, ActorA balance = 1 share. (tx `0xfb3f6918…3a99`)
6. ActorA donates 1e9 raw USDC directly to wrapper via `USDC.transfer(wrapper, 1e9)`. (tx `0xcd86677d…b5f5`)
7. Re-read `previewDeposit(1e9)` from wrapper.

**Observation (operation IDs)**:

| Step | Value |
|---|---|
| Pre-donation `previewDeposit(1e9)` | `0x3b9aca00 = 1e9` shares |
| Post-donation `previewDeposit(1e9)` | `0x3b9aca00 = 1e9` shares (UNCHANGED) |
| Post-donation `USDC.balanceOf(wrapper)` | `0x3b9aca00 = 1e9` (donation parked) |
| Post-donation `wrapper.totalAssets()` | `0x5c161a4894002` (unchanged — reads Morpho, not wrapper balance) |

**Why this works**: `FxReceipt.totalAssets()` is OVERRIDDEN at `FxReceipt.sol:66-68`:

```solidity
function totalAssets() public view override returns (uint256) {
    return MORPHO.expectedSupplyAssets(_marketParams, address(this));
}
```

It reads Morpho's view of the wrapper's supply position, NOT `asset.balanceOf(address(this))`. The classical ERC-4626 inflation attack assumes `totalAssets()` is sensitive to direct asset transfers. Here, donations to the wrapper sit as dead dust — they do not affect share pricing.

**Verdict tag**: **DISPUTED** (direct-donation variant).

**Severity revision**: The defensive pass's R1 should be downgraded from "Medium → potentially High" to **Informational (no mechanism)** — the specific attack vector named is mechanically inoperative.

**However — NEW-FINDING variant**: The same vulnerability class IS reachable via a *Morpho-side donation*. An attacker can call `MORPHO.supply(M2_params, donation_amount, 0, wrapper, "")` — anyone can supply on behalf of anyone in Morpho Blue. This *does* increase the wrapper's `expectedSupplyAssets` (Morpho mints shares to the wrapper, inflating its supply position).

Analytical math for the Morpho-side variant (verified by hand against `SharesMathLib`):

Setup with `_decimalsOffset=0` (OZ default — confirmed by reading wrapper):
- ActorA `deposit(1)` → wrapper deposits 1 wei into Morpho. Morpho `VIRTUAL_SHARES=1e6`, `VIRTUAL_ASSETS=1`. Wrapper position: supplyShares = `1 * (0 + 1e6) / (0 + 1) = 1e6`. wrapper totalSupply (ERC20) = 1, totalAssets (Morpho view) = 1.
- ActorA "donates" `MORPHO.supply(params, 1e9, 0, wrapper, "")`. Morpho mints to wrapper: `1e9 * (1e6 + 1e6) / (1 + 1) = 1e15` Morpho shares. Wrapper position now: supplyShares ≈ `1e6 + 1e15`. Wrapper totalAssets() now reads ≈ `(1e6+1e15) * (1+1e9+1) / (1e6+1e15+1e6) ≈ 1e9+1`.
- ActorB `deposit(V)` for `V = 1e6` (1 USDC). Shares minted: `V * (totalSupply+1) / (totalAssets+1) = 1e6 * 2 / (1e9+2) = 0` (integer division → 0).
- ActorB receives 0 shares for 1 USDC. ActorA still holds the only 1 share, representing the entire pool `≈ 1e9+1e6+1` assets. ActorA `redeem(1)` recovers everything; net profit = ActorB's full deposit minus 1 wei.

**The vulnerability class is real; the report's described mechanism is not.** The mitigation (`_decimalsOffset() returns 6`) still defends both variants, so the recommended fix is unchanged.

**Severity revision (NEW-FINDING)**: Medium (same as defensive pass intent). Window opens at deploy time and stays open until the wrapper has nontrivial scale. The threshold for victim-rounds-to-0 is `V < (D+2)/2`, so attacker burns capital `D > 2V` to extract `V`. Capital-efficient against small/aggregator deposits, less so against whales. Critical detail: the defensive pass's recommended fix (`_decimalsOffset() returns 6`) DOES defend, because it makes the rounding threshold `1e6+1e6` larger — but the report's reproducer (forge test: "donate 1e9 USDC directly to wrapper") would FALSELY GREEN if literally implemented because the donation has no effect. Update the forge test to donate via `MORPHO.supply(params, 1e9, 0, wrapper, "")`.

---

## Item 2: Production-oracle delta — RedStone calldata-tail revert

**Hypothesis (defensive pass)**: Production oracle path (Pyth + RedStone) reverts when called without a signed RedStone payload appended; staged 1e36 mock hides this. Codex Patch #2 should catch the revert and mark deposit Stranded.

**Reproducer**:
1. Confirm mocks installed: `MorphoOracleAdapterM2.price()` returns `0x0…604be73d…` (= 0.5e36, the S3 crash mock — currently installed on the snapshot, not the 1e36 from S1/S2).
2. Call `FxOracle.getMid(USDC, MockEURC)` directly to confirm the production-path revert.

**Observation (operation IDs)**:

| Step | Result |
|---|---|
| `MorphoOracleAdapterM2.price()` (mock active) | Returns `0x0000…604be73de4838ad9a5cf8800000000` = 0.5e36. (operation `e1b2d33e-18bc-4890-8750-ebc6a0651371`) |
| `FxOracle.getMid(USDC, MockEURC)` directly (production path) | Reverted (status=false). (operation `be5ac693-9f11-451f-93c9-9f7ff413b4ca`) |
| Error path | FxOracle self-staticcall to `getMidFromPyth` → call to Pyth proxy `0x23f0…7509` → delegatecall impl `0x36825bf3…e320` → revert (Pyth feed unknown for MockEURC OR stale on fork). Try/catch in `getMid` falls through to `_getMidFromRedstone` → reverts (no RedStone payload in msg.data). |

**Adversarial scoping refinement that DISPUTES the defensive pass's framing**:

The defensive pass framed RedStone-revert as a "production-oracle delta" affecting "S1/S2/S3/S5 PASS rows". On code re-read this is **too broad**. The actual reachability map:

| Path called by `executeDeposit→Registry.<fn>→Morpho.<fn>` | Calls oracle? | Affected by production-oracle delta? |
|---|---|---|
| `Registry.supply()` → `Morpho.supply()` | **No** — supply only `_accrueInterest`s; accrueInterest calls IRM, not oracle | **No** |
| `Registry.supplyCollateral()` → `Morpho.supplyCollateral()` | **No** | **No** |
| `Registry.borrow()` | Blocked by `onBehalf != msg.sender` (receiver becomes msg.sender) | N/A — unreachable from receiver |
| `Registry.withdraw()` (with health check) | Same gating | N/A |
| `Registry.repay()` | **No** | **No** |
| `FxLiquidator` paths | **Yes — `Morpho.liquidate` reads `IOracle.price()`** | **Yes** |

For `executeDeposit` whose normal hubCalldata is a `supply` or `supplyCollateral` call, the production-oracle delta does NOT trigger. Codex Patch #2's deposit-stranded handling is NOT exercised by oracle reverts on the supply path.

The production-oracle delta IS exercised by liquidations. R7's "operational, not security" classification stands for the deposit pipeline; for the liquidation pipeline it should be tightened to: **liquidations require an active Pyth payload in the same tx, and FxLiquidator currently does not call `Pyth.updatePriceFeeds` before invoking Morpho — a liquidator with a stale Pyth feed will revert at oracle read.** This isn't a vulnerability per se, but it is a keeper-bot UX gap.

**Verdict tag**: **CONFIRMED** with sharper scope. Defensive pass's R7 classification stands, but the framing in §Methodology→Production-oracle delta overstates the delta as affecting "S1/S2/S3/S5". Only S3 (liquidation) is genuinely affected. S1/S2/S5 traverse supply paths which never call oracle.

**Severity revision**: R7 stays Low. Add operational note: liquidation keepers MUST include a fresh Pyth payload + RedStone signed payload in the same tx as `FxLiquidator.liquidate`. Consider exposing `liquidateWithUpdate(payload, ...)` helper on FxLiquidator.

---

## Item 3: R5 — uint96 truncation walkthrough

**Hypothesis (defensive pass)**: `uint96(minted)` / `uint96(leftover)` truncation at `FxHubMessageReceiver.sol:141, 154` is gated by Circle's mint caps; rated Low.

**Reproducer (analytical, because Tenderly Pro write quota was exhausted before this probe; assertions verified against source not chain state)**:

For `mintedAmount = 2^96` (`0x1000000000000000000000000`), `uint96(2^96) = 0` (Solidity 0.8.x truncating cast does NOT revert).

Three paths walked:

**Path (a) — full consume (Executed branch, line 141)**:
- Registry consumes all `minted=2^96` of USDC. `ok=true`, `leftover=0`. Branch: `if (ok && leftover == 0)`.
- Store: `amount: uint96(minted) = 0`. State=`Executed`. Event `DepositExecuted(nonce, beneficiary, minted)` emitted with the ACCURATE `uint256 minted`.
- Outcome: cosmetic only — USDC reached Morpho via Registry, no funds at risk. The stored `_deposits[nonce].amount=0` matters only for off-chain accounting (the event has the correct value).

**Path (b) — zero consume (Stranded branch, line 154) — THE REAL HAZARD**:
- Registry call reverts OR succeeds without pulling any USDC. `ok=false` OR `leftover=minted=2^96`.
- Store: `stranded = ok ? uint96(leftover) : uint96(minted) = 0`. State=`Stranded`. `d.amount = 0`.
- The 2^96 raw USDC sits on the receiver's balance.
- Beneficiary calls `sweepStrandedDeposit(nonce)` after 24h grace → executes `USDC.safeTransfer(d.beneficiary, d.amount)` = `transfer(beneficiary, 0)`. **Beneficiary receives 0**. The 2^96 USDC is permanently stuck on the receiver under the existing recovery mechanism. Recoverable only by off-chain governance + new code (the contract has no admin function to sweep arbitrary token balances).

**Path (c) — partial consume**:
- `ok=true`, `leftover ∈ (0, minted)`. `uint96(leftover)` truncates if `leftover > 2^96-1`. For `leftover = 2^96 - 1` exactly, no truncation. For `leftover ≥ 2^96`, truncates to `leftover mod 2^96`.
- The "stranded" amount stored is incorrect; the actual USDC sitting on receiver is the true `leftover`. Same recovery gap.

**Verdict tag**: **CONFIRMED Low**, with mechanism clarification that defensive pass under-stated.

Defensive pass calls this a Low "Circle-gated" issue but does NOT mention that path (b) leaves funds **permanently inaccessible via the normal sweep mechanism**. The cast is not "cosmetic" — it severs the only intended recovery path for a stranded deposit that overflows uint96. This deserves explicit note in the mitigation: `SafeCast.toUint96` reverts the entire `executeDeposit` rather than silently storing 0, which is the correct behavior — Circle's relayer can then retry or escalate.

**Threshold reachability**: 2^96 raw USDC = ~7.92e22 USDC tokens (since USDC is 6-decimal: 7.92e28 / 1e6 = 7.92e22). Total USDC supply ~5e10. So this requires a per-CCTP-message mint of ~1.6e12× the entire USDC supply. **Unreachable in practice.** R5 stays Low.

However: the mitigation argument flips. Defensive pass says "wrap in SafeCast as defence-in-depth" — that framing implies marginal value. The real argument is: SafeCast is the difference between "Circle relayer can retry" (good) and "USDC permanently bricked on receiver, only off-chain remediation" (bad). Even at unreachable thresholds, the failure mode is qualitatively different. Recommend the fix more emphatically than v1.2.1 does.

**Severity revision**: R5 stays Low, but reword mitigation rationale.

---

## Item 4: Q8 — liquidation ordering dependence

**Verdict tag**: **BLOCKED — Tenderly Pro write quota exhausted before this probe could be primed.**

**Setup attempt**: Item 4 requires (1) priming 10 underwater positions via `supplyCollateral` + `borrow`, each as a different actor (`set_erc20_balance` + `send_vnet_transaction × 2N`), (2) `tenderly_setCode` swap on the M2 oracle to push positions underwater, (3) sub-snapshot, (4) 10× `Morpho.liquidate` in order A, (5) `revert_vnet` to sub-snapshot, (6) 10× `Morpho.liquidate` in order B, (7) compare per-position recovered profit. Even at N=3 this is ~10 write-quota operations.

The quota counter on the active vnet hit its ceiling during Item 1 (R1 reset + funding + 3 send_vnet_transaction calls). Subsequent `set_erc20_balance`, `send_vnet_transaction`, `revert_vnet`, and `set_storage_at` all returned:

```
{"code":-32004,"message":"You've reached the quota limit for your current plan. Upgrade your plan in the dashboard or contact support to continue."}
```

(Visible in operation logs; not reproduced here to keep the report under 25k tokens.)

**Implication for the standing question**: This adversarial pass cannot close Q8 either way. The question stays OPEN.

**Recommendation**: Re-run this probe in a fresh vnet (post-quota-reset, or on a higher-tier plan) with N=3 minimum, N=10 if budget allows. The expected outcome from Morpho Blue's design is that bad-debt socialization is order-INDEPENDENT (haircuts are applied to remaining suppliers proportionally per liquidation, but the seizure math each liquidator sees doesn't depend on prior bad-debt events in the same block AS LONG AS the oracle price is the same). The MEV vector — front-running specific liquidations because they're cheaper or more profitable than others — is real but is a property of bonus economics (`LIF = WAD / (WAD - α(WAD-lltv))`, constant per market), not ordering. Front-running for liquidator-set ordering DOES affect WHO captures the bonus, but per-position-profit is invariant across orderings.

**Anticipated verdict (analytical only, not measured)**: Probably DISPUTED at the Δ-profit-per-position level, but ESCALATED if framing is "who gets to liquidate first wins the bonus" (MEV ordering). The Q is malformed; defensive pass's wording ("realized haircut per supplier") conflates two different concerns.

---

## Item 5: §S7b extension — accrueInterest-side uint128 saturation

**Verdict tag**: **BLOCKED** — `simulate_vnet_transaction.state_overrides.stateDiff` is silently ignored by Tenderly VNet API, and `set_storage_at` (the working alternative used by defensive pass S7a/S7b) is quota-blocked.

**Probe attempted**: 
1. Compute slot 0 of `market[M2_id]` = `0x4ed92523f783d319ad2de283ec4c4fb751d0b5592c2e6506dd16f3108bf985a3` (matches defensive pass).
2. Apply `state_overrides`:
   - slot 0 → `0xff…ff` (totalSupplyAssets=2^128-1, totalSupplyShares=2^128-1)
   - slot 1 → `0x40…40` (totalBorrowAssets=2^126, totalBorrowShares=2^126)
   - slot 2 → `0x…6553f100` (lastUpdate ≈ 1 year ago)
3. Simulate `Morpho.accrueInterest(M2_params)`. Expect Panic(0x11) at `Morpho.sol:491` (`totalSupplyAssets += interest.toUint128()`).

**Observation**:

Simulate returned `status: true` (success) with 0 state changes. Re-running with simpler overrides confirms: state_overrides for storage on Morpho are NOT being applied. Verified by simulating a read of `market(M2_id)` with `stateDiff` setting slot 0 to `0xdeadbeefcafef00d…` — the read returned the BASELINE values, not the override. operation IDs `432c125d-4b8c-4232-8948-d60423e32949`, `d33ac83c-e4cc-4f98-b485-fc2e26e45a2e`, `16a47748-3ee0-4067-bae6-d2a827e4ec17`, `58f8cae8-8397-4028-aab1-1677ab1d4652`.

The `state` (full replacement) variant was attempted instead of `stateDiff`; MCP rejected it as an invalid additional property — only `stateDiff` is supported by the wrapper. Defensive pass S7a/S7b worked because it used PERSISTENT `tenderly_setStorageAt` then read the actual modified state, NOT state_overrides. The persistent path is quota-locked for this session.

**Analytical fallback (NOT measured, recorded only)**:

`_accrueInterest` (lines 483-509 of `Morpho.sol`) does:
```
interest = totalBorrowAssets * wTaylorCompounded(rate * elapsed)
totalBorrowAssets += interest.toUint128()  // line 490
totalSupplyAssets += interest.toUint128()  // line 491
```

Both `+=` operations are in 0.8.19 default-checked context (no `unchecked {}` wrapping). With `totalSupplyAssets = 2^128-1`, line 491 panics with Panic(0x11) — identical revert mode to S7a/S7b. The code path is IDENTICAL pattern; defensive pass's "inferred Panic(0x11)" claim is structurally sound.

The unmeasured branch is: what if `interest.toUint128()` overflows BEFORE the `+=`? That is, what if `interest > 2^128`? `toUint128` in `UtilsLib` (Morpho) reverts on overflow. With totalBorrowAssets at 2^126 and a 1-year elapsed at 25% APR-ish IrmMock, interest ≈ 0.28 × 2^126 ≈ 2.4e37 < 2^128. So toUint128 succeeds, the `+=` panics. **Cannot be measured here.** Recommend re-running this probe when write quota recovers.

**Verdict tag**: **BLOCKED** (cannot be measured this session). Confidence in "same Panic(0x11) on accrueInterest path" is ~95% from code identity but is not empirical. Carry this as an open follow-up.

---

## Item 6: 18-decimal S7 variant

**Verdict tag**: **BLOCKED** — requires (a) deploying `MockBRLA(18)`, (b) creating M3 market, (c) supplying small, (d) `set_storage_at` to push `totalSupplyShares=MAX`, (e) simulating `supply(1)`. Steps (a)–(d) are state-mutating; write quota blocks all of them.

Carry as deferred. Same architectural argument as Item 5: code path is identical regardless of underlying token decimals (`shares.toUint128()` and `assets.toUint128()` are decimal-agnostic). Expected behavior: same Panic(0x11).

---

## Anything else you noticed (new findings beyond the standing six)

**NEW-FINDING #A — `FxReceipt.totalAssets()` blocks the classical inflation attack but the codebase docs don't celebrate this** : The wrapper's `totalAssets()` override (reading `MORPHO.expectedSupplyAssets` instead of `asset.balanceOf(this)`) is a strong defence-in-depth against the standard ERC-4626 inflation pattern. The codebase's `FxReceipt.sol` doesn't comment on this design choice; defensive pass R1 missed it. Recommend an explicit `/// @dev Inflation-attack resistance: totalAssets reads Morpho's expectedSupplyAssets, NOT the wrapper's asset balance. Direct-donation inflation is therefore defeated; the wrapper is still vulnerable to Morpho-side donation inflation against fresh markets.` comment in the wrapper source.

**NEW-FINDING #B — `_ensureApproval` on `FxHubMessageReceiver:190-196` is dead code**: The function exists but is never called by any function in `FxHubMessageReceiver.sol`. `executeDeposit` uses `USDC.forceApprove(MARKET_REGISTRY, minted)` directly on line 122, not the helper. Suggest removing or wiring up.

**NEW-FINDING #C — receiver currently holds 450M USDC stranded from S5 priming**: Read `USDC.balanceOf(0x365de300…4362) = 0x019945ca262000 = 450,000,000,000,000` (450M raw = 450M USDC) on the current vnet state. This is leftover from the S5 partial-pull tx and the S5a stranded deposits, plus the donation I made in Item 1. Per the audit setup, those nonces should be sweepable after the grace period; the deposit-state mapping retains the records. Not a vulnerability — just a sanity-check that the snapshot state is correctly populated post-S5.

**NEW-FINDING #D — Tenderly Pro `simulate_vnet_transaction.state_overrides.stateDiff` is broken or undocumented**: The MCP wrapper accepts the parameter but appears to drop it before the call reaches the vnet RPC. Verified across 4 simulations with deliberately-divergent override values; all returned baseline storage on subsequent reads. This is a TOOLING bug (Tenderly side or MCP shim side), not a fx-Telaraña finding. If true, it limits the auditability of state-dependent paths to whatever can be reached via persistent `setStorageAt` — exactly the surface that hits write quota first. Recommend filing with Tenderly + MCP server maintainers.

---

## Sign-off

- Snapshots taken/reverted: 
  - Root snapshot `0x681228b28ba16c12868bf49e1af8acad858cbac9c50e3a7f650c315edadafa50` is the working state across this session.
  - Branched once via Item 1's `set_storage_at` reset of `FxReceiptUSDC` totalSupply + Morpho `position[M2][wrapper]` + Morpho `market[M2].slot0`. Revert was attempted (`0xe85b12209ef2abc7a9ec170c07cb4df6bdee958af484ef037eedf56c1be629af`) but rate-limited; the vnet now carries the Item 1 mutations (1B donation to wrapper, 1 wei deposit by ActorA, zeroed slots). **NOT a clean state for re-runs**. Future re-runs should re-snapshot from a fresh `fork_vnet`.
- TUs consumed (estimate): unknown; Tenderly's quota counter is not exposed via MCP. Quota was already partially-consumed at session start (defensive pass and prior runs). Item 1's write operations (~6 state mutations) plus reads (~15) plus simulations (~10) appears to have exhausted the per-account write budget for the rolling window.
- Concordance caveat: this reviewer and first-pass author are both Claude Opus 4.7. Independent-model review (Codex) was attempted three times and blocked by OpenAI's content moderation gate plus sandbox RPC isolation. Recommend re-running this audit on Anthropic's eventual Codex-equivalent or paying for OpenAI Trusted Access for Cyber. The concordance bias risk: we may share the same blind spots in static-analysis or the same training-prior assumptions about Morpho/ERC-4626 mechanics. Item 1's empirical disproof of R1's direct-donation mechanism is the strongest counter-evidence that this pass was genuinely adversarial — but a different model architecture would surface different blind spots.
- Adversarial verdict: **PASS_WITH_FOLLOWUPS**
  - 2 confirmed (Item 2, Item 3 — both with mechanism refinements that strengthen, not weaken, the fix recommendations)
  - 1 disputed (Item 1 — R1's named mechanism is inoperative; vulnerability class still exists via a different route)
  - 3 blocked (Items 4, 5, 6 — Tenderly Pro write quota exhausted; recommend re-running on a fresh vnet or upgraded plan)
- Recommended next action: 

  1. **Update R1 immediately**: rewrite the R1 narrative in `AUDIT_REPORT.md` to specify Morpho-side donation, NOT direct-donation. The current language ("donate USDC directly to wrapper") would mislead a forge test that follows the spec — the test would falsely green. Update the recommended check to `MORPHO.supply(params, 1e9, 0, wrapper, "")` for the donation step. Implementation mitigation (`_decimalsOffset() returns 6`) is unchanged.

  2. **Wrap the uint96 cast in SafeCast as a hard requirement, not "defence-in-depth"**: the path (b) failure mode permanently bricks USDC on the receiver via the only intended recovery mechanism. Reword R5's mitigation rationale.

  3. **Re-run Items 4, 5, 6 on a fresh vnet (or upgraded Tenderly plan)**: snapshot from clean fork, prime via the existing staging-artefacts table, then run the three blocked probes serially. Estimate: 3–4 hours including vnet setup.

  4. **File Tenderly bug**: `simulate_vnet_transaction.state_overrides.stateDiff` is being silently dropped. If this is fixable on the Tenderly side, future audits can do much more with read-only quota.

  5. **Surface NEW-FINDING #A in the codebase**: add the inflation-attack-resistance comment to `FxReceipt.sol`, explaining that `totalAssets()` is deliberately overridden to break the direct-donation pattern.

  6. **Delete NEW-FINDING #B dead code**: `_ensureApproval` in `FxHubMessageReceiver` is unused.

