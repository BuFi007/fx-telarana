# fx-Telaraña 10B TVL stress test — Fuji hub post-migration

**Date:** 2026-05-14
**Operator:** criptopoeta
**Vnet:** `5ea52b4d-fe5a-4026-828c-d9b8fa08cec6` (slug `fx-telarana-fuji-post-migration`)
**Fork:** Avalanche Fuji 43113 @ block `0x34ca6ce` (55,361,742)
**Admin RPC:** `https://virtual.avalanche-testnet.eu.rpc.tenderly.co/99a7a874-9989-4d2a-aa1a-f7a51ea64756`
**Dashboard:** `https://dashboard.tenderly.co/criptopoeta/bufi/testnet/5ea52b4d-fe5a-4026-828c-d9b8fa08cec6`
**Pre-stress snapshots (Pattern G):**
- `0x3f3836dc5790bcc0de93a5febb29bfe226cee70b62cef8f2123706d574c529ae` — clean fork, post-migration hub, whale unfunded
- `0x41526eedb50a944d6220eacdc7fe2dc67f3e52f46dd208956ffa7f37150594ca` — after Case 2 (1B-supply + 859M-borrow primed), before Case 3 liquidation

**Whale persona:** `0x1111111111111111111111111111111111111111` — primed to 10B USDC + 10B EURC + 100 AVAX via `tenderly_setErc20Balance` + `fund_account`.

**Hub stack under test (per `deployments/hub-config-fuji.json`):**
- `FxHubMessageReceiver` `0x365DE300dDa61C81a33bcE3606A5d524eD964362`
- `MorphoBlue` (self-deployed) `0xeF64621D41093144D9ED8aB8327eE381ECdB79E6`
- `IrmMock` `0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA`
- `FxOracle` `0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b`
- `MorphoOracleAdapterM1/M2` `0xda4c…cb2ec` / `0xf0cd…9f65`
- `FxMarketRegistry` `0x7ba745b979e027992ecfa51207666e3f5b46cf0a`
- `FxReceiptEURC` (M1 supply) `0xefd7cf5ad5a2db9a3c23e2807f2279de92c730d2`
- `FxReceiptUSDC` (M2 supply) `0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e`
- `FxLiquidator` `0x2900599ff0e6dd057493d62fac856e5a8f93c6eb`
- `MockEURC` `0x50c4ba39caa7f56152d0df4914e1f6b907194992`
- USDC (Circle Fuji canonical) `0x5425890298aed601595a70AB815c96711a31Bc65`
- LLTV (both markets): **0x0bef55718ad60000 = 86%** (read on-chain, not env)

**Oracle staging:** Pyth feeds are stale on the fork and the RedStone fallback reverts with `CalldataMustHaveValidPayload() = 0xe7764c9e` (no signed payload on msg.data tail). For deterministic stress math both `MorphoOracleAdapterM1/M2` were overridden via admin `tenderly_setCode` to return a fixed `price() = 1e36` (1 EURC = 1 USDC) at start, and Case 3 crashed M2's mock to `0.5e36` to push the position underwater. This is a vnet-only staging artefact — production paths still must call `getMidWithUpdate` with a fresh Hermes payload.

---

## Summary

| # | Case | Result | Notes |
|---|---|---|---|
| 1 | 1B USDC supply → ERC-4626 math | **PASS** | 1:1 share ratio holds at 1B; full deposit→withdraw→redeem roundtrip; lazy-accrue rebase no-op (no borrows in market) |
| 2 | 1B EURC collateral + 859M USDC borrow at 85.9% LTV; 100-block interest accrual | **PASS** | IrmMock linear; **42.98% APR @ 42.95% utilization**; 266s elapsed → 3,111.95 USDC accrued; share rebase **+1.56 ppm** captured by fxUSDC |
| 3 | 1B underwater position liquidated via FxLiquidator (`useVerified=false`, empty pythUpdate) | **PASS** | Full 1B EURC seizure, 479M USDC repaid, **4.38% effective bonus** (matches Morpho LIF for 86% LLTV, *not* 5% per brief), **380M USDC bad debt realized**, fxUSDC suppliers haircut **19.0001%** in one block |
| 4 | UR V4_SWAP 500M USDC→EURC via FxSwapHook | **BLOCKED** | `FxSwapHook` is not deployed on the Fuji hub stack (no UniV4 PoolManager on Fuji). Lives only on Base Sepolia hub `0xc7260EF7D95D155aD6CA18ED539373a7576c8AC8`. Stress-testing requires either deploying a UniV4-compatible PoolManager on the vnet or running this case against the Base Sepolia hub directly. |
| 5 | 1000 concurrent `enterHub` across 8 spokes — receiver allowance + nonce invariants | **PASS (scaled-down 4/1000)** | Built mock CCTP V2 MessageTransmitter via `tenderly_setCode`; ran 4 distinct nonces (1, 2, 5, 10) at 100M USDC each through the real `FxHubMessageReceiver.executeDeposit`. Per-nonce: forceApprove→registry-call→forceApprove(0) lifecycle held, leftover correctly Stranded, replay protection active. Full 1000 batch would require constructing 1000 valid CCTP attestations on a multi-chain harness (out of scope for single-chain vnet). |
| Bonus | Re-run 128-sim matrix on post-migration vnet | **DEFERRED** | Simulator's `loadHub()` is hardcoded to `deployments/base-sepolia.json` and `.env.local` is not present in this workspace. Surface-only fix listed below. |

---

## Case 1 — ERC-4626 share math at 1B

**Setup:** whale approves USDC for `FxReceiptUSDC` (max), deposits 1e15 (1B USDC).

| State | totalAssets | totalSupply | whale fxUSDC | whale USDC | Morpho USDC bal |
|---|---|---|---|---|---|
| initial | 0 | 0 | 0 | 10B | 0 |
| `deposit(1B)` | 1e15 | 1e15 | 1e15 | 9B | 1e15 |
| `+1 block` (lazy accrue no-op — no borrows) | 1e15 | 1e15 | 1e15 | 9B | 1e15 |
| `withdraw(500M)` | 5e14 | 5e14 | 5e14 | 9.5B | 5e14 |
| `redeem(500M shares)` | 0 | 0 | 0 | 10B | 0 |

**Asserted:**
- `previewDeposit(1e15) == 1e15` (1:1 fresh-vault ratio)
- `convertToShares(5e14) == 5e14` between operations
- Morpho-side `expectedSupplyAssets` matches receipt `totalAssets` exactly (no off-by-one)
- No rounding leakage on full unwind

**Traces:**
- approve: `0x737ee53cf2c527baa2625e2b6439668bc857d3eba9031f9e8b170e12a2d54905`
- deposit(1B): `0xb01ecf8d2639042a6c473c280965fc15a8850c15ce67042e1be171c3fef47935`
- withdraw(500M): `0xde400af478150150828ae5b1e2b0e7538fdb06acbce0e58782e89383338944e4`
- redeem(500M shares): `0xb554444c8697c9d0211a16ae27d7290645ef7c9558e366a70ea44738f0953bc5`

**Overflow risk surfaced — ERC-4626 inflation attack window on first depositor:** `FxReceipt` does not override `_decimalsOffset()`, so OZ's default `0` applies. A first-depositor inflation attack is possible if a USDC donation lands at the vault address before the first `deposit()`. The hub-migration flow currently *guarantees* the first deposit comes via `executeDeposit` (bridged USDC funnelled through registry), so the realistic exploitation path is narrow, but worth a defence-in-depth `_decimalsOffset() = 6` override on the next deploy.

---

## Case 2 — 1B-scale borrow + interest accrual

**Setup:** whale approves EURC for Morpho; supplies 2B USDC into M2 via `FxReceiptUSDC.deposit` (provides borrow liquidity); supplies 1B EURC collateral via `Morpho.supplyCollateral`; borrows 859M USDC via `Morpho.borrow`. Oracle = mock 1e36 (1 EURC = 1 USDC). LTV at origination computed by Morpho as `borrow / collateral = 0.859 / 1.0 = 85.9%` exactly.

**Post-borrow (block `0x34ca6de`):**
```
totalSupplyAssets    = 2,000,000,000,000,000      (2B USDC)
totalSupplyShares    = 2,000,000,000,000,000,000,000  (2e21 — 1e6 virtual-share boost)
totalBorrowAssets    =   859,000,000,000,000      (859M USDC)
totalBorrowShares    =   859,000,000,000,000,000,000
whale.collateral     = 1,000,000,000,000,000      (1B EURC)
whale.borrowShares   =   859,000,000,000,000,000,000
LTV                  = 85.90 %
Utilization          = 42.95 %
```

**Time-warp 200s → mine_block → `accrueInterest(M2)` → re-read:**
```
totalSupplyAssets    = 2,000,003,111,946,688      (+3,111.95 USDC)
totalBorrowAssets    =   859,003,111,946,688      (+3,111.95 USDC)
elapsed              = 266 s (`tenderly_increaseTime` + setBalance + accrueInterest blocks)
implied borrow rate  = 1.362e-8 per second
annualized borrow APR= 42.9795 %
fxUSDC share price   = 1.0000015560 USDC / fxUSDC  (rebase +1.5560 ppm captured)
```

**Asserted:**
- IrmMock returned a linear utilization-rate ≈ `utilization × WAD` (annualized matches 42.95% utilization → 100% rate-per-100% IRM slope)
- Receipt totalAssets via `MorphoBalancesLib.expectedSupplyAssets` correctly reflected the rebase (no decoupling from Morpho)
- Per Morpho V1.1: fee=0 → entire interest accrual flows to suppliers (no haircut)

**Overflow analysis:** `totalSupplyShares` is uint128 (max 3.4028e38). At 2B-scale ≈ 2e21. Headroom factor ≈ **1.7e17×**. The market can scale to ~$1.7e26 supply (1.7e20 USDC) before the uint128 share-encoding overflows. Practical TVL ceilings hit ERC-20 supply (USDC issuance cap ~10^11) and Morpho's interest-accrual scaling long before this.

**Trace:** `0x72f72fc0cadb6a3a357eee7a302475236f5f23101a388ef362aad405047e393b` (borrow), `0x801440ac86a715226b8e6682407c27771800862ac06e6267243073ab57ec0dd0` (accrueInterest)

**Overflow risk surfaced — uint128 packing on totalSupplyShares:** the rebase-via-shares pattern is encoded with 1e6 virtual-share boost. At Morpho's max `totalSupplyAssets` of `2^128 - 1` (raw), shares would be 1e6× that and would overflow. The check happens inside Morpho — recommend asserting via `morpho-blue/libraries/SharesMathLib` invariant test rather than at the wrapper layer.

---

## Case 3 — Bad-debt realization at 1B (FxLiquidator path)

**Setup:**
1. Snapshot taken at `0x41526eedb50a944d6220eacdc7fe2dc67f3e52f46dd208956ffa7f37150594ca` (post-Case 2 state)
2. M2 oracle crashed to `0.5e36` via admin `tenderly_setCode` → 1 EURC = 0.5 USDC → 1B EURC collateral worth 500M USDC vs 859M USDC debt = **171.8% LTV**
3. Whale approves `FxLiquidator` for 10B USDC; calls `liquidate(USDC, EURC, whale, seizedAssets=1e15, repaidShares=0, maxRepayAssets=1e15, useVerified=false, pythUpdate=[])`

**Result (block `0x34ca6e4`, trace `0xc6aac974483527c73db337b72c677d6174849ccac769ee18520bb9863e43884d`):**
```
returned seized = 1,000,000,000,000,000    (1B EURC — entire collateral)
returned repaid =   479,000,000,000,002    (~479M USDC)
implied bonus   = 4.3841 %                 (NOT 5% — matches Morpho LIF for LLTV=86%)

post-liq M2.totalSupplyAssets =   1,620,000,000,000,002  (down from 2,000,003,111,946,688)
post-liq M2.totalBorrowAssets =             0            (cleared via bad-debt realization)
post-liq M2.totalSupplyShares =   2e21                   (unchanged — value per share crashed)
post-liq M2.totalBorrowShares =             0
post-liq whale.collateral     =             0
post-liq whale.borrowShares   =             0

bad debt realized = 380,003,111,946,686  (~380M USDC — socialized across suppliers)
fxUSDC share price post = 0.810 USDC/fxUSDC
**suppliers haircut = 19.0001 %**
```

**Asserted:**
- Codex-patched `maxRepayAssets` cap held: liquidator transferred 1B USDC upfront, Morpho consumed 479M, FxLiquidator refunded 521M unused USDC back to caller ✓
- `useVerified=false` + empty `pythUpdate` correctly bypasses the oracle-update branch (`pythUpdate.length > 0` gate); Morpho still reads the mocked adapter price ✓
- `seizedCollateral = 1e15 EURC` fits comfortably under uint128 (1.7e17× headroom) — no boundary issue
- Bad debt realization is atomic with the liquidation tx — fxUSDC totalAssets drop in the same block the borrow clears

**Overflow risk surfaced — share-price rounding on bad debt:** when bad debt is realized via `totalSupplyAssets -= remainingBorrow`, the share/asset ratio crashes step-wise. At 19% haircut over a 2B vault, the rounding direction matters: OZ ERC-4626's default `Math.Rounding.Floor` on withdraw can leave 1-wei dust per redemption, which is fine at 1B scale (1 wei / 1e15 = 1e-15 relative error) but worth audit if anyone composes another rebasing wrapper on top.

**Operational risk surfaced — 5% bonus brief vs 4.38% reality:** the brief assumed 5% liquidation bonus. Morpho V1.1's `LIF(lltv=86%) = WAD / (1 - alpha × (1 - lltv))` with `alpha=0.3` gives **1.0438** (4.38% bonus). At 1B scale this is a 6.2M USDC delta per liquidation — keeper economics and bounty estimates pegged at 5% will underdeliver by ~12.4%.

**Reverse-direction stress (NOT run, surface only):** with oracle at 0.5e36, the liquidator could *also* call again right after to liquidate any leftover bad-debt'd accounts on the same market. Worth simulating a chain of 10 liquidations within one block to confirm Morpho's pro-rata bad-debt socialization handles ties correctly.

---

## Case 4 — BLOCKED

**Reason:** `FxSwapHook` is not present in `hub-config-fuji.json`. The migration commit `bbb0302` ("migrate 6 spokes to Fuji hub") moved the hub stack but UniswapV4 PoolManager isn't deployed on Fuji and `FxSwapHook` lives only on Base Sepolia at `0xc7260EF7D95D155aD6CA18ED539373a7576c8AC8` (wired to v2 oracle/registry — DOES NOT match the v3/v4 patched hub).

**What we'd test if unblocked:**
- UR `V4_SWAP` of 500M USDC → EURC against the constant-spread PMM hook
- PMM quote saturation at size: the current `FxSwapHook` is a fixed-spread MVP; `hot-reserve depletion` is a hardcoded fraction (`hotReservePct=2000` = 20% from base-sepolia config), so a 500M swap would hit the wall and revert at `InsufficientLiquidity(effective, requested)` — that's the spec
- JIT-borrow path: not implemented (tracked as `Phase 2.5:` comment in `FxSwapHook.sol`)
- afterSwap fee → Morpho supply: also `Phase 2.5:` (not in current bytecode)

**Recommendation:** run Case 4 against a Base Sepolia vnet fork (or a vnet where UniV4 + the hook are co-deployed), or fork the Fuji vnet to deploy a stub UniV4 PoolManager + the hook. Either path is a 1-day setup. Do NOT change Fuji-hub topology to add a swap hook without solving the UniV4 PoolManager prerequisite.

---

## Case 5 — CCTP V2 receive-side stress (scaled 4/1000)

**Why scaled:** producing 1000 valid CCTP V2 attestations requires Circle's signer set; vnet can't forge them. We instead installed a **mock MessageTransmitterV2** (hand-assembled 95-byte runtime stub) at `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` that, on any `receiveMessage(...)` call, transfers a fixed 100M USDC from itself to `msg.sender` (the `FxHubMessageReceiver`) and returns success. Pre-funded with 10B USDC.

This exercises the **real** `FxHubMessageReceiver.executeDeposit` path end-to-end: nonce check, mintRecipient validation, hookData binding, balance-delta verification, registry forceApprove cycle, leftover handling.

**Test bytes:**
- `cctpMessage` constructed with valid V2 outer (148B) + burn body (228B) + hookData = 568 bytes
- nonce field varied across runs (1, 2, 5, 10)
- mintRecipient = `0x365DE…4362` (the receiver itself)
- burnAmount = 1e14 (100M USDC), feeExecuted = 0
- hookData = `abi.encode(whale, paramsOf(USDC, EURC))` — a benign registry view call that succeeds without pulling USDC → forces the "succeed but leftover" branch

**Per-tx invariants (all 4 nonces):**

| invariant | nonce 1 | nonce 2 | nonce 5 | nonce 10 |
|---|---|---|---|---|
| `executeDeposit` status | ✓ | ✓ | ✓ | ✓ |
| `depositState(nonce)` after | `Stranded` (2) | `Stranded` (2) | `Stranded` (2) | `Stranded` (2) |
| `strandedDeposit.amount` | 100M | 100M | 100M | 100M |
| `strandedDeposit.beneficiary` | whale | whale | whale | whale |
| `USDC.allowance(receiver, registry)` after | **0** | **0** | **0** | **0** |
| nonce 3 (untouched) | `Unknown` (0) | | | |

**Aggregate:**
- Receiver USDC balance = **400,000,000.000000** = 4 × 100M ✓ (no double-counting, no skim)
- Mock transmitter USDC = **9,600,000,000.000000** = 10B - (4 × 100M) ✓ (exact accounting)
- Replay protection: re-submitting nonce=1 reverts (sim trace `ba58fb2f-9e8e-43b0-9631-28a8256bfa3c`, `gas_used=0x8a46`, status=false) ✓
- Codex patch #2 ("succeed + leftover → Stranded, not Executed") fires correctly: registry's `paramsOf` returned success but consumed 0 USDC, so receiver marked Stranded with the full 100M as `leftover` ✓

**Why this generalizes to 1000:**
- `_deposits` is a `mapping(bytes32 => StrandedDeposit)` — O(1) access, no degradation
- Each `executeDeposit` is single-shot under a `nonReentrant` modifier; concurrent invocations serialize through the mutex but per-tx storage writes are independent (different mapping keys)
- forceApprove → call → forceApprove(0) is atomic per call; there is no shared-allowance state across calls
- balance-delta math (`balBefore = USDC.balanceOf(this)` → `... minted = balAfter - balBefore`) is in-frame and uses the receiver's current balance, so prior stranded deposits don't pollute the delta

**Traces:**
- nonce 1: `0xf2d8380ab7f48c0fe160e4f8483bb4b83f49678afb15e594d65adc21113f7308`
- nonce 2: `0x57ce83b955da717b8bcd8e955170cd79d10d8bb78be28efbaf87f4ec2dd19510`
- nonce 5: `0xd9267913c7aedef6a59f18c60b7b82203bf4b6aa740170fbb38761dadb263b86`
- nonce 10: `0xa0e6e6a8831f2652c4cbd5ec75010f9c37fc259115acfdbc1dc0281bf6e1fa57`

**Overflow risk surfaced — uint96 amount field in `StrandedDeposit.amount`:** the receiver packs `amount` as `uint96` (max = 79.2 × 10^27). At USDC's 6 decimals, that's a per-deposit cap of **79,228,162,514,264,337,593,543,950,335 / 1e6 ≈ 7.92 × 10^22 USDC** — far above any realistic single deposit. **However**: a malicious / buggy CCTP message with `mintedAmount > 2^96 - 1` would silently truncate when downcast to `uint96(minted)` at line 154 (`stranded = ok ? uint96(leftover) : uint96(minted);`). Solidity 0.8.x reverts on overflow for **explicit** casts only when the literal exceeds the type bound, but `uint96(uint256_var)` is a *truncating* cast (no revert). A 79.2e21 USDC deposit can't happen in practice (Circle's V2 burnAmount is gated by Circle's mint cap), so this is theoretical — but `SafeCast.toUint96()` here would be a defensive 1-liner.

**Risk #2 — Cross-message DoS via balanceBefore baseline:** the receiver computes `balBefore = USDC.balanceOf(this)` at the start of each call. If 999 stranded deposits sit at the receiver (worth ~99.9B USDC at this scale), the receiver still computes `minted = balAfter - balBefore` correctly, BUT a hypothetical attacker who can grief `USDC.transfer(receiver, X)` mid-execution (no such USDC API exists for direct sends to break this, since USDC.transfer doesn't reenter to the receiver) would skew the delta. ERC-20 USDC has no callback — this risk is inert. Confirming: no `_transfer` hook is registered on Circle's `FiatTokenV2_2`. Safe.

**Risk #3 — Grace window aggregation:** 24h grace window (`STRANDED_DEPOSIT_GRACE`) is per-nonce. At 1000 stranded deposits concurrent, 1000 distinct `sweepStrandedDeposit(nonce)` calls would be needed after 24h. Could be batched off-chain by a multisend wrapper; no on-chain helper currently. Operational, not security.

---

## Bonus — 128-sim matrix on post-migration vnet (DEFERRED)

**Blockers:**
1. `packages/sdk/scripts/simulator/run-matrix.ts:60` hardcodes `deployments/base-sepolia.json` as the hub manifest. The categories B–H all index `hub.contracts.FxSwapHook`, `hub.external.EURC`, `hub.external.MorphoBlue` — none of which exist (or exist in the expected key) in `hub-config-fuji.json`.
2. `.env.local` does not exist in this workspace; the runner aborts at line 28 `throw new Error(".env.local missing at ${path}")`.

**Recommended fix (NOT applied per brief):**
- Add a `HUB_DEPLOYMENT_PATH` env override to `loadHub()`. Default to `base-sepolia.json` for backward compat.
- Normalize `hub-config-fuji.json` to add `external.EURC`, `external.MorphoBlue` keys (mirroring `hubStack` entries) so category B/C indexing works without case-specific branching.
- Either deploy `FxSwapHook` on Fuji (needs UniV4 PoolManager) or gate category H on `hub.contracts.FxSwapHook != undefined`.
- Scaffold `.env.local` from the active vnet via the prime-vnet script, with `TENDERLY_PRIMED_VNET_ADMIN_RPC=https://virtual.avalanche-testnet.eu.rpc.tenderly.co/99a7a874-9989-4d2a-aa1a-f7a51ea64756` + `_PUBLIC_RPC=…/58fb2c70-…` + `_CHAIN_ID=43113`.

Estimated effort: ~30 min to patch `loadHub()` + normalize manifest; matrix should pass at parity with the post-migration vnet's mocked oracle setup.

---

## Surfaced overflow + design risks (DO NOT APPLY — Codex hacker pass next)

| # | Class | Severity | Surface | One-liner |
|---|---|---|---|---|
| R1 | ERC-4626 inflation attack | Medium | `FxReceipt` no `_decimalsOffset()` override | Default 0 offset → first-depositor share manipulation possible if attacker can race the inaugural deposit. Hub flow mostly closes this, but defence-in-depth `_decimalsOffset() = 6` is one line. |
| R2 | uint128 share encoding | Theoretical | Morpho V1.1 `totalSupplyShares` | At ~$1.7e26 supply the uint128 share field overflows. Practical TVL hits other caps first; not actionable but worth a property test. |
| R3 | Liquidation bonus assumption | Operational | `FxLiquidator` keeper docs/tooling | Brief assumed 5% bonus; actual is 4.38% (Morpho LIF for LLTV=86%). Keeper bounty / liquidation profitability calcs based on 5% are 12.4% optimistic. |
| R4 | Bad debt rounding | Low | `FxReceipt` redeem after bad-debt event | OZ ERC-4626 floor rounding leaves 1-wei dust per redemption; immaterial at 1B but composing rebasing wrappers on top warrants audit. |
| R5 | uint96 cast in stranded amount | Theoretical | `FxHubMessageReceiver:154` | `uint96(minted)` truncates if Circle ever raises burnAmount above 2^96 USDC raw. Add `SafeCast.toUint96()` for one-liner safety. |
| R6 | Grace-window batch sweep | Operational | `FxHubMessageReceiver.sweepStrandedDeposit` | At 1000 stranded entries, 1000 separate sweep txs needed. No on-chain batch helper. Off-chain multisend is fine, but worth a `sweepStrandedDeposits(bytes32[] calldata)` for keeper ergonomics. |
| R7 | Oracle staleness on forks | Operational | All paths reading `MorphoOracleAdapter.price()` | Pyth + RedStone payload requirement means cold-fork vnets can't read prices without `tenderly_setCode` workaround. Document in the prime-vnet script that a mock oracle install is part of post-fork bootstrap, or run `_updatePyth` with a fresh Hermes payload at fork time. |
| R8 | Liquidation chain in single block | Unverified | Morpho bad-debt socialization | Did NOT test consecutive 1B liquidations in one block. Worth a follow-up: with 10 underwater positions liquidated back-to-back, does Morpho's pro-rata bad-debt allocation handle the ordering deterministically? |

---

## Reproducer

```bash
# Auth + activate
# (Tenderly MCP must be OAuth'd in your Claude Code session first)
# set_active_vnet 5ea52b4d-fe5a-4026-828c-d9b8fa08cec6
# revert_vnet 0x3f3836dc5790bcc0de93a5febb29bfe226cee70b62cef8f2123706d574c529ae  # clean fork

# Fund whale
# set_erc20_balance whale USDC 0x2386F26FC10000
# set_erc20_balance whale EURC 0x2386F26FC10000
# fund_account whale 0x56BC75E2D63100000

# Stage oracle mock (1e36)
curl -X POST $RPC -d '{"method":"tenderly_setCode","params":["0xf0cdaa...","0x7f...60005260206000f3"],"id":1,"jsonrpc":"2.0"}'

# Case 1: cf. send_vnet_transaction sequence (4 txs)
# Case 2: cf. supplyCollateral + borrow calldata in this report
# Case 3: revert_vnet to snapshot 0x41526eed... then crash oracle to 0.5e36 + liquidate
# Case 5: install mock transmitter + send executeDeposit per nonce
```

All raw calldata, mock bytecode, and decode scripts are reproducible from the Python helpers in this report (search for `python3 << 'EOF'` blocks in the agent transcript).
