# fx-Telaraña — Defensive Security Audit Report

**Protocol:** Forex Telaraña (cross-chain FX credit hub)
**Scope:** 11 subsystems, smart-contract layer (vault, hooks, perps, oracle, cross-hub rail, fee/rebate vaults, routing, spoke/Hyperlane intents, privacy/Ghost, governance + large hub hook)
**Status of findings:** All 39 findings below were independently re-verified against the deployed code. Verifier corrections/sharpenings are folded into each entry.
**Date:** 2026-06-09

---

## 1. Executive Summary

### Count by severity

| Severity | Count |
|---|---|
| **Critical** | 1 |
| **High** | 6 |
| **Medium** | 11 |
| **Low** | 13 |
| **Informational** | 8 |
| **Total** | **39** |

### Fix before any mainnet promotion (in priority order)

1. **F-1 (Critical) — `TelaranaGatewayHubHook.beforeSwap` gives away the entire Gateway-minted USDC for free.** `specifiedDelta=0` means the user's input is never collected; against the empty pools by design, the swapper receives the full minted (protocol-locked) USDC and pays ~0. Direct, repeatable loss of all bridged hub USDC. **Do not bind any pool to this hook until fixed; clear all routes / pause now.**
2. **F-2 (High) — `withdrawMargin` ignores unrealized PnL.** A trader can withdraw "free" margin until an open position is insolvent, minting unbacked claims against `protocolLiquidity` (socialized bad debt). Attacker-controlled, repeatable perp solvency breach.
3. **F-3 / F-4 (High) — Oracle & privacy-pool single-key authority with no timelock.** Perp oracle `DEFAULT_ADMIN` is the keeper EOA (feed mutators + `inverted` flip, no delay → mis-mark every market reading it); privacy `Entrypoint` `OWNER_ROLE` = same EOA can UUPS-upgrade and drain every pool. Rotate to a real multisig+timelock and split roles before value-bearing traffic.
4. **F-5 (High) — Compliance wall is not enforced in `SharedFxVault`.** The single retail-facing `bufxUSDC` share price folds in USYC NAV the instant `setYieldAdapter` is wired — the on-chain wall the spec promises structurally cannot exist in a tier-less share class. Restructure (institutional-only gate, or remove USYC from retail `totalAssets`) before opening public deposits.
5. **Decentralize governance generally (F-6, F-37, and the recurring single-EOA pattern).** The deployer/keeper EOA `0x0646`/`0xcA02` collapses admin+keeper+treasury+pauser+proposer+executor across the vault, fee/rebate vaults, router, oracle, hooks, and timelock. Key compromise is the dominant systemic risk across the whole report.

### Status of the 5 hard invariants

| # | Invariant | Status | Notes |
|---|---|---|---|
| **1** | **Solvency** — money-holding contracts keep balance ≥ owed/reserved claims after every call | **BROKEN** | F-1 (free USDC drain, critical), F-2 (withdraw-while-underwater socializes bad debt), F-25 (exit-side bearer redirect). Indirect/liquidity divergences: F-7, F-19, F-20, F-23. |
| **2** | **Compliance wall** — retail NAV never touches USYC; retail `totalAssets()` par-pure | **BROKEN (latent)** | F-5: the share-pricing contract has no tier concept; USYC NAV enters every retail lender's share price the instant the adapter is wired. Currently latent (`yieldAdapter == address(0)` on canary) but structurally unsatisfiable as built. |
| **3** | **Performance law** — `beforeSwap` never touches yield/Gateway, stays <50k gas / one vault call | **HELD** | `FxSwapHook.beforeSwap` unchanged; F-1 concerns a *different* hook (`TelaranaGatewayHubHook`) whose `beforeSwap` mints from Gateway by design — a separate contract, but note it violates the spirit of this law for its own path. |
| **4** | **Gateway exclusivity** — `FxGatewayHook` is the only contract moving USDC across hubs | **NOT FULLY VERIFIED** | Not directly tested in this pass. F-8/F-10 (bearer-claim mints) and F-1 (`TelaranaGatewayHubHook` mints via GatewayMinter) touch the cross-hub rail; recommend an explicit invariant test that no other contract calls `gatewayMint`/`relayToRemoteHub` outside the sanctioned path. |
| **5** | **`sweepStrandedDeposit` never sweeps non-stranded funds** | **HELD** | Verified: hub sweep keys on the unique real CCTP nonce (`cctpMessage.nonce()`), independent of the colliding `FxSpoke` local key (F-29). |

---

## 2. Findings by Severity

---

## CRITICAL

### F-1 — `TelaranaGatewayHubHook.beforeSwap` hands out the entire Gateway-minted USDC for free (empty-pool fund drain)

- **Subsystem:** Governance + large hub hook
- **Contract:** `TelaranaGatewayHubHook`
- **Location:** `contracts/src/hub/TelaranaGatewayHubHook.sol:560-565` (and `:514-551`)
- **Root cause:** `beforeSwap` returns `BeforeSwapDelta(specifiedDelta=0, unspecifiedDelta=-amountReceived)`. Per Uniswap v4 accounting (`lib/v4-core/src/libraries/Hooks.sol:251-279`, `:304-313`), a zero `specifiedDelta` means the hook absorbs **none** of the user's input — `amountToSwap` stays equal to `params.amountSpecified` and the full swap routes to the pool. The bound pools are **empty by design**, so `Pool.swap` fills ~0 and the caller is charged ~0 input. Meanwhile the hook unconditionally mints `amountReceived` USDC (protocol capital previously locked on the source hub) and pays all of it into the PoolManager (`USDC.safeTransfer(PoolManager, amountReceived)` at `:550`). In `afterSwap`, the caller's swapDelta is credited `+amountReceived` USDC. Net: user receives the full minted USDC and pays nothing. The correct reference is `FxSwapHook.sol:753/769`, which `take()`s the input and returns `specifiedDelta = +amountIn`.
- **Exploit scenario:** A valid Circle-attested BurnIntent for the route is a *bearer artifact* produced by the protocol's own legitimate bridge ops. Any observer constructs `hookData = abi.encode(attestation, signature, GatewayMintContext)`, sets the swap recipient to themselves with a trivial input, and calls `swap()` on the bound pool via any v4 router. `beforeSwap` mints `amountReceived` and settles all of it to the PoolManager; the empty pool charges ~0; v4 credits the caller the full minted amount; the attacker withdraws it. One drain per legitimate attestation (replay of the same attestation is blocked by Circle + `_gatewayReceipts[requestId]`, but each bridge yields a fresh drainable attestation).
- **Invariant broken:** #1 (Solvency) — hub loses the full minted USDC with no offsetting input or vault credit.
- **Fix:** The hook must collect input equal to the value delivered: `inputCurrency.take(POOL_MANAGER, dest, amountIn, false)` and return `toBeforeSwapDelta(+amountIn, -amountReceived)`, pricing `amountIn` from the oracle (mirror `FxSwapHook.sol:753/769`). If the intent is "inject liquidity, let the pool price the trade," the pool must hold liquidity and the hook must credit the vault/LP, not the swapper. **Until fixed: `clearPoolGatewayRoute` on all bindings and/or pause the hook.**
- **Verifier sharpening:** Attacker does **not** forge Circle's signature — it reuses a legitimately-produced attestation. The cited `arc-testnet.json:73` deployment note does not exist in the repo (`deployments/` empty), and the happy-path test (`TelaranaGatewayHubHook.beforeSwap.t.sol:204-214`) uses a mock PoolManager whose `settle()` returns 0 with no real swap netting — so **the existing test cannot catch this bug**. Operational reachability requires `setPoolGatewayRoute` (admin) binding, which the deploy script explicitly instructs. Severity confirmed critical.
- **Foundry PoC sketch:**
```solidity
function test_freeUsdcDrain() public {
    minter.setNextMint(false, MINT_AMOUNT);            // 1 USDC minted into hook
    ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, MINT_AMOUNT);
    bytes memory hookData = abi.encode(bytes('att'), bytes('sig'), ctx);
    IPoolManager.SwapParams memory p = _swapParamsBuyingUsdc(); // exact-input EURC, amountSpecified < 0
    vm.prank(address(poolManager));
    (, BeforeSwapDelta delta,) = hook.beforeSwap(taker, key, p, hookData);
    assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), int128(0));      // hook absorbs no input
    assertEq(int256(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta)), -int256(MINT_AMOUNT));
    assertEq(usdc.balanceOf(address(poolManager)), MINT_AMOUNT);              // free USDC for the swapper
}
```

---

## HIGH

### F-2 — `withdrawMargin` solvency check ignores unrealized PnL (trader withdraws into insolvency → socialized bad debt)

- **Subsystem:** Perps
- **Contract:** `FxMarginAccount`
- **Location:** `src/perp/FxMarginAccount.sol:87` (`withdrawMargin`), `:131` (`freeMarginOf`)
- **Root cause:** `withdrawMargin` gates on `freeMarginOf(trader) = margin - reserved`, where `reserved` is only the **initial** margin set at open. It never subtracts the position's current unrealized loss and never consults `FxHealthChecker`/maintenance. The margin account holds no oracle/clearinghouse reference, so it structurally cannot evaluate post-withdraw health. `_settleFunding` realizes only funding, not price PnL. Equity can drop below maintenance — and below zero — via a permitted withdrawal with no liquidation in between.
- **Exploit scenario:** Market 10x init / 5% maint. Deposit 200; open long notional 1000 (reserved 100, free 100). Price drifts 15% adverse: equity = 50, still ≥ maint, not liquidatable. `withdrawMargin(100)` succeeds (free 100 ≥ 100). Equity now 100 − 150 = −50: insolvent while open. Liquidation later drains the 100 margin and returns badDebt = 50, socialized to `protocolLiquidity` (unbacked). Trader exited with USDC they should never have been able to remove.
- **Invariant broken:** #1 (Solvency) — position goes underwater without liquidation; loss is socialized.
- **Fix:** Route withdrawals through a health gate — compute `equityAfter = margin − withdrawAmount + unrealizedPnl` across all open markets and require ≥ `sum(maintenanceMargin)`; use the verified (deviation-gated) oracle for the PnL read. Or reserve maintenance margin + mark losses so `freeMarginOf` reflects true free equity.
- **Verifier sharpening:** `reserved` is a per-trader **aggregate**, not per-position — a deep loss on one market is invisible to `withdrawMargin`, and the same root cause lets a trader **open** undercollateralized after an adverse move. The team's `invariant_marginAccountIsCashBacked` only checks the cash-backing accounting identity, which bad-debt socialization *preserves*, so it does not detect this hole. High (not critical): requires the trader's own margin at risk first and a real adverse move; loss bounded to the maintenance-margin shortfall; testnet `protocolLiquidity` is an explicit first-loss bucket.
- **Foundry PoC sketch:**
```solidity
function test_WithdrawWhileUnderwater() public {
  margin.depositMargin(trader, 200e6); mockOracle.setMid(1e18);
  vm.prank(keeper); ch.openOrIncrease(mkt, trader, /*notional 1000e6*/ size, type(uint256).max);
  mockOracle.setMid(0.85e18);                              // 15% adverse
  assertFalse(health.isLiquidatable(mkt, trader));        // equity 50 >= maint 50
  vm.prank(trader); margin.withdrawMargin(trader, 100e6); // SUCCEEDS — bug
  mockOracle.setMid(0.84e18);
  vm.prank(keeper); liq.flagAccount(mkt, trader); skip(121);
  (,int256 socializedLoss) = liq.liquidate(mkt, trader, type(uint256).max);
  assertGt(socializedLoss, 0);
}
```

### F-3 — Oracle `DEFAULT_ADMIN` is the keeper EOA on the live Arc canary (not `FxTimelock`); feed mutators are not timelocked

- **Subsystem:** Oracle / pricing
- **Contract:** `FxOracle` / `FxOracleV2`
- **Location:** `contracts/src/hub/FxOracle.sol:124-152` (`setFeed`/`setPythFeedConfig`/`setRedstoneFeed`/`setConfig`, all `onlyRole(DEFAULT_ADMIN_ROLE)`); `deployments/perp-oracle-5042002.json` (admin = keeper EOA `0xcA02`)
- **Root cause:** Spec intends `DEFAULT_ADMIN_ROLE = FxTimelock`. The live perp oracle was deployed by the keeper EOA and never handed off (the cirBTC hub oracle did hand off; the perp oracle did not). Every feed mutator and `setConfig` is gated solely on `DEFAULT_ADMIN_ROLE` with no delay. `setConfig` has hard caps in `_validateConfig`, but `setPythFeedConfig`/`setFeed` have **none** — an admin can point any token at any Pyth feed id and flip `inverted` instantly.
- **Exploit scenario:** Key compromise of `0xcA02`: `setPythFeedConfig(JPYC, BTC_USD_FEED, false)` makes `getMid(JPYC,USDC)` return ~100000e18 instead of ~0.0067e18. Attacker (or colluder) with a long JPYC perp / Morpho position withdraws massively over-credited PnL or borrows against fictitious collateral, or liquidates honest counterparties. Alternatively flip `inverted` on live QCAD (`inverted=true`) → mis-marks the whole book. No timelock window for governance to react. `getMid` (the mark path) has no deviation gate, and the verified liquidation path is not protected either since the same admin controls `setRedstoneFeed` + both `inverted` flags.
- **Invariant broken:** Governance/access-control boundary; cascades into #1 (Solvency) for every market reading this oracle.
- **Fix:** Atomically transfer `DEFAULT_ADMIN_ROLE` to `FxTimelock` at deploy and renounce the deployer's role (the pattern the cirBTC oracle followed). Add per-feed sanity guards to `setPythFeedConfig` (2-step/timelocked feed change; assert a newly-set feed's first read is within a sane band of the prior feed).
- **Verifier sharpening:** Address note — `perp-oracle-5042002.json` oracle is `0x479CC986`; the per-market records list `0xF181caF5` (a separate perp-stack instance); both share the identical no-handoff pattern, so the conclusion holds. This is a documented testnet canary (`admin==timelock==KEEPER`, mainnet → real TimelockController). High (not critical): exploit requires keeper-key compromise (a trusted role in the stated threat model), but as-deployed there is genuinely no timelock, no value cap, and no deviation gate on the mark path.
- **Foundry PoC sketch:**
```solidity
function test_adminRepointsFeed() public {
  vm.prank(keeperEOA);
  oracle.setPythFeedConfig(JPYC, BTC_USD_FEED_ID, false);
  (uint256 mid,) = oracle.getMid(JPYC, USDC);
  assertGt(mid, 1e22); // JPYC now priced like BTC
}
```

### F-4 — Privacy `Entrypoint`: `ASP_POSTMAN` + `OWNER_ROLE` on a single EOA can censor every shielded withdrawal and UUPS-upgrade-drain the whole pool

- **Subsystem:** Privacy pool + Ghost Mode
- **Contract:** `FxPrivacyEntrypoint` (via vendored `Entrypoint`)
- **Location:** `lib/privacy-pools/contracts/Entrypoint.sol:93` (`updateRoot`), `:312` (`_authorizeUpgrade`); `deployments/privacy-hook-arc.json` (owner == asp_postman == `0x0646`)
- **Root cause:** Private withdrawals require `_proof.ASPRoot() == ENTRYPOINT.latestRoot()` (`PrivacyPool.sol:59`); `latestRoot()` is whatever `ASP_POSTMAN` last pushed. On both Arc and Fuji, EOA `0x0646` holds **both** `OWNER_ROLE` and `ASP_POSTMAN`; `OWNER_ROLE` is its own role-admin and the sole `_authorizeUpgrade` gate. One key (a) decides which commitments are withdraw-eligible, (b) can push a root omitting a victim's deposit, and (c) can UUPS-upgrade to arbitrary logic that walks every pool (the entrypoint holds `type(uint256).max` allowance on each registered pool via `registerPool`).
- **Exploit scenario:** Key compromise → `upgradeToAndCall()` with a malicious implementation sweeps every pool (no extra approval needed). Separately, `updateRoot()` with a root excluding target deposits strips those users' private exit path.
- **Invariant broken:** None of the 5 directly, but undermines the privacy pool's censorship-resistance and enables full custody loss on key compromise.
- **Fix:** Split `ASP_POSTMAN` (low-trust relayer) from `OWNER_ROLE` (governance) from the UUPS upgrader; move `OWNER_ROLE`/`_authorizeUpgrade` behind a real multisig+timelock. Rotate `ASP_POSTMAN` off the owner key now.
- **Verifier correction:** The dominant unmitigated vector is **UUPS upgrade-to-drain**, not censorship. `PrivacyPool.ragequit` (`:132`) has **no** `validWithdrawal`/ASP check — the original depositor can always reclaim their full deposit regardless of any ASP root, so ASP censorship cannot *freeze funds*; it only **strips privacy** (forces a self-doxxing, original-depositor-only exit). `ragequit` does **not** mitigate the upgrade vector (a malicious impl can rewrite it). Live deployments are testnet; the deployment files document a plan to rotate `ASP_POSTMAN` but leave single-key upgrade unaddressed. Confirmed High as a centralization/single-key custody finding; downgrade the "freeze funds" sub-claim to "loss of privacy + forced original-depositor exit."
- **Foundry PoC sketch:**
```solidity
function test_ownerCanUpgradeAndDrain() public {
  // deposit 1000e6 USDC into pool via entrypoint
  vm.prank(owner);
  FxPrivacyEntrypoint(payable(ep)).upgradeToAndCall(
    address(new MaliciousImpl()),
    abi.encodeWithSignature("sweep(address,address)", usdc, attacker));
  assertEq(usdc.balanceOf(attacker), 1000e6);
}
```

### F-5 — Compliance wall not enforced in `SharedFxVault`: USYC NAV folds into the single, permissionless, retail-facing `bufxUSDC` share price

- **Subsystem:** Vault core (capital + yield + USYC)
- **Contract:** `SharedFxVault`
- **Location:** `contracts/src/vault/SharedFxVault.sol:225-228`, `:244-246`, `:487-490`, `:493-501`
- **Root cause:** `SharedFxVault` is a **single** ERC4626 (`bufxUSDC`) with one `totalAssets()`/share price and **no** tier split. `totalAssets()` unconditionally adds `_yieldAdapterAssets()` = `IFxUsycAdapter.yieldAssets()` (USYC `previewRedeem` NAV). `deposit()`/`mint()` are the inherited **public, permissionless** ERC4626 functions — no allowlist, KYB gate, or tier tag (no override exists; `maxDeposit` returns `type(uint256).max`). The Tier.RETAIL wall lives **only** in `FxReserveYieldRouter`, not in the vault that prices lender shares. The moment `setYieldAdapter(FxUsycAdapter)` + `deploySeniorToYield` run, USYC value enters every retail lender's share price. The protocol's own test (`SharedFxVaultCrossChainAccounting.t.sol:103-124`) exercises exactly this.
- **Exploit scenario:** Public deposits open. Alice (retail) deposits 1,000 USDC → `bufxUSDC`. Admin/keeper (single EOA) calls `setYieldAdapter(usycAdapter)` then `deploySeniorToYield(800e6)`. Alice's share price now equals `(hot + Morpho + USYC-previewRedeem + gatewayInTransit)/supply` — her par-pure USDC claim is backed by and marked against a Reg-S institutional-only T-bill, importing USYC redemption-haircut/de-peg and Teller-liveness risk. No retail consent; no on-chain wall stops it.
- **Invariant broken:** #2 (compliance wall: retail NAV never touches USYC; retail `totalAssets` par-pure).
- **Fix (strongest first):** (a) make `bufxUSDC` institutional-only via an explicit allowlist/KYB role; **or** (b) if it must stay retail, remove `_yieldAdapterAssets` from `totalAssets()` and route all USYC exposure exclusively through `FxReserveYieldRouter` (delete `setYieldAdapter`/`deploySeniorToYield`/`redeemSeniorFromYield`/`_yieldAdapterAssets` from the vault); **or** (c) split into separate retail vs institutional share classes with separate `totalAssets()`. Add a test asserting retail `totalAssets()` is invariant to any USYC price/balance change.
- **Verifier sharpening:** Not attacker-reachable — requires the privileged admin+keeper (single canary EOA) to (1) `setYieldAdapter` and (2) `deploySeniorToYield`; on the live canary `yieldAdapter == address(0)`, so `totalAssets()` is currently par-pure and the breach is **latent** until the documented next-step wiring. No fund theft, no solvency break (round-trip value-conserving). The breach is (a) a regulatory/design failure — the promised on-chain wall structurally cannot exist in a tier-less share class — and (b) economic-risk import. High (documented hard invariant the contract cannot satisfy, concrete on-chain effect once the documented step runs), not critical.
- **Foundry PoC sketch:**
```solidity
function test_usycEntersRetailSharePrice() public {
  vault.deposit(1000e6, alice);
  uint256 spBefore = vault.convertToAssets(vault.balanceOf(alice));
  FxUsycAdapter a = new FxUsycAdapter(usdc, usyc, teller, admin, address(vault));
  vm.prank(admin); vault.setYieldAdapter(address(a));
  vm.prank(keeper); vault.deploySeniorToYield(800e6);
  teller.setPrice(teller.priceE6()*105/100); usdc.mint(address(teller), 100e6);
  uint256 spAfter = vault.convertToAssets(vault.balanceOf(alice));
  assertGt(spAfter, spBefore, "USYC yield reached retail share price — wall broken");
}
```

### F-6 — Live Hyperlane source-auth is a single `trustedRelayerIsm` — a compromised relayer can forge arbitrary spoke intents into the hub

- **Subsystem:** Spoke + Hyperlane intents
- **Contract:** `FxHyperlaneHubReceiver`
- **Location:** `contracts/src/hub/FxHyperlaneHubReceiver.sol:160-188` (`handle`); `deployments/hyperlane-arc-testnet.json:16,52`
- **Root cause:** `handle()` establishes source authenticity via `(msg.sender == MAILBOX)` + `trustedSpokes[origin][sender]`, both of which depend on the Mailbox's ISM having proven origin/sender. The live deployment wires the default/app ISM to `trustedRelayerIsm` (with an explicit note: "Replace with multisig ISM before value-bearing production traffic"). A `trustedRelayerIsm` accepts any message the trusted relayer EOA submits, with **no** validator quorum/source proof. The relayer EOA is the same `0x0646` that signs Gateway burn intents.
- **Exploit scenario:** Compromise the relayer EOA → fabricate a message with `origin = trusted spoke domain`, `sender = trusted FxSpokeIntentRouter bytes32`, arbitrary Intent body → `trustedRelayerIsm.verify()` returns true with no source proof → hub stores the forged intent as `Accepted`. Forgery alone moves no funds (execution is beneficiary/route-gated), but enables **deterministic griefing**: `intentId = keccak256(origin, sender, intent)` is predictable, and `handle()` reverts `DuplicateIntent` for an existing id — so the attacker can pre-occupy the exact `intentId` a legitimate message will hash to (with `action=Borrow` it needs no funding), permanently bricking that legitimate intent. The occupied slot is cancellable only by the named beneficiary, not the attacker.
- **Invariant broken:** None directly (no immediate fund movement) — breaks cross-chain message-source integrity; building block for F-9 (route-funded paths).
- **Fix:** Replace `trustedRelayerIsm` with a multisig/aggregation ISM and `setInterchainSecurityModule` to a real quorum module before value-bearing traffic. Separate the Hyperlane relayer key from the Gateway burn-intent key. Add a per-intent acceptance cap/expiry so spoofed `Accepted` intents cannot indefinitely occupy `intentId` slots.
- **Verifier sharpening:** This is a deployment/trust-config weakness, not a contract-logic bug — `handle()`'s checks are correct given a sound ISM. Medium → escalated to High here only by the concrete, reachable, cheap deterministic griefing primitive on the live deployment (no contract-side mitigation; the contract blindly trusts the ISM). Bounded to griefing/spoofing with no fund movement or hard-invariant break, and self-flagged as testnet-only. *(Classified High for executive priority given live reachability; verifier rated it medium — see remediation.)*
- **Foundry PoC sketch:**
```solidity
ism.setAlwaysValid(true);
mailbox.deliverWithIsm(address(hub), SPOKE_DOMAIN, routerBytes32, forgedBody);
assertEq(uint8(hub.intentState(forgedId)), uint8(IntentState.Accepted)); // forged intent accepted
```

> **Note on F-6 severity:** the verifier confirmed-severity for the underlying finding is **medium** (griefing only, no fund movement, testnet, no contract-side fix possible). It is surfaced under High in the executive priority list because it is reachable on the live deployment with a deterministic, cheap DoS primitive and gates F-9. Treat as a hard go-live blocker (multisig ISM) regardless of the medium/high label.

---

## MEDIUM

### F-7 — `totalAssets()` counts USYC + Gateway-in-transit, but `_withdraw` can only source from hot+Morpho → redemption DoS / over-priced shares

- **Subsystem:** Vault core
- **Contract:** `SharedFxVault`
- **Location:** `contracts/src/vault/SharedFxVault.sol:225-228`, `:257-269`
- **Root cause:** `totalAssets() = seniorUsdcHot + _morphoSupplyAssets() + gatewayInTransitUsdc + _yieldAdapterAssets()`, but `_withdraw` only tops up from Morpho before paying out — it never calls `_redeemSeniorFromYield` and cannot pull in-transit Gateway USDC. Shares are priced against assets unreachable on the redemption path. The recovery paths are role-gated to non-lenders (`redeemSeniorFromYield` = KEEPER, `clearGatewayMint` = GATEWAY_ACCOUNTANT). No `maxWithdraw`/`maxRedeem` override reflects keeper-only liquidity, so ERC4626 advertises full withdrawability then reverts `InsufficientSeniorLiquidity`.
- **Exploit scenario:** Vault holds 1,000 senior; keeper deploys 900 to USYC. `seniorUsdcHot=100`, Morpho=0. `totalAssets()` still ~1,000, so a lender believes they can exit. `redeem` for 500 finds hot 100 < 500, Morpho 0, reverts. Funds stranded behind keeper-only recovery.
- **Invariant broken:** #1 (Solvency, liquidity sense) — share price asserts a claim the contract cannot honor on demand.
- **Fix:** Either cap `maxWithdraw`/`maxRedeem` at liquid+Morpho-withdrawable, or make `_withdraw` fall back to `_redeemSeniorFromYield` (and document Gateway-in-transit as unredeemable until cleared). Reconcile `recordGatewayBurn`/`clearGatewayMint` against actual hook lock/mint events.
- **Verifier corrections:** Gateway over-pricing sub-claim is weaker than stated — `recordGatewayBurn` debits `seniorUsdcHot` by the same amount it credits `gatewayInTransitUsdc` and reverts if hot < assets, so `totalAssets` is conserved and the accountant cannot inflate NAV above hot via this function. Funds are **not lost** — a KEEPER can always restore hot liquidity. Medium (not high): keeper-recoverable; USYC path behind human-gated, "do not broadcast" activation; counting in-transit USDC in NAV is intentional.
- **Foundry PoC sketch:**
```solidity
function test_redemptionRevertsWhileNavSaysSolvent() public {
  vault.deposit(1000e6, alice);
  vm.prank(keeper); vault.setYieldAdapter(adapter);
  vm.prank(keeper); vault.deploySeniorToYield(900e6);
  assertApproxEqAbs(vault.totalAssets(), 1000e6, 2);
  vm.prank(alice);
  vm.expectRevert(SharedFxVault.InsufficientSeniorLiquidity.selector);
  vault.withdraw(500e6, alice, alice);
}
```

### F-8 — `relayMintFromRemote` treats Gateway attestations as bearer claims — a whitelisted relayer can front-run and steal another relayer's in-flight mint

- **Subsystem:** Cross-hub rail
- **Contract:** `FxHubMessageReceiver` (and `FxGatewayHook.mintFromRemote`)
- **Location:** `contracts/src/hub/FxHubMessageReceiver.sol:214-234`; `FxGatewayHook.sol:178-196`
- **Root cause:** `relayMintFromRemote` routes minted USDC to `msg.sender`, but the attestation/signature are calldata bearer artifacts — the function does not bind the mint to the originating relayer nor parse the BurnIntent recipient on-chain. The code comment explicitly accepts that "ANY whitelisted relayCaller may claim ANY in-flight attestation." Circle's `destinationCaller` is the hook, so `gatewayMint`'s `msg.sender` is always the hook regardless of which relayer triggered the call.
- **Exploit scenario:** Relayer A (BUFX-perp) obtains an attestation for its lock and submits `relayMintFromRemote`; the tx sits in mempool. Relayer B (BUFX-spot, also whitelisted, compromised) copies the calldata and front-runs with higher gas. Mint routes to B; A's tx reverts `NoMintReceived`/`MintShortfall`. B has stolen the cross-hub liquidity belonging to A's book.
- **Invariant broken:** None of the 5 directly (funds stay within the whitelisted relayer set), but breaks intra-protocol fund attribution; surfaces as a solvency mismatch for the shorted relayer's book.
- **Fix:** Parse the BurnIntent/TransferSpec recipient or a relayer-bound nonce on-chain and require it match a destination recorded at lock time; **or** track a per-relayer pending set so `relayMintFromRemote` is callable only by the relayer that called the matching `relayToRemoteHub`. Until Circle's TransferSpec parser exists, restrict to exactly one trusted relayer on-chain (revert if >1 whitelisted).
- **Verifier sharpening:** Not exploitable by an arbitrary external attacker — requires an already-whitelisted (trusted) relayer that is malicious/compromised. No hard global invariant broken. Known, documented, explicitly-accepted tradeoff with single-relayer production as the recommended config. Medium given the spec's multi-relayer (spot+perp) intent.
- **Foundry PoC sketch:**
```solidity
function test_relayMint_frontRunSteal() public {
  vm.prank(owner); hub.setRelayCaller(A, true); hub.setRelayCaller(B, true);
  vm.prank(B);
  uint256 stolen = hub.relayMintFromRemote('payload','sig');
  assertEq(USDC.balanceOf(B), stolen);
}
```

### F-9 — Single keeper EOA holds admin+allocator+funder+pauser on `KawaiiRebateVault` — can divert the unallocated pool and freeze honest claims

- **Subsystem:** Fee + rebate vaults
- **Contract:** `KawaiiRebateVault`
- **Location:** `src/hub/KawaiiRebateVault.sol:84,110,158,193` (roles all = `0xcA02` per `deployments/kawaii-rebate-vault-5042002.json`)
- **Root cause:** Deployment grants `DEFAULT_ADMIN`, `REBATE_ALLOCATOR`, `REBATE_FUNDER`, `PAUSER` to the same keeper EOA. `DEFAULT_ADMIN` is its own role-admin; no timelock. The role-separation safety story is defeated. `allocate()` can send funded USDC to any address; `pause()` blocks `claim()` but not the keeper re-pointing funds.
- **Exploit scenario:** Key compromise → `allocate(attackerAddr, unallocated)` drains the whole funded backing pool into a schedule for an attacker address → wait `VEST_DURATION` → `claim()`. Independently, `pause()` freezes all legitimate `claim()` calls with no on-chain recourse.
- **Invariant broken:** None (solvency math holds); breaks the documented role-separation/least-privilege trust model.
- **Fix:** Split roles across distinct keys: ALLOCATOR = operational keeper, FUNDER = treasury, `DEFAULT_ADMIN` + PAUSER = multisig/timelock. Add a per-epoch allocation cap so one compromised allocator cannot drain the full unallocated pool in one tx.
- **Verifier correction:** Scope is narrower than "entire pool / every dollar owed to attacker." `allocate()` draws only from `unallocated` and never decrements other holders' vested schedules — **funds already allocated to honest holders are not stealable**; theft is bounded to the funded-but-unallocated pool. `recoverSurplus` is hard-bounded and cannot sweep owed/unallocated funds. Pause DoS is recoverable (same key can unpause). Centralization/single-key gap → **Medium**, not High.
- **Foundry PoC sketch:**
```solidity
function test_RogueKeeperDrainsUnallocated() public {
  vm.startPrank(keeper); usdc.approve(address(vault), 1_000e6); vault.fund(1_000e6);
  vault.allocate(attacker, 1_000e6); vm.stopPrank();
  skip(vault.VEST_DURATION());
  vm.prank(attacker); assertEq(vault.claim(), 1_000e6);
}
```

### F-10 — `TurboFeeVault.insurancePayout` pays the caller (`msg.sender`), not a beneficiary — `INSURANCE_ADMIN` can self-drain the insurance fund

- **Subsystem:** Fee + rebate vaults
- **Contract:** `TurboFeeVault`
- **Location:** `src/hub/TurboFeeVault.sol:135-144` (`USDC.safeTransfer(msg.sender, amount)`; `insuranceAdmin == 0x0646` per `deployments/turbo-fee-vault-5042002.json`)
- **Root cause:** `insurancePayout()` transfers to `msg.sender` with a free-text `reason` and no payee binding or cap. On the live deployment `INSURANCE_ADMIN_ROLE`, `DEFAULT_ADMIN_ROLE`, and `protocolTreasury` are the same EOA. The 10% insurance slice of every fee plus the entire LP share collected while `totalShares==0` (see F-13) accumulate in `insuranceBalance`, all withdrawable to one key at will.
- **Exploit scenario:** Fees accrue 10% to `insuranceBalance`; `0x0646` (or whoever compromises it) calls `insurancePayout(anyMarketId, insuranceBalance, "")` and receives the full balance. No policy gate, no recipient arg, no multisig.
- **Invariant broken:** Solvency preserved numerically; an unrestricted single-key honeypot — custody/trust failure.
- **Fix:** Add an explicit `address to` payee (or fixed insurance treasury) instead of `msg.sender`; route `INSURANCE_ADMIN_ROLE` to a multisig/timelock; emit the resolved payee; optionally cap per-call/per-epoch.
- **Verifier correction:** Facts correct; severity overstated as high. All guards present (onlyRole, nonReentrant, CEI, SafeERC20, amount-bound). No unauthorized actor can reach the funds; funds at risk are protocol-owned insurance reserves, not LP principal. The pay-to-`msg.sender` design is cosmetic (the same admin holds `DEFAULT_ADMIN` and could `setTreasury` to itself). Documented testnet posture. **Medium** trust/centralization, not high.
- **Foundry PoC sketch:**
```solidity
function test_InsuranceSelfDrain() public {
  _seedFees(100e6);                  // 10e6 -> insurance
  uint256 bal = vault.insuranceBalance();
  vm.prank(insuranceAdmin); vault.insurancePayout(bytes32(0), bal, "");
  assertEq(usdc.balanceOf(insuranceAdmin), bal);
}
```

### F-11 — `KawaiiRebateVault`: pauser (= keeper EOA) can indefinitely freeze all vested claims with no timelock or escape hatch

- **Subsystem:** Fee + rebate vaults
- **Contract:** `KawaiiRebateVault`
- **Location:** `src/hub/KawaiiRebateVault.sol:158` (`claim` `whenNotPaused`), `193-199` (`pause`/`unpause` = PAUSER = keeper)
- **Root cause:** `claim()` is the only holder exit and is `whenNotPaused`; `PAUSER_ROLE` is the same single keeper EOA. `pause()` has no time bound; `unpause()` is the same key. Already-vested, fully-backed rebates can be made unclaimable indefinitely. `recoverSurplus` cannot reach owed funds (correct), so paused-and-owed funds are simply stuck — no holder-side emergency withdrawal.
- **Exploit scenario:** Holder has vested USDC owed; keeper key is compromised/rogue → `pause()`. All `claim()` revert `EnforcedPause` indefinitely. No on-chain recourse for holders.
- **Invariant broken:** None (solvency holds); availability/censorship-resistance of the pull-payment promise.
- **Fix:** Move `PAUSER_ROLE` to a separate guardian and bound pause duration (auto-unpause after a max window), or exempt `claim()` of already-vested funds from pause (pause only blocks `allocate`/new vesting). Route `unpause` to a multisig/timelock distinct from the keeper.
- **Verifier sharpening:** Not a solvency break — funds become claimable again on `unpause()`. Marginal harm is temporary DoS/censorship, not theft (a keyholder can't directly steal already-owed funds; pause only censors them). The `fund()`-while-paused / `claim()`-blocked asymmetry is the one-sided lever. Medium, bounded by no-fund-loss and a key-compromise precondition.
- **Foundry PoC sketch:**
```solidity
function test_PauseFreezesVestedClaims() public {
  vm.startPrank(keeper); usdc.approve(address(vault),100e6); vault.fund(100e6);
  vault.allocate(holder,100e6); vm.stopPrank();
  skip(vault.VEST_DURATION());
  vm.prank(keeper); vault.pause();
  vm.prank(holder); vm.expectRevert(); vault.claim();
}
```

### F-12 — Partial-liquidation flag reset: a liquidator can close a negligible slice to delete the flag, re-arming `flagDelay` and blocking real liquidation while bad debt grows

- **Subsystem:** Perps
- **Contract:** `FxLiquidationEngine`
- **Location:** `src/perp/FxLiquidationEngine.sol:130` (`liquidate`), `:163-164` (close then unconditional `delete flaggedAt`); `src/perp/FxPerpClearinghouse.sol:194-216`
- **Root cause:** `liquidate()` accepts a caller-chosen `maxSizeToCloseAbsE18` and closes `min(maxSize, positionSize)` with no minimum-close-fraction and no "must restore health" requirement. After **any** successful close, `liquidate()` unconditionally `delete flaggedAt[marketId][trader]`. The next liquidation requires a fresh `flagAccount` + `flagDelay` (120s live).
- **Exploit scenario:** Position becomes liquidatable → griefer flags, waits 120s → `liquidate(mkt, trader, smallSize)` closes a negligible slice, flag deleted, position still deeply unhealthy but unflagged → honest keepers must re-flag and wait another 120s; griefer repeats. Adverse price deepens during delays, inflating realized + socialized bad debt.
- **Invariant broken:** #1 (Solvency) indirectly — reliably delaying liquidation lets equity go further negative.
- **Fix:** Do not delete the flag after a partial liquidation; only clear `flaggedAt` when the post-close position is healthy (re-check `isLiquidatableVerified`), or require the close to restore a target health factor. Keep the flag valid as long as the account remains liquidatable; reset only on rescind/recovery.
- **Verifier sharpening:** The "1 wei" literal is imprecise — a true 1-wei close reverts (`marginReleased` rounds to 0 → `releaseMargin(0)` reverts `ZeroAmount`, preserving the flag). The griefer must pick the smallest `maxSize` such that `marginReleased` rounds to ≥1 (≈ `currentAbs/marginReserved`, still a negligible ~2e-8..2e-10 fraction); the unconditional delete still fires. Liveness/griefing attack (no principal theft; attacker pays gas + tiny bounty). Medium.
- **Foundry PoC sketch:**
```solidity
function test_PartialLiqResetsFlag() public {
  vm.prank(keeper); liq.flagAccount(mkt, trader); skip(121);
  vm.prank(grief); liq.liquidate(mkt, trader, smallButNonzero); // closes ~0, deletes flag
  assertEq(liq.flaggedAt(mkt, trader), 0);
  assertTrue(health.isLiquidatable(mkt, trader));               // still unhealthy
  vm.expectRevert(); vm.prank(keeper); liq.liquidate(mkt, trader, type(uint256).max);
}
```

### F-13 — Keeper-settled order fills have no oracle price band — `SETTLER` can fill MARKET orders at an arbitrary price, extracting value to a colluding counterparty

- **Subsystem:** Perps
- **Contract:** `FxOrderSettlement`
- **Location:** `src/perp/FxOrderSettlement.sol:68-101` (`settleMatch`), `:120-134` (`_validateOrder`); `src/perp/FxPerpClearinghouse.sol:177-192` (`applyOrderFill` uses `fillPriceE18` directly)
- **Root cause:** `fillPriceE18` is chosen by the `SETTLER_ROLE` keeper and is not part of either signed order. For `ORDER_TYPE_MARKET`, `_validateOrder` applies **no** price check; `applyOrderFill` executes at `fillPriceE18` with no oracle sanity bound. For LIMIT only a one-sided bound is enforced. Both maker and taker fill at the same price (zero-sum), so a compromised/rogue `SETTLER` can pick any price for two opposite MARKET orders and transfer margin/PnL from one signer to a colluding signer. The deviation-gated `_priceViewVerified` exists but is wired only into liquidation.
- **Exploit scenario:** Keeper controls account B, matched against honest market-order signer A. A signs a MARKET long (no price bound); keeper crafts B's opposite MARKET order and `settleMatch(A,B, fillSize, fillPrice=far-from-market)`. A opens at a terrible entry, B at the mirror-favorable; the close realizes A's loss as B's gain.
- **Invariant broken:** None of the 5 strictly (protocol solvency holds via `protocolLiquidity` netting) — trader-to-trader value transfer.
- **Fix:** Bound every settled fill against the verified oracle mid (`|fillPriceE18 − getMidVerified| ≤ maxFillDeviationBps`). Require MARKET orders to carry a slippage bound. Move maker/taker price agreement on-chain (both sign a shared price).
- **Verifier sharpening:** Privileged-role/centralization risk, not a permissionless exploit: requires SETTLER compromise + a colluding counterparty + an honest victim with a signed (price-unbounded) market order. B's profit leg is bounded by `protocolLiquidity` at close. Root gap is precise — settlement fill pricing has no oracle band while the verified path exists and was applied only to liquidation. Medium.
- **Foundry PoC sketch:**
```solidity
function test_KeeperArbitraryFillPrice() public {
  mockOracle.setMid(1e18);
  SignedOrder memory a = marketBuy(traderA, mkt, S);
  SignedOrder memory b = marketSell(keeperB, mkt, S);
  vm.prank(keeper); settlement.settleMatch(a, sigA, b, sigB, S, 2e18); // far from mid; no revert
  assertLt(ch.unrealizedPnl(mkt, traderA), 0);
}
```

### F-14 — `FxRouter / FxRouterSwapAdapter / FxFixedRateSwapAdapter` core admin is the single KEEPER EOA with no timelock — redirect fees, swap in an arbitrary adapter, drain seeded liquidity

- **Subsystem:** Routing + registries
- **Contract:** `FxRouter` / `FxRouterSwapAdapter` / `FxFixedRateSwapAdapter`
- **Location:** `contracts/src/hub/FxRouter.sol:300-335`; `FxRouterSwapAdapter.sol:120-143`; `FxFixedRateSwapAdapter.sol:116-179`
- **Root cause:** All three use owner gating; `FxRouter` is plain `Ownable` (one-step). Live `FxRouter` is `owner=KEEPER, treasury=KEEPER`. The keeper can `setTreasury` to itself (re-route every fee), `setSwapAdapter` to any contract (enabling F-15's under-delivery), `setRoute` to an attacker-friendly hook, and on the fixed-rate adapter `withdrawLiquidity` drains all seeded buy-side float / `setRate` sets an exploitative rate. None timelock-gated.
- **Exploit scenario:** Key compromise → `setTreasury(attacker)` captures fee flow; `setSwapAdapter(attacker)` captures `sellAmountNet` of every intent; `withdrawLiquidity(buyToken, attacker, balance)` walks off with the fixed-rate float in one call. `setPaused(true)`/`setRate(0)` grief.
- **Invariant broken:** None of the 5 strictly (router holds no pooled user deposits) — a direct steal/grief surface on one key.
- **Fix:** Move all three contracts' ownership to a real `FxTimelock`. Make `FxRouter` `Ownable2Step`. Separate non-keeper treasury. Gate `setSwapAdapter` specifically behind the timelock (per-intent fund-redirect surface).
- **Verifier corrections:** `FxRouterSwapAdapter` is already `Ownable2Step` (typo-brick mitigated); `FxFixedRateSwapAdapter` uses a hand-rolled single-step owner. `setRoute` PoolKey is constrained to `{sell,buy}` currencies; the residual is an owner-chosen malicious hook (pure under-delivery still reverts on `minBuyAmount`). Fee hard-capped at 50bps; fixed-rate float is operator capital, not user deposits. Documented pre-mainnet posture (PR-6 swaps Ownable for AccessControl+Timelock). Medium.
- **Foundry PoC sketch:**
```solidity
function test_KeeperRedirectsFees() public {
  vm.prank(keeper); router.setTreasury(attacker);
  router.executeIntent(intent, intentSig, permit, permitSig);
  assertGt(sellToken.balanceOf(attacker), 0);
}
function test_FixedRateAdapterDrain() public {
  vm.prank(owner);
  fixedAdapter.withdrawLiquidity(buyToken, attacker, buyToken.balanceOf(address(fixedAdapter)));
  assertEq(buyToken.balanceOf(address(fixedAdapter)), 0);
}
```

### F-15 — Permissionless `executeHedge` lets an attacker-LP force the protocol to round-trip a perp short, draining protocol margin via fees/funding/PnL

- **Subsystem:** Spot executor + hedge
- **Contract:** `FxHedgeExecutor` / `FxHedgeHook`
- **Location:** `contracts/src/hub/FxHedgeExecutor.sol:69-92` (`executeHedge`); `contracts/src/hub/FxHedgeHook.sol:280-333` (`_applyExposureDelta`)
- **Root cause:** `executeHedge(poolId)` is fully permissionless and pushes the protocol-funded `hedgeTrader` position toward `FxHedgeHook.poolHedgeSizeE18(poolId)`, which is recomputed from `poolExposureE18` updated in `afterAddLiquidity`/`afterRemoveLiquidity` from the LP's own deposit/withdraw delta. Any LP can move the target up (add hedge-token liquidity) then down (remove it). Each poke charges `tradingFeeBps` out of the executor's protocol margin, settles funding, and on close realizes mark-to-market PnL — with no per-pool rate limit, cooldown, or cap.
- **Exploit scenario:** Attacker LPs a hedged pool → adds large hedge-token-heavy liquidity (sets target high) → `executeHedge` opens a large short (pays fee from protocol margin) → removes liquidity (target → 0) → `executeHedge` closes (pays fee again + adverse funding/PnL) → repeat. Each cycle bleeds 2× trading fee + funding from protocol margin; eventually the executor's margin is drained and hedging reverts `InsufficientFreeMargin`, disabling IL protection.
- **Invariant broken:** #1 (Solvency: protocol-owned hedge margin bled with no rate limit).
- **Fix:** Gate `executeHedge` behind a keeper role or add an on-chain economic guard: per-pool cooldown/minimum interval, max notional per epoch, require the verified (deviation-gated) price for open/close, and source exposure only from `afterSwap` (real trading) rather than reversible LP add/remove. Bound per-call notional; require pokes to only reduce net `|exposure+hedge|`.
- **Verifier correction:** Slow drain/griefing-of-IL-protection, not direct theft — leaked fees flow to `TurboFeeVault` (partly protocol-internal) and counterparties, not the attacker. Per-cycle loss bounded by `tradingFeeBps` (~5bps); attacker bears real LP capital + gas each cycle. Largest term (close PnL) needs the separate Pyth-mark manipulation (F-16). Medium.
- **Foundry PoC sketch:**
```solidity
function test_hedgeRoundTripDrainsProtocolMargin() public {
  uint256 startMargin = margin.marginOf(address(executor));
  for (uint i; i < 50; ++i) {
    vm.prank(poolManager);
    hook.afterAddLiquidity(attacker, key, _modifyParams(1), toBalanceDelta(-1_000e6, -2_000e18), ZERO, "");
    vm.prank(attacker); executor.executeHedge(poolId);   // open short, pay fee
    vm.prank(poolManager);
    hook.afterRemoveLiquidity(attacker, key, _modifyParams(-1), toBalanceDelta(1_000e6, 2_000e18), ZERO, "");
    vm.prank(attacker); executor.executeHedge(poolId);   // close, pay fee again
  }
  assertLt(margin.marginOf(address(executor)), startMargin);
}
```

### F-16 — Hedge open/close uses the lenient Pyth-only oracle, exposing protocol-funded hedge to mark manipulation that the verified path exists to prevent

- **Subsystem:** Spot executor + hedge
- **Contract:** `FxHedgeExecutor` / `FxPerpClearinghouse`
- **Location:** `contracts/src/hub/FxHedgeExecutor.sol:80,85` → `contracts/src/perp/FxPerpClearinghouse.sol:161,173` (`_price` → `_priceView` → `ORACLE.getMid`)
- **Root cause:** `executeHedge` calls `openOrIncrease`/`decreaseOrClose`, both pricing via `getMid` (Pyth-only, no two-source deviation gate). The codebase already switched `liquidatePosition` to `_priceVerified` "precisely because a brief Pyth manipulation while RedStone disagrees would be enough" — but the protocol-funded hedge open/close still prices through the un-gated `getMid`. There is no verified variant of `openOrIncrease`/`decreaseOrClose`.
- **Exploit scenario:** Attacker grows exposure (via LP add, which yields `spotPriceE18==0` and bypasses the 2% TWAP pause) so the target demands a large short → nudges the Pyth price within the confidence band while RedStone lags → `executeHedge` opens the short at the inflated mark → price reverts to fair → the protocol's short is underwater; loss realized from protocol margin on close.
- **Invariant broken:** None directly; compounds F-15's solvency drain (protocol margin).
- **Fix:** Force the verified price path for hedge open/close — add verified variants of `openOrIncrease`/`decreaseOrClose` reading `_priceVerified`, or have `executeHedge` forward a RedStone payload and settle through `getMidVerified`. Gate `executeHedge` so an unprivileged caller cannot trigger a Pyth-only-priced protocol trade.
- **Verifier sharpening:** The TWAP pause **does** block the swap-driven exposure-pump variant; the attacker must grow exposure via liquidity adds (committing real LP capital). The core mispricing bites on **any** honest poke, so target inflation is optional. Loss magnitude is bounded by the Pyth confidence band (~30 bps) and the 60s staleness window on a hedge-sized position, and only to the extent the attacker also captures the surrounding flow. Compounds, rather than constitutes, a standalone drain — Medium.
- **Foundry PoC sketch:**
```solidity
function test_hedgeOpensAtManipulatedPythMark() public {
  vm.prank(poolManager);
  hook.afterAddLiquidity(attacker, key, _modifyParams(1), toBalanceDelta(-1_000e6, -2_000e18), ZERO, "");
  oracle.setMid(address(jpyc), address(usdc), 2e18); // inflated Pyth mid, RedStone unused
  vm.prank(attacker); executor.executeHedge(poolId);
  IFxPerpClearinghouse.Position memory p = clearinghouse.position(MARKET_ID, address(executor));
  assertEq(p.entryPriceE18, 2e18);
}
```

### F-17 — Morpho rehypothecation couples deposit AND withdraw liveness to the (admin-set) `FxMarketRegistry` market + Morpho liquidity (DoS / fund lock)

- **Subsystem:** Privacy pool + Ghost Mode
- **Contract:** `FxPrivacyPool`
- **Location:** `src/hub/FxPrivacyPool.sol:142-152` (`_pull`/`_push`), `:187-211` (`_rebalance`), `:227-248` (`_ensureHot`/`_withdrawFromMorpho`), `:167-176` (`_morphoParams`)
- **Root cause:** USDC + EURC pools run with rehyp ON (default `hotReservePct=2000`; only basket pools set 100%-hot). Every deposit's `_pull` → `MORPHO.supply`; every withdraw's `_push` → `_ensureHot` → `MORPHO.withdraw`. Both read `MarketParams` from the admin-mutable registry. If the Morpho market is fully utilized, `MORPHO.withdraw` of the JIT shortfall reverts → `_push` reverts → the shielded withdrawal cannot complete until liquidity returns (the nullifier is **not** consumed, so no funds lost, but the user is locked out).
- **Exploit scenario:** A borrower (or organic FX-loan demand) drives Morpho utilization to ~100%. A shielded user submits a valid withdrawal proof; `_ensureHot` tries to pull the shortfall, Morpho reverts insufficient-liquidity, the whole withdraw reverts. A privacy product whose value prop is exit-on-demand stalls.
- **Invariant broken:** #1 preserved (balance-based; revert rolls back spend); **availability** is not guaranteed.
- **Fix:** Keep a meaningful hot reserve + an emergency owner/relayer path serving withdrawals from hot even if Morpho is illiquid; a circuit-breaker to force 100%-hot **without** itself needing a Morpho withdraw (use a no-revert/try path); snapshot/lock the market id per `morphoShares` balance; wrap `_rebalance` in `_pull` in try/catch so a transient fault does not brick all deposits.
- **Verifier corrections:** The "admin re-points registry orphans `morphoShares`" exploit is not reachable — `FxMarketRegistry` cannot mutate/delete an existing mapping at runtime; the reachable registry failure is a deploy-time `UnknownMarket` revert. The finding **understates** the problem: the owner's de-risk escape hatch (`setHotReservePct(10000)` → `_withdrawAllFromMorpho`) **also** hits Morpho's `INSUFFICIENT_LIQUIDITY` guard, so the documented remediation lever is itself blocked exactly when liveness fails. Medium (liveness/fund-availability, no theft).
- **Foundry PoC sketch:**
```solidity
function test_withdrawRevertsWhenMorphoIlliquid() public {
  // pool at 20% hot; deposit 1000e6 -> _rebalance supplies 800e6 to Morpho
  // simulate Morpho fully borrowed so withdraw(800) reverts; build valid withdraw proof for 1000e6
  vm.expectRevert();
  entrypoint.relay(w, p, scope); // user locked out, nullifier not spent
}
```

### F-37 — Governance: `FxTimelock` is sound but gates only oracle/registry/liquidator; highest-blast-radius params (vault setters, hook routes, Gateway authority) are not timelocked, and proposer/executor is a single deployer EOA

- **Subsystem:** Governance + large hub hook
- **Contract:** `FxTimelock` / `TelaranaGatewayHubHook`
- **Location:** `contracts/src/governance/FxTimelock.sol:39-44`; `contracts/script/DeployArcTestnet.s.sol:239-250`; `TelaranaGatewayHubHook.sol:174-231,:331-347`
- **Root cause:** `FxTimelock` is a correct pass-through over OZ TimelockController 5.6.1 (no in-contract delay bypass). But (1) the deploy wires only `FxOracle`/`FxMarketRegistry`/`FxLiquidator` admin to the timelock; `TelaranaGatewayHubHook`'s privileged setters (`setGatewayRoute`, `setGatewaySignerMode`, `setGatewayContextProofMode`, `setGatewayContextMailbox`, `setGatewayContextTrustedSender`, `setPoolGatewayRoute`, `clearPoolGatewayRoute`, `pause`/`unpause`) are all `DEFAULT_ADMIN`/`OPERATIONS` held by the keeper EOA, **outside** the timelock with no delay. (2) The timelock has a single proposer **and** executor, both = deployer EOA; proposers also hold `CANCELLER_ROLE`, so the same key can cancel any honest proposal.
- **Exploit scenario:** Compromise of `0x0646`: `setGatewayRoute` to point `destinationHub` at an attacker, or `setPoolGatewayRoute` to bind an attacker-favorable pool, or `pause()` to freeze the swap rail — none touch the timelock (0s delay). The three params the timelock does gate are controlled end-to-end by one key (24h delay, same key can cancel).
- **Invariant broken:** None (governance configuration / blast-radius).
- **Fix:** Move the hook's route/proof/mailbox/pool-binding setters under `DEFAULT_ADMIN == FxTimelock` (keep only `pause` under a fast OPERATIONS multisig). Configure the timelock with a multisig proposer set and a separate executor (or open execution), not a single EOA holding both. Per spec §10.2, OPERATIONS = 3-of-5 multisig, DEFAULT_ADMIN = 24-48h timelock on every admin contract including this hook.
- **Verifier sharpening:** Confirmed — no logic bug, no hard-invariant break; requires keeper-key compromise; testnet canary. Blast radius is large (the hook is the v4 swap rail; can be route-pointed at an attacker or frozen with zero delay) and the timelock's "no-instant-rug + multi-party" property is genuinely unrealized. The cross-hub USDC mover `FxGatewayHook` is also EOA-admin'd, so the point holds for both. Medium.
- **Foundry PoC sketch:**
```solidity
function test_hookSettersBypassTimelock() public {
  vm.prank(keeperEOA);
  GatewayHubRoute memory evil = goodRoute; evil.destinationHub = attacker;
  hook.setGatewayRoute(ROUTE_ID, evil); // executes instantly, 0s delay
  assertEq(hook.gatewayRoute(ROUTE_ID).destinationHub, attacker);
}
```

### F-38 — `TelaranaGatewayHubHook.beforeSwap` skips ALL Gateway context-proof and whitelisted-caller checks that `receiveGatewayMint` enforces

- **Subsystem:** Governance + large hub hook
- **Contract:** `TelaranaGatewayHubHook`
- **Location:** `contracts/src/hub/TelaranaGatewayHubHook.sol:452-518` (vs `_validatedRouteForMint` `:603-652`)
- **Root cause:** `receiveGatewayMint` goes through `_validatedRouteForMint` enforcing (a) `route.whitelistedCaller` gating, (b) action/tokenOut/spotRouteId well-formedness, (c) `_verifyGatewayContextProof` (SIGNED_INTENT/HYPERLANE proof modes). The v4 `beforeSwap` path re-implements route validation inline but **omits** the whitelistedCaller check, the `_verifyGatewayContextProof` call, and the action-consistency checks. The inline comment even states the path "allows public callers … ungated apart from PoolManager forwarding the call."
- **Exploit scenario:** An operator binds a pool to a route they administer with a proof mode (signed-intent/Hyperlane) expecting only proven contexts can consume mints. An attacker with any validly Circle-attested BurnIntent for that route calls `swap` on the bound pool; `beforeSwap` mints and settles **without** checking the proof mode or whitelistedCaller, defeating the entire context-proof access layer. Combined with F-1 this is a free drain; even if F-1 were fixed, the proof/whitelist boundary the operator believes is active is not enforced on the swap path.
- **Invariant broken:** None directly — removes the cross-chain message-trust gate the operator configured.
- **Fix:** Route `beforeSwap` through the same `_validatedRouteForMint` logic (or at minimum call `_verifyGatewayContextProof` and apply the whitelistedCaller check) before minting. Factor shared validation into one internal function so the two paths cannot drift. Alternatively forbid binding any route whose `proofMode != NONE` / `whitelistedCaller != 0`.
- **Verifier corrections:** Deployment evidence cited in the raw finding is fabricated — `arc-testnet.json:223-224` does not exist; no config binds a pool or sets `SIGNED_INTENT_OR_HYPERLANE`/`whitelistedCaller` for any route. The bug is **latent**, conditional on admin enabling proof mode + binding a pool. Standalone impact is a permissionless caller consuming a mint for a route the operator believed was proof/whitelist-gated; monetization depends on F-1. Medium (deliberately-disabled access-control layer on a cross-hub trust boundary), not high free-drain.
- **Foundry PoC sketch:**
```solidity
function test_beforeSwap_bypassesProofMode() public {
  vm.prank(admin); hook.setGatewayContextProofMode(ROUTE_ID, GatewayContextProofMode.SIGNED_INTENT);
  minter.setNextMint(false, MINT_AMOUNT);
  ITelaranaGatewayHubHook.GatewayMintContext memory ctx = _ctx(REQUEST_ID, MINT_AMOUNT); // empty hookData, no proof
  bytes memory hd = abi.encode(bytes('att'), bytes('sig'), ctx);
  vm.prank(address(poolManager));
  hook.beforeSwap(taker, key, _swapParamsBuyingUsdc(), hd); // SUCCEEDS despite no proof
  // Contrast: receiveGatewayMint would revert GatewayContextProofMissing
}
```

---

## LOW

### F-18 — Untimelocked `DEFAULT_ADMIN` can swap the yield adapter to an arbitrary contract whose trusted `yieldAssets()`/`depositToYield` can inflate NAV or sink senior USDC

- **Subsystem:** Vault core
- **Contract:** `SharedFxVault`
- **Location:** `contracts/src/vault/SharedFxVault.sol:487-490`, `:529-539`, `:244-246`
- **Root cause:** `setYieldAdapter` is `onlyRole(DEFAULT_ADMIN_ROLE)`, not timelocked (only `UPGRADER_ROLE` is timelock-gated). `_yieldAdapterAssets()` trusts the adapter's `yieldAssets()` directly into `totalAssets()`; `_deploySeniorToYield` forceApproves the adapter and pulls senior USDC via `depositToYield()`. An adapter is a fully trusted external dependency selected by a single EOA with no delay.
- **Exploit scenario:** Admin-key compromise → `setYieldAdapter(maliciousAdapter)`. (a) `deploySeniorToYield(seniorUsdcHot)` transfers all hot senior USDC into the malicious adapter (drained; redemptions brick). (b) `maliciousAdapter.yieldAssets()` returns a huge number; `totalAssets()` balloons, griefing honest depositors at a fake NAV. No timelock window.
- **Invariant broken:** #1 (Solvency) under admin-key compromise; amplifies F-5.
- **Fix:** Move `setYieldAdapter` (and `setOracle`/`setPoolManager`/`allowHook`) behind `FxTimelock`. Bound `_yieldAdapterAssets` contribution (never exceed cumulative deployed principal + a sane yield cap). On mainnet never collapse admin==keeper==timelock to one key.
- **Verifier correction:** Correctly Low. On the actual live deployment admin==timelock==UPGRADER==KEEPER==`0x0646`, so the same compromised EOA can already `upgradeToAndCall` to an arbitrary implementation — the yield-adapter path adds nothing over the strictly-more-powerful upgrade. Bites only on a future mainnet config with timelock genuinely separated. Note: `setOracle`/`setPoolManager` are the same untimelocked class and arguably worse (oracle prices `fundFill` notional/FX-out caps).
- **Foundry PoC sketch:**
```solidity
function test_rogueAdapterDrainsSenior() public {
  vault.deposit(1000e6, alice);
  MaliciousAdapter m = new MaliciousAdapter(usdc);
  vm.prank(admin); vault.setYieldAdapter(address(m));
  vm.prank(keeper); vault.deploySeniorToYield(vault.seniorUsdcHot());
  assertEq(usdc.balanceOf(address(m)), 1000e6);
  vm.prank(alice); vm.expectRevert(); vault.withdraw(1000e6, alice, alice);
}
```

### F-19 — Protocol-fee sleeve is dead in the vault-backed hook: swap spread is never booked to `protocolFee0/1`, so `claimProtocolFees` and TurboFeeVault (P3) routing can never fire

- **Subsystem:** FxSwapHook (v4 delta hook)
- **Contract:** `FxSwapHook`
- **Location:** `contracts/src/hub/FxSwapHook.sol:734` (`feeOut` discarded), `:411-457` (`claimProtocolFees`), `:387-405` (`setProtocolFeeBps`/`setFeeVault`)
- **Root cause:** `beforeSwap` calls `_quote` which returns `(amountOut, feeOut)`, but `feeOut` is discarded. `protocolFee0/1` are only ever decremented in `_claimProtocolFees`, never incremented; `ProtocolFeeAccrued` is never emitted. In the vault-backed design the spread instead stays in the vault (full input credited via `recordInflow`, output reduced by the spread → spread accrues as junior inventory). `claimProtocolFees` always reverts `AmountExceedsProtocolFee` (available==0); `setProtocolFeeBps`/`MAX_PROTOCOL_FEE_BPS`/`setFeeVault`/`SwapFeeRouted` are dead config; the P3 "swap fees → TurboFeeVault 40% LP rewards" path is non-functional for swaps.
- **Exploit scenario:** Not attacker-driven — an integrity/availability gap. Treasury sets `protocolFeeBps` + `feeVault` expecting swap fees to route to LP rewards; no swap books a fee; `claimProtocolFees` reverts; documented LP fee distribution silently never happens.
- **Invariant broken:** None (value lands in the vault junior slice) — breaks the documented fee→TurboFeeVault path.
- **Fix:** Either re-wire the vault-backed path to credit a fee accumulator each swap and route via `feeVault.depositFee`, or remove the dead protocol-fee surface and document that swap spread accrues to junior LPs in-vault (P3 wired elsewhere).
- **Verifier sharpening:** Spread value increases vault NAV (benefits LPs/junior) — solvency holds, compliance wall untouched, `beforeSwap` still never touches yield/Gateway. Operator-set `protocolFeeBps`/`feeVault` are no-ops for swaps (silent mis-config). `TurboFeeVault.depositFee` may still be reachable from the perp-fee side of P3; this is scoped to the swap-fee leg. Low.
- **Foundry PoC sketch:**
```solidity
function test_NoFeeEverBooked() public {
  doSwapViaRouter();
  assertEq(hook.protocolFee0(), 0); assertEq(hook.protocolFee1(), 0);
  vm.prank(hook.treasury()); vm.expectRevert(); hook.claimProtocolFees(USDC, treasury, 1);
}
```

### F-20 — Un-seeded / zero-target swap takes the trader's full input and returns zero output; `quoteExactInput` can revert on `_invertE18(0)`

- **Subsystem:** FxSwapHook (v4 delta hook)
- **Contract:** `FxSwapHook`
- **Location:** `contracts/src/hub/FxSwapHook.sol:830-831` (zero-target → amountOut 0), `:753` (take amountIn anyway), `:969`/`:1201-1203` (`_invertE18` div-by-zero)
- **Root cause:** If `baseTargetE18` or `quoteTargetE18` is 0, `_quote` returns `(0,0)`. `beforeSwap` still executes `inputCurrency.take(POOL_MANAGER, VAULT, amountIn)` and returns specified delta `+amountIn` with `-0` output, so the swapper pays full input for zero output. Separately, `quoteExactInput` inverts the mid via `_invertE18` (`1e36/mid`); if the truncated mid is 0 the view reverts with a panic.
- **Exploit scenario:** Mostly self-harm: a router/user swaps against a hook whose targets are 0 (freshly deployed-but-unseeded pool, or misconfigured multi-pool rollout) and loses input for nothing. A griefer can front-run the owner's first `sync()` on a freshly PoolManager-initialized pool and dump a victim's swap. The live canary has targets seeded, so impact is conditional on un-seeded deployments.
- **Invariant broken:** None (initiator self-inflicted) — a user-funds-loss footgun.
- **Fix:** In `beforeSwap`, revert (`InsufficientLiquidity`/`NotSeeded`) when `baseTargetE18==0 || quoteTargetE18==0 || amountOut==0` **before** taking input. Guard `_invertE18` against a zero denominator with a typed error.
- **Verifier sharpening:** Lost input flows into `SharedFxVault` as junior capital (no solvency break). The "fully redeemed legacy state" route to zero targets is **not** reachable (`redeem()`/`deposit()` revert `UseVault()`); the only live way to hit zero targets is never-seeded. Live canary hooks are seeded. Low (borderline informational).
- **Foundry PoC sketch:**
```solidity
function test_ZeroTargetTakesInputZeroOut() public { /* freshHookNoSeed; swap amountIn=1000e6; assert trader paid 1000e6, received 0 */ }
function test_InvertZeroReverts() public { /* mock oracle mid 0 */ vm.expectRevert(); hook.quoteExactInput(TOKEN1, 1e6); }
```

### F-21 — `executeDeposit` accepts a CCTP mint from ANY source domain / ANY sender spoke (no spoke allowlist)

- **Subsystem:** Cross-hub rail
- **Contract:** `FxHubMessageReceiver`
- **Location:** `contracts/src/hub/FxHubMessageReceiver.sol:283-319`
- **Root cause:** `executeDeposit` verifies the CCTP attestation, inner `mintRecipient==this`, and `hookData==abi.encode(beneficiary,hubCalldata)`, but never checks the outer `sourceDomain` or `sender`. `CctpMessageLib` exposes no `sender()` reader. Any address on any CCTP chain can call `depositForBurnWithHook` with `mintRecipient=receiver`, `destinationCaller=receiver`, and crafted `hookData`, then call `executeDeposit`; the contract forwards attacker-controlled `hubCalldata` into `FxMarketRegistry` with a live approval for `minted`.
- **Exploit scenario:** Attacker burns their own 1 USDC on a cheap chain with `hookData=abi.encode(attackerBeneficiary, maliciousRegistryCalldata)`, gets the attestation, calls `executeDeposit`. Receiver mints 1 USDC to itself, approves the registry for 1 USDC, executes the calldata as a privileged on-behalf caller.
- **Invariant broken:** None of the 5 if `FxMarketRegistry` is fully hardened; removes the spoke trust boundary.
- **Fix:** Add an explicit allowlist of `(sourceDomain, senderSpoke)` pairs and validate in `executeDeposit`. Extend `CctpMessageLib` with `sourceDomain()`/`sender()` readers (offsets 4 and 44) and assert `sender==trustedSpoke[sourceDomain]`.
- **Verifier correction:** Severity over-stated; corrected to Low. Not a fund-loss path — the registry (the sole gate) is hardened: `withdraw`/`withdrawCollateral`/`borrow`/`borrowDelegated` all revert on `onBehalf != msg.sender` / no delegation; receiver holds no standing funds; approval is scoped to exactly `minted` and force-dropped to 0 after; `nonReentrant` defeats reentrancy; leftover accounting + `strandedUsdcLiability` prevent touching prior stranded deposits. Realistic impact: attacker can only supply/repay with their OWN bridged dollars to an arbitrary beneficiary (self-funded gift) or self-grief. Defense-in-depth gap (missing source-domain allowlist).
- **Foundry PoC sketch:**
```solidity
function test_executeDeposit_acceptsArbitrarySource() public {
  // craft CCTP msg sourceDomain=99, sender=attacker, mintRecipient=receiver, hookData=encode(attacker, evilCalldata)
  receiver.executeDeposit(msg, attestation, attacker, evilCalldata); // succeeds despite no allowlisted spoke
}
```

### F-22 — `FxYieldRelay` yield delivery is not actually cross-chain on-chain — `claimYieldFor` pushes into the Gateway rail keyed to a single hub and ignores `(homeChain, lp)`

- **Subsystem:** Cross-hub rail
- **Contract:** `FxYieldRelay`
- **Location:** `contracts/src/hub/FxYieldRelay.sol:133-143`, `_pushHome` `:191-197`
- **Root cause:** `claimYieldFor` is permissionless, zeroes `lpRewards[k]`, then calls `_pushHome`, which ignores both `homeChain` and `lp` and unconditionally calls `hub.relayToRemoteHub(amount)` into one configured hub. The USDC enters the bearer-claim rail and is later minted to whichever relayer calls `relayMintFromRemote` — not cryptographically to the LP. On-chain accounting decrements the LP's reward as if delivered. `homeChainOf[k]` is written on stake but never read for routing.
- **Exploit scenario:** Anyone calls `claimYieldFor(homeChain, lpVictim)`; `lpRewards[victim]` is zeroed and pushed into the rail. On the destination hub a whitelisted (or compromised) relayer calls `relayMintFromRemote` and receives the USDC. The LP's on-chain reward is 0 but they received nothing on-chain. A griefer can batch-claim every LP at once.
- **Invariant broken:** #1 (attribution — reward marked paid without on-chain delivery to the LP).
- **Fix:** Bind the destination mint recipient to the LP via the BurnIntent recipient field; or keep funds claimable on the LP's home hub by the LP (pull pattern); or gate `claimYieldFor` to a trusted keeper and emit `(homeChain, lp, amount)` that the single trusted relayer must honor, documenting the trust assumption on-chain.
- **Verifier sharpening:** Attribution/delivery-guarantee gap, not theft-of-relay-funds — the relay's own balance stays solvent; CEI/nonReentrant prevent double-spend inside `FxYieldRelay`. Realistic loss bounded by accrued LP yield in flight and requires a dishonest/compromised whitelisted relayer or off-chain bookkeeping failure, not a permissionless drain. Griefing variant only forces premature settlement. Documented single-relayer trust boundary. Low.
- **Foundry PoC sketch:**
```solidity
function test_claimYield_doesNotDeliverToLp() public {
  relay.claimYieldFor(CHAIN, lp);
  assertEq(relay.pendingYieldFor(CHAIN, lp), 0); // marked paid, but no on-chain balance increase for lp
}
```

### F-23 — `TurboFeeVault` routes the entire 40% LP fee share to insurance whenever no LPs are staked (`totalShares==0`)

- **Subsystem:** Fee + rebate vaults
- **Contract:** `TurboFeeVault`
- **Location:** `src/hub/TurboFeeVault.sol:80-84`
- **Root cause:** In `depositFee`, when `totalShares==0` the `lpShare` (40%) is added to `insuranceBalance` instead of held for future LPs. Because `insuranceBalance` is drainable to the single admin EOA (F-10), every fee collected before the first LP stake permanently converts the LP reward stream into admin-controlled insurance. Even after LPs join, pre-stake LP rewards are unrecoverable to LPs.
- **Exploit scenario:** Fees flow via `depositFee` while `totalShares==0` → each call adds protocolShare (50%) to treasury and BOTH insuranceShare (10%) AND lpShare (40%) to `insuranceBalance` → admin later drains `insuranceBalance`, capturing 50% of fees through a path nominally earmarked for LPs.
- **Invariant broken:** None (solvency holds) — breaks the intended 50/40/10 split and the LP-rewards promise.
- **Fix:** When `totalShares==0`, accrue `lpShare` into a pending bucket folded into `rewardPerShareStored` on the first deposit (or escrow separately), or require a protocol-seeded minimal stake at deploy so `totalShares` is never 0 during fee ingress.
- **Verifier correction:** Severity overstated (low/informational). No invariant breaks; deliberate documented design (fees with no LPs route to insurance), and the only actor who can extract is the trusted `INSURANCE_ADMIN_ROLE` (its purpose, not escalation). The "live state silently captures all LP yield" framing is unsupported — **no `TurboFeeVault` address exists in any deployment manifest** and the live perp book is empty, so no fees flow now. `FxYieldRelay` is designed to hold the canonical position so `totalShares > 0` once the first cross-hub LP stakes. Narrow real issue: fees deposited **before** the first stake are unrecoverable to LPs.
- **Foundry PoC sketch:**
```solidity
function test_LpShareLostWhenNoStakers() public {
  assertEq(vault.totalShares(), 0);
  _seedFees(100e6);
  assertEq(vault.insuranceBalance(), 50e6); // 10 + 40, not 10
}
```

### F-24 — `TurboFeeVault` LP staking has no lock-up/cooldown — fee distributions can be JIT-sandwiched

- **Subsystem:** Fee + rebate vaults
- **Contract:** `TurboFeeVault`
- **Location:** `src/hub/TurboFeeVault.sol:80-84,92-104,106-120,122-131`
- **Root cause:** Rewards are distributed instantaneously per `depositFee` via `rewardPerShareStored` (lump-sum, not time-streamed); `deposit()`/`withdraw()`/`claimYield()` have no cooldown. Perp/swap fee deposits are predictable. An attacker can stake a large amount immediately before a known `depositFee` and unstake right after, capturing a pro-rata slice of that distribution that long-term LPs should have earned.
- **Exploit scenario:** Attacker observes a large pending `depositFee` → `deposit()`s a large amount → `depositFee` executes (rewardPerShare jumps, attacker owns most of the increment) → `claimYield()` + `withdraw()` next block. Diluting honest LP APY.
- **Invariant broken:** None (solvency holds) — fairness/economic integrity of LP rewards.
- **Fix:** Add a minimum staking duration or deposit→reward eligibility delay, or stream fee distributions over time (Synthetix `periodFinish`/`rewardRate`) instead of crediting the full `lpShare` instantly. A withdrawal cooldown also mitigates.
- **Verifier sharpening:** The self-trigger-via-wash-trade variant is economically irrational (attacker pays the full fee but recovers <40%). The passive sandwich is bounded by share-domination + parking large transient capital for one block — pure APY dilution, no principal at risk. The cross-hub path is immune (`FxYieldRelay` deposit/withdraw are SPOKE_ROLE-gated). Low.
- **Foundry PoC sketch:**
```solidity
function test_JitSandwichFeeDistribution() public {
  vm.prank(honest); vault.deposit(100e6);
  vm.prank(attacker); vault.deposit(10_000e6);
  _seedFees(1_000e6); // 400e6 lpShare
  vm.startPrank(attacker);
  uint256 y = vault.claimYield(); vault.withdraw(vault.shares(attacker));
  vm.stopPrank();
  assertGt(y, 360e6); // attacker took ~99%
}
```

### F-25 — `exitHub` redirects all CCTP-minted funds to an arbitrary caller-supplied recipient (exit-side bearer claim / fund redirection)

- **Subsystem:** Spoke + Hyperlane intents
- **Contract:** `FxSpoke`
- **Location:** `contracts/src/spoke/FxSpoke.sol:138-167`
- **Root cause:** `exitHub`/`_exitHubForToken` accepts a fully attacker-controlled `recipient` and, after `MessageTransmitter.receiveMessage`, transfers the entire measured balance delta (freshly-minted USDC/EURC) to that `recipient`. No binding between the CCTP message body and the `recipient` passed. Whoever submits the `(message, attestation)` pair to `exitHub` picks where the money lands. The only protection is CCTP's `destinationCaller`, but `exitHub` is permissionless: any address can call it and supply its own `recipient`, so `destinationCaller==spoke` is satisfied regardless of the real beneficiary.
- **Exploit scenario:** Hub burns USDC back with `mintRecipient = FxSpoke` (the documented redistribution design). Attacker watches Circle's public attestation API, then front-runs the legit relayer: `spoke.exitHub(cctpMessage, attestation, attackerAddr)`. The spoke mints to itself and forwards the full exit amount to the attacker.
- **Invariant broken:** #1 (funds reach their owner) — exit funds redirected away from the intended recipient.
- **Fix:** Do not trust a caller-supplied `recipient` for CCTP exits. Derive the recipient from a field the hub signed into the burn (encode in `hookData`, recompute keccak, mirroring `FxHubMessageReceiver.executeDeposit:298-301`), or require `destinationCaller == FxSpoke` AND restrict `exitHub` to a trusted relayer role AND read the real recipient from the message.
- **Verifier sharpening:** Conditional on the hub-side exit burn setting `mintRecipient = FxSpoke` (the documented design). If `mintRecipient = the end user`, the spoke's delta is 0 and `exitHub` reverts (`received == 0`) — no theft. If `destinationCaller = 0` (open) the attack is unconditional; if `= FxSpoke`, still exploitable (permissionless `exitHub`). **Correction:** the "sweeps idle tokens" claim is wrong — the balance delta equals exactly the minted amount; drop that part. Core unbound-recipient redirection stands. *(Verifier confirmed-severity: high. Listed under Low here per the per-finding `confirmedSeverity` field which records `low`; treat the loss-of-exit-funds impact as high-priority — see remediation note.)*
- **Foundry PoC sketch:**
```solidity
function test_exitHub_frontrun_redirect() public {
  bytes memory msg_ = mt.buildMintMessage(address(spoke), 1_000_000);
  bytes memory att  = mt.sign(msg_);
  vm.prank(attacker);
  spoke.exitHub(msg_, att, attacker);
  assertEq(usdc.balanceOf(attacker), 1_000_000); // stolen
  assertEq(usdc.balanceOf(bob), 0);
}
```

> **Note on F-25:** the JSON `confirmedSeverity` for this finding is `low`, but the verifier reasoning describes a high-impact loss-of-exit-funds redirection ("Loss = entire exit amount per message; breaks invariant 1"). The discrepancy is preserved verbatim from the input. **Recommendation: treat F-25 as High-priority remediation** — bind the recipient to the attested message before any exit-bearing CCTP flow goes live, regardless of the recorded label.

### F-26 — `executeRoutedIntent` does not bind delivered funds to the intent — any Accepted intent can consume the receiver's standing balance

- **Subsystem:** Spoke + Hyperlane intents
- **Contract:** `FxHyperlaneHubReceiver`
- **Location:** `contracts/src/hub/FxHyperlaneHubReceiver.sol:212-238, 333-343`
- **Root cause:** `executeRoutedIntent`/`_executeFromReceiverBalance` execute a token-funded intent against whatever `balanceOf(address(this)) >= inputAmount`. Funds a Warp route delivers are a fungible lump; nothing ties a delivery to a specific `intentId`. With multiple Accepted intents sharing `(origin, route, inputToken)`, the route can satisfy intent B (beneficiary=B) using funds delivered for intent A; over-/double-delivery / donation can be claimed by an unrelated Accepted intent. The only gate is `msg.sender == current.route` (a trusted/allowlisted route).
- **Exploit scenario:** Alice's Supply intent A (1,000,000 USDC, beneficiary Alice) is Accepted; attacker uses permissionless `sendIntent` to create intent B (same route+token, beneficiary=attacker), also Accepted. The Warp route delivers Alice's funds; if the route (by mistake/mis-ordering/bug) calls `executeRoutedIntent(B)`, the registry credits the Supply position to the attacker using Alice's delivered funds. Residual balance from a prior partial delivery can also be swept.
- **Invariant broken:** #1 (funds reach their owner) — conditional on a trusted route mis-selecting the intent.
- **Fix:** Bind delivered funds to the intent: deliver via a transfer-and-call naming the `intentId`, or snapshot `balanceOf` at handle/accept time and require the post-delivery **delta** equal `inputAmount` for THIS `intentId`. Track a per-token `creditedForIntent` ledger.
- **Verifier sharpening:** Not permissionless theft — `executeRoutedIntent` is gated by `msg.sender == current.route`, an admin-allowlisted route (the attacker cannot designate themselves or call it). Harm requires the trusted route to mis-select the `intentId`, plausible because the contract gives the route no on-chain way to know which `intentId` a delivery funded. Low (the trusted-route gate is load-bearing).
- **Foundry PoC sketch:**
```solidity
function test_routedIntent_crossConsumesDelivery() public {
  (bytes32 idA,) = _dispatchSupply(alice, 1e6);
  (bytes32 idB,) = _dispatchSupply(attacker, 1e6);
  mailbox.deliver(...idA...); mailbox.deliver(...idB...);
  usdc.mint(address(hub), 1e6); // route delivers ALICE's funds
  vm.prank(route); hub.executeRoutedIntent(idB);
  assertEq(registry.lastOnBehalf(), attacker);
}
```

### F-27 — `KawaiiRebateVault`: `allocate()` to a non-claiming address strands backed funds outside `recoverSurplus` reach

- **Subsystem:** Fee + rebate vaults
- **Contract:** `KawaiiRebateVault`
- **Location:** `src/hub/KawaiiRebateVault.sol:132-153`
- **Root cause:** `_allocate` rejects `address(0)` and `address(this)` but accepts any other address. If the allocator allocates to an address that cannot/will not `claim()` (contract without a claim wrapper, typo'd EOA, burn address), the amount moves from `unallocated` into `totalOutstanding` permanently. `recoverSurplus` can only sweep `balance − (unallocated + totalOutstanding)`, so those funds are unrecoverable forever.
- **Exploit scenario:** Keeper runs `allocateBatch` with a malformed/typo address → amount moves into `totalOutstanding` → that address never claims → `recoverSurplus` reserved includes the stranded amount → admin cannot recover it. Funds bricked. (Not a steal — permanent loss from the absence of a clawback for never-claimed/expired allocations.)
- **Invariant broken:** None (solvency holds) — permanent fund-lock / no misallocation recovery.
- **Fix:** Add an admin clawback for allocations unclaimed past a long grace window (allocation timestamp + N·VEST_DURATION) returning the remainder to `unallocated`, with an event, time-locked so it cannot rug live vesting holders.
- **Verifier sharpening:** Not attacker-reachable (`_allocate` is `onlyRole(REBATE_ALLOCATOR_ROLE)`); requires a trusted keeper fat-finger. Known/documented tradeoff (rejecting `address(this)` cites "codex audit LOW-3"; misallocation "stays a keeper-correctness concern, mitigated by off-chain validation"). The real gap is the absence of a time-gated clawback for stale/abandoned allocations (even a lost-key holder is permanently bricked). Low.
- **Foundry PoC sketch:**
```solidity
function test_MisallocationStranded() public {
  address dead = address(0xdead);
  vm.startPrank(keeper); usdc.approve(address(vault),50e6); vault.fund(50e6); vault.allocate(dead,50e6); vm.stopPrank();
  skip(vault.VEST_DURATION());
  vm.prank(admin); vm.expectRevert(KawaiiRebateVault.ZeroAmount.selector); vault.recoverSurplus(admin);
}
```

### F-28 — `getMid()` silently falls back Pyth → single-source RedStone, bypassing the confidence-band gate during market stress

- **Subsystem:** Oracle / pricing
- **Contract:** `FxOracle`
- **Location:** `contracts/src/hub/FxOracle.sol:185-193` (`getMid`), `331-338` (`_assertPythConfidence`); consumed at `MorphoOracleAdapter.sol:46`, `FxSwapHook.sol:731`, `SharedFxVault.sol:315`
- **Root cause:** `getMid()` wraps the Pyth read in `try this.getMidFromPyth(...) catch { fall through to RedStone }`. The catch is indiscriminate — it swallows EVERY Pyth revert including `OracleLowConfidence` and `OracleStale`, then switches to the RedStone-only path (no deviation cross-check, no confidence gate). The gate that protects against shaky prices is disabled precisely when Pyth flags uncertainty. `MorphoOracleAdapter.price()` (the live oracle for Morpho borrow/liquidation markets), `FxSwapHook.beforeSwap`, and `SharedFxVault._usdcNotional` all use `getMid`, not the strict `getMidVerified`. The `IFxOracle` docstring falsely claims `getMid` "Reverts on Pyth staleness or low confidence."
- **Exploit scenario (as written):** Pyth widens its confidence band past `maxConfidenceBps` → `getMidFromPyth` reverts → `getMid` swallows it and returns the RedStone-only mid with no cross-check → borrow/liquidate on Morpho at a price the protocol's own primary oracle just declared unreliable.
- **Invariant broken:** Indirectly #1 (solvency of Morpho-backed markets) and the "liquidation safety = two-source agreement" guarantee.
- **Fix:** Make `getMid` distinguish recoverable from non-recoverable failures: fall back to RedStone only on `OracleFeedUnknown`; propagate `OracleLowConfidence`/`OracleStale`. Better: route every money path through `getMidVerified`. If a single-source fallback must exist, make it a separate `getMidUnsafe` view no liquidation/borrow path consumes. Fix the docstring.
- **Verifier correction:** The high-impact "attacker manipulates unchecked RedStone during stress" path is **not reachable**, so severity drops to Low. The RedStone fallback only returns a value if the calling frame carries a valid 3-of-5 signed RedStone payload in `msg.data`; an attacker cannot forge or "nudge" it. The three money paths call `getMid` with clean ABI calldata and no appended payload, so on those paths a low-confidence Pyth makes `getMid` **revert** (fail-closed), not fail-open. Real residual issues: the docstring/spec mismatch, and a latent footgun for any future off-chain/relayer caller that appends a RedStone payload (skipping the gates and trusting a single still-authorized source). Low.
- **Foundry PoC sketch:**
```solidity
function test_getMid_fallsBackOnLowConfidence() public {
  mockPyth.setPrice(JPY_FEED, 669000, /*conf=*/ 50000, -8); // ~7.5% band >> 30bps
  oracle.setRedstoneFeed(JPYC, "JPY"); redstoneMock.set("JPY", attackerMid);
  (uint256 mid,) = oracle.getMid(JPYC, USDC); // does NOT revert; returns RedStone mid (on a payload-carrying frame)
  assertEq(mid, attackerMidComputed);
}
```

### F-29 — Local `messageNonce` key collides for identical deposits in the same block

- **Subsystem:** Spoke + Hyperlane intents
- **Contract:** `FxSpoke`
- **Location:** `contracts/src/spoke/FxSpoke.sol:129`
- **Root cause:** `messageNonce = keccak256(abi.encode(address(this), msg.sender, hookData, block.number))`. Two identical `enterHub` calls (same sender, beneficiary, hubCalldata) in the same block produce an identical `messageNonce`. The CCTP message has a unique Circle nonce; this key is only an emitted local-tracking identifier (no on-chain accounting depends on it — the sweep map lives on the hub keyed by the real CCTP nonce). UX/observability collision, not a fund issue.
- **Exploit scenario:** A user (or a batching UI) sends two identical `enterHub` calls in one block; both `Entered` events carry the same `messageNonce`; an off-chain tracker conflates them or a stranded-recovery UI mis-routes. No on-chain funds affected.
- **Invariant broken:** None (and explicitly not #5 — the hub sweep keys on the unique real CCTP nonce).
- **Fix:** Include a strictly-increasing per-spoke counter (or tx-level entropy) in the local key, or document that this field is a non-unique convenience identifier and the canonical key is the CCTP message nonce recomputed on the hub.
- **Verifier sharpening:** Accurate and correctly self-scoped. Lowest-effort fix is documentation; the off-chain canonical key is the CCTP nonce surfaced on the hub side, never this event field. Low.
- **Foundry PoC sketch:**
```solidity
vm.prank(alice); bytes32 n1 = spoke.enterHub(usdc, 1e6, bob, hex'dead');
vm.prank(alice); bytes32 n2 = spoke.enterHub(usdc, 1e6, bob, hex'dead');
assertEq(n1, n2); // same block, identical args -> colliding local nonce
```

### F-30 — `FxGhostKycHook` does not bind the KYC pass to the actual swapper/LP — a trusted router can satisfy the gate with any third party's valid pass

- **Subsystem:** Privacy pool + Ghost Mode
- **Contract:** `FxGhostKycHook`
- **Location:** `src/ghost/FxGhostKycHook.sol:198-213` (`_assertGhostAuthorized`), `:131-139` (`beforeAddLiquidity`), `:172-180` (`beforeSwap`)
- **Root cause:** The hook only checks (1) `msg.sender` (the v4 router) is in `trustedRouter` and (2) the `account` decoded from attacker-supplied `hookData` has a valid pass ≥ `minPassLevel`. No link between `account` and the economic beneficiary, funds source, or any nullifier/commitment. v4's `beforeSwap` cannot see the ultimate user; `account` is whatever bytes the router forwards. KYC enforcement collapses to "router is honest AND chooses to pass a real KYC'd account."
- **Exploit scenario:** Once a Ghost v4 pool is live, a trusted (or buggy) router forwards `hookData.account = <any address holding a valid Bufi pass>` while the real trader/LP is un-KYC'd; the hook passes. KYC/compliance gate bypassed for the actual counterparty.
- **Invariant broken:** None of the 5 (KYC is a Ghost-Mode compliance control).
- **Fix:** Bind the pass to a value the hook can authenticate: require the router to have verified the pass for THIS swap's beneficiary (and trust only that narrowly-scoped router), or carry a signed attestation in `hookData` tying `account` → this poolId/blockhash/nonce. Gate `trustedRouter` behind the timelock.
- **Verifier correction:** Downgraded to Low. Not reachable today — `FxGhostKycHook`/`trustedRouter`/`GhostHookData` appear only in source + unit test; no deploy script, no manifest, no `trustedRouter` ever set; the live privacy stack is a different zk system. The attack precondition is a TRUSTED router (`setTrustedRouter` is `onlyOwner`); passes are non-transferable (the named account must be a genuine onboarded party). Documented v1 intent delegates binding to the routers. Soft/trusted-party gate, defensible as v1, worth hardening before any Ghost v4 pool + trustedRouter goes live.
- **Foundry PoC sketch:**
```solidity
function test_hookPassesWithBorrowedPass() public {
  vm.prank(owner); hook.setTrustedRouter(router, true);
  passVerifier.setPass(kycdStranger, 1, true);
  bytes memory hd = abi.encode(FxGhostKycHook.GhostHookData({account: kycdStranger, commitment: 0, nullifierHash: 0}));
  vm.prank(address(poolManager));
  hook.beforeSwap(router, key, params, hd); // passes even though real trader is un-KYC'd
}
```

### F-31 — `FxLiquidator` sends its full collateral and debt-token balances to `msg.sender`, so stranded/donated tokens are stealable

- **Subsystem:** Spot executor + hedge
- **Contract:** `FxLiquidator`
- **Location:** `contracts/src/hub/FxLiquidator.sol:130-136`
- **Root cause:** After `MORPHO.liquidate`, the contract sweeps `collat.balanceOf(this)` and `debtToken.balanceOf(this)` to `msg.sender`. It is designed balance-zero between calls, but unconditionally pays out the entire current balance, not just this-call deltas. Any tokens left in the contract (a prior reverted-after-transfer flow, a mis-send, a donation) are claimable by anyone who calls `liquidate` with that token as collateral/loan.
- **Exploit scenario:** Someone accidentally transfers token X to `FxLiquidator` → attacker calls `liquidate()` on a registered market whose `collateralToken==X` with a tiny seize → Morpho seizes a negligible amount → the post-call sweep forwards the contract's entire X balance to the attacker.
- **Invariant broken:** #1 (minor, contract should retain no token).
- **Fix:** Track balances before `MORPHO.liquidate` and only transfer the per-call delta (`seized = collat.balanceOf(this) − collatBefore`; refund from amounts). Never forward pre-existing balances. Alternatively add a sweep-only admin function and transfer exactly `seized` + computed refund.
- **Verifier sharpening:** Correctly Low — `FxLiquidator` is a stateless conduit holding no owed/reserved claims; impact is bounded to accidentally stranded/donated dust (lost-and-found). Not a free sweep: `line 104` forces a nonzero seize/repay, so the attacker must execute a real liquidation against an actually-liquidatable borrower on a registered market whose collateral/loan token equals the stranded token, in the same tx. Hygiene-grade fix.
- **Foundry PoC sketch:**
```solidity
function test_liquidatorSweepsDonatedTokens() public {
  collateral.mint(address(liq), 1_000e18); // stranded
  uint256 before = collateral.balanceOf(attacker);
  vm.prank(attacker);
  liq.liquidate(address(loan), address(collateral), borrower, 1, 0, maxRepay, false, empty);
  assertGt(collateral.balanceOf(attacker), before + 999e18);
}
```

### F-32 — `FxRouter` trusts adapter's self-reported `buyAmount` instead of measuring recipient balance delta — a malicious adapter can under-deliver while passing the min-out check

- **Subsystem:** Routing + registries
- **Contract:** `FxRouter`
- **Location:** `contracts/src/hub/FxRouter.sol:226-237` (and `setSwapAdapter` `:331`)
- **Root cause:** `executeIntent` forwards `sellAmountNet` to the owner-settable `swapAdapter` and enforces slippage purely on the adapter's RETURN value (`buyAmount >= intent.minBuyAmount`). It never measures `intent.recipient`'s `buyToken` balance before/after. The recipient-protection invariant rests entirely on the adapter being honest. `swapAdapter` is mutable via `onlyOwner setSwapAdapter`; live `owner == treasury == KEEPER`. The production `FxRouterSwapAdapter` is currently safe (re-checks min-out in the v4 callback and `take()`s output to recipient), but the Router itself provides no defense-in-depth, and `FxFixedRateSwapAdapter` prices off the caller-claimed `sellAmountNet`, not a measured delta.
- **Exploit scenario:** KEEPER key compromise (or a future under-delivering adapter wired in) → `setSwapAdapter(maliciousAdapter)`. User submits a signed intent; Router pulls `sellAmount` via Permit2, skims fee, forwards `sellAmountNet`; the adapter keeps the sell token, transfers ~0 to recipient, and returns `buyAmount = intent.minBuyAmount`. Checks pass; `IntentExecuted` emitted; user debited, receives nothing.
- **Invariant broken:** None directly (router holds no standing inventory) — breaks the user-facing slippage/min-out guarantee.
- **Fix:** Measure recipient's `buyToken` balance delta around the adapter call inside `executeIntent` and require `(balAfter − balBefore) >= intent.minBuyAmount`, mirroring `FxPrivacyEntrypoint.relayCrossCurrency` (`AdapterUnderdelivered`). Treat the adapter return as advisory. Gate `setSwapAdapter` behind `FxTimelock`.
- **Verifier sharpening:** Low (defense-in-depth gap, not a live bug). Requires keeper-key compromise OR wiring a malicious adapter — both trusted-admin preconditions, and a compromised KEEPER already has strictly stronger primitives. Strongest evidence it is real: the in-repo inconsistency — `FxPrivacyEntrypoint.relayCrossCurrency` (calling the SAME adapter interface) measures recipient-side balance delta (`:356-361`, `RecipientUnderdelivered`); `FxRouter` does the inverse.
- **Foundry PoC sketch:**
```solidity
function test_MaliciousAdapterUnderDelivers() public {
  MaliciousAdapter mal = new MaliciousAdapter(); // returns minBuy, sends 0
  vm.prank(owner); router.setSwapAdapter(address(mal));
  uint256 recvBefore = buyToken.balanceOf(recipient);
  uint256 ret = router.executeIntent(intent, intentSig, permit, permitSig);
  assertEq(ret, intent.minBuyAmount);                    // check passes
  assertEq(buyToken.balanceOf(recipient), recvBefore);   // recipient got nothing
}
```

### F-33 — Funding payment scales by raw size, not notional — omits the FX price factor

- **Subsystem:** Perps
- **Contract:** `FxFundingEngine`
- **Location:** `src/perp/FxFundingEngine.sol:130-138` (`settleFunding`); index built at `:96-118`
- **Root cause:** `settleFunding` computes `fundingE18 = abs(size).mulDiv(abs(deltaIndex), 1e18)` = `size * (rate*time)`. Economically correct funding is notional-based: `notional * rate * time = size * price * rate * time`. The price is never multiplied in, so the charge is off by a factor of the pair price. The funding index is a dimensionless fraction-of-notional; applying it to raw size omits the price term.
- **Exploit scenario:** Admin configures a market whose oracle price is 0.5 or 10.0; funding accrued (calibrated as a fraction of notional via `skewBps`) is applied to raw size, so the actual margin debited/credited is off by ~2× or ~10× — distorting the skew-balancing incentive and long/short conservation.
- **Invariant broken:** None.
- **Fix:** Multiply by notional: `fundingE18 = notionalFromSize(abs(size), markPriceE18, ...).mulDiv(abs(deltaIndex), 1e18)` (or fold price into the index). Decide entry- vs mark-notional and document it. Add a test asserting long funding paid == short funding received for a price ≠ 1.0 market.
- **Verifier sharpening:** Not a theft vector — market config and funding params are `DEFAULT_ADMIN`-gated; price is from the oracle, not attacker-controlled; funding is symmetric so vault solvency is preserved. The "small for pairs near 1.0" framing undersells it — even canonical EUR/USD (~1.08) is ~8-10% understated on **every** settlement (always-on, not exotic-market). Low.
- **Foundry PoC sketch:**
```solidity
function test_FundingIgnoresPrice() public {
  mockOracle.setMid(2e18); // pair at 2.0
  int256 longPaid = funding.settleFunding(mkt, longTrader);
  int256 shortRecv = funding.settleFunding(mkt, shortTrader);
  assertEq(abs(longPaid), abs(shortRecv)); // conserved, but ~2x too small vs notional-based design
}
```

### F-34 — Maintenance margin uses fixed entry-price notional while equity uses current price — under-collateralizes losing shorts and delays liquidation

- **Subsystem:** Perps
- **Contract:** `FxHealthChecker`
- **Location:** `src/perp/FxHealthChecker.sol:66-72` (`maintenanceMargin` uses `p.entryPriceE18`), `:74-94` (`_equity` uses current-price `unrealizedPnl`)
- **Root cause:** `maintenanceMargin = notionalFromSize(abs(size), entryPriceE18) * maintenanceMarginBps` — pinned to entry price, never re-marked. Equity is marked to current price. For a losing short (price rose), current notional > entry notional, so the true maintenance requirement is higher than what is checked, making the position appear healthier and delaying liquidation; equity can drift further underwater before `isLiquidatable` flips, increasing socialized bad debt.
- **Exploit scenario:** Short opened at entry 1.0 (notional N); price rises 30% to 1.3 (mark-notional 1.3N); maintenance still computed on N, ~30% lower than it should be; the position stays classified not-liquidatable longer, so by the time `isLiquidatableVerified` returns true the equity deficit and `badDebt` are larger.
- **Invariant broken:** #1 (Solvency) indirectly — liquidation triggers later than the maintenance buffer intends.
- **Fix:** Compute maintenance notional from the current (verified) mark price, not entry: `notional = notionalFromSize(abs(size), markPriceE18)`. Standard Synthetix/GMX mark-based maintenance.
- **Verifier sharpening:** The threshold error is only the marginal term `maintenanceMarginBps * (currentNotional − entryNotional)` — for 5% maint and a 30% move, ~1.5% of notional, not 30%. Equity is still correctly marked down by the full mark loss; only the buffer threshold lags. The same entry-price notional convention is used elsewhere (OI reduction), plausibly a deliberate Synthetix-BFP-style convention. No attacker-controlled input, no direct profit. Low.
- **Foundry PoC sketch:**
```solidity
function test_MaintUsesEntryNotCurrent() public {
  mockOracle.setMid(1e18);
  uint256 m0 = health.maintenanceMargin(mkt, short);
  mockOracle.setMid(1.3e18);             // short now losing, exposure up 30%
  uint256 m1 = health.maintenanceMargin(mkt, short);
  assertEq(m0, m1);                      // BUG: maintenance unchanged despite larger live notional
}
```

### F-35 — `relayExecute` settle-back can over-forward the entrypoint's balance of a result token, and `InvalidPoolState` check runs before a result-token == sell-asset settle-back

- **Subsystem:** Privacy pool + Ghost Mode
- **Contract:** `FxPrivacyEntrypoint`
- **Location:** `src/hub/FxPrivacyEntrypoint.sol:438-448` (settle-back), `:433-434` (untrusted adapter return)
- **Root cause:** The settle-back forwards `min(_rt.balanceOf(this), _resultAmount)` of the adapter-REPORTED result token to the recipient AFTER the `InvalidPoolState` (sell-asset) check. Two gaps: (1) it uses the entrypoint's entire result-token balance as the upper bound, so any standing balance can be swept to this recipient; (2) there is no `resultToken != sellAsset` guard, so a result token equal to the pool/sell asset is transferred out **after** the sell-asset solvency check already passed, side-stepping `InvalidPoolState`. `relayCrossCurrency` blocks `buyToken==asset` (`:316`); `relayExecute` has no equivalent.
- **Exploit scenario:** Requires a registered (owner-trusted) execution adapter that returns an inflated `_resultAmount` or returns `(sellAsset, X)`. Not externally exploitable today (shipped adapters return tight values or `(0,0)`), but a future adapter reporting `(asset, large)` lets a small note's recipient receive the entrypoint's full asset balance, because the sell-balance invariant was checked before the settle-back.
- **Invariant broken:** #1 (defense-in-depth; only via a misbehaving trusted adapter).
- **Fix:** (1) Require `resultToken != asset` (mirror `relayCrossCurrency`'s `BuyTokenEqualsAsset`). (2) Measure the result token's balance delta across the adapter call and forward only that delta. (3) Move the `InvalidPoolState` check AFTER the settle-back (or re-assert post-settle when resultToken could touch sell-asset accounting).
- **Verifier corrections:** The "accrued withdrawFees not yet swept" premise is FALSE for this contract — fees are paid out immediately; it holds no protocol-fee balance to drain; the transfer is bounded by `min(balanceOf, _resultAmount)` (no synthetic over-mint). The substantive correct half is gap (2): `InvalidPoolState` runs before the result==sell-asset settle-back, and `relayExecute` lacks the `_resultToken != _asset` guard. Trusted-adapter-only, balance-bounded, no current exploit. Low.
- **Foundry PoC sketch:**
```solidity
function test_relayExecute_overForwardsStandingBalance() public {
  // pre-fund entrypoint with 500e6 buyToken; register adapter returning (buyToken, type(uint256).max);
  // execute a shielded note of 10e6; assert recipient received the entrypoint's full buyToken balance
}
```

### F-36 — Non-zero `vettingFeeBPS` silently makes deposited notes un-withdrawable under the fixed-denomination gate (gross vs net mismatch)

- **Subsystem:** Privacy pool + Ghost Mode
- **Contract:** `FxPrivacyEntrypoint`
- **Location:** `src/hub/FxPrivacyEntrypoint.sol:263-270` (gate on raw value); `lib/privacy-pools/contracts/Entrypoint.sol:330` (`_beforeDeposit` on PRE-fee `_value`), `:341-345` (commitment on POST-fee amount)
- **Root cause:** The denomination gate is enforced on the deposit's GROSS value, but the commitment (future withdrawable amount) is the NET value after `vettingFeeBPS`. A deposit of a denominated gross value creates a note whose value is a non-denominated net amount, which can never be fully withdrawn once the withdrawal-side gate is on. Today `vettingFeeBPS=0` everywhere, so it is latent; setting any vetting fee while the gate is enabled bricks full withdrawals of new notes.
- **Exploit scenario:** Governance enables a 50 bps vetting fee with the gate on; a user deposits 1000e6 (a denom); the note is worth 995e6 (not a denom); every full-withdraw reverts `NotADenomination`; the user can only withdraw denominated sub-amounts, leaving an un-withdrawable remainder.
- **Invariant broken:** None.
- **Fix:** Enforce the gate on the POST-vetting-fee amount that becomes the commitment, OR forbid `vettingFeeBPS > 0` while the gate is enabled (mutual-exclusion guard in `setDenominations`/`setVettingFee`).
- **Verifier corrections:** Not fully permanent — `ragequit()` lets the ORIGINAL DEPOSITOR withdraw the full note value with no denomination gate, so the net amount is always recoverable, but only via a **deanonymizing** ragequit (re-links the note to the depositor). Drainability via partial withdrawals depends on the fee: net amounts that are an integer sum of denominations drain fully (UX/anonymity degrade only); a fee leaving a sub-1e6 remainder (e.g. 33 bps → 0.7 USDC dust) is permanently un-withdrawable via any relay path. Owner-misconfiguration-gated, not attacker-triggerable. Low.
- **Foundry PoC sketch:**
```solidity
function test_vettingFeeBreaksDenomWithdraw() public {
  vm.prank(owner); ep.updatePoolConfiguration(usdc, 1e6, 50 /*bps*/, 500);
  ep.setDenominations(usdc, denomsIncluding1000e6);
  ep.deposit(usdc, 1000e6, precommit);          // note value = 995e6
  vm.expectRevert(NotADenomination); ep.relay(w,p,scope); // full withdraw of 995e6 bricked
}
```

---

## INFORMATIONAL

### F-39 — First-depositor share-inflation only mitigated by OZ virtual-shares offset 0; no dead-shares / minimum-deposit seed

- **Subsystem:** Vault core • **Contract:** `SharedFxVault` • **Location:** `SharedFxVault.sol:53-64` (no `_decimalsOffset` override), `:182-183`, `:248-255`
- **Root cause:** No `_decimalsOffset()` override (defaults to 0); OZ 5.0.2 virtual-shares mitigation active. Critically, `totalAssets()` reads tracked `seniorUsdcHot`/Morpho/gateway/adapter — **not** raw `balanceOf` — so a raw USDC donation does not move share price (the classic inflation lever is structurally removed). No dead-shares/seed/minimum first deposit.
- **Exploit scenario:** With `totalSupply()==0`, attacker deposits 1 wei, then would need NAV to grow via legit Morpho interest / keeper rounding (not attacker-controllable) for a victim's deposit to round down. Impact is rounding dust.
- **Invariant broken:** None (rounding/fairness).
- **Fix:** Before opening public deposits, seed a protocol first deposit and burn dead shares, or override `_decimalsOffset()` to ~3-6. Add a first-deposit inflation test.
- **Verifier correction:** Downgraded low → informational — no money-losing path: the donation lever is gone (balance-immune `totalAssets`) and NAV growth is not attacker-controlled. Real missing-best-practice, one-line fix.
- **PoC:** `function test_firstDepositRounding() public { vault.deposit(1, attacker); /* attacker cannot force NAV growth */ vault.deposit(2e6-1, victim); /* victim shares ~ fair */ }`

### F-40 — Multi-hook `recordInflow` donation/yield grief: first HOOK_ROLE caller claims any unaccounted token balance as its own junior slice

- **Subsystem:** Vault core • **Contract:** `SharedFxVault` • **Location:** `SharedFxVault.sol:326-354`, `:341-343`
- **Root cause:** `recordInflow` credits `balanceOf(this) − accounted` to `msg.sender`'s per-hook slice, where `accounted` is the GLOBAL total. Any token balance not yet booked is claimable by whichever allowlisted hook calls first. The live deployment has 4 `FxSwapHook`s (EURC/AUDF/MXNB/QCAD) sharing the USDC accounting.
- **Exploit scenario:** A direct USDC/FX donation is swept into whichever of the 4 hooks calls `recordInflow` first, mis-attributing first-loss capital between pools.
- **Invariant broken:** None hard; cross-hook junior isolation is partially porous for unaccounted balances.
- **Fix:** Pass+authenticate the intended hook/poolId, or have the hook assert the measured delta against its expected delta; only credit legs belonging to the caller's configured PoolKey.
- **Verifier correction:** Below low → informational. Leg (b) (untracked USDC between swaps) is FALSE — Morpho interest / yield-redeem / gateway-clear all credit `seniorUsdcHot` (booked, part of `accounted`); the only genuinely unaccounted balance is an unsolicited donation (no sweep/skim function exists). Solvency intact (`credited` bounded by real balance − real accounted; attacker can only gift), compliance wall untouched (junior excluded from `totalAssets`). Protocol-favorable, no loss.
- **PoC:** `function test_siblingHookClaimsStrayUsdc() public { usdc.mint(address(vault), 100e6); vm.prank(address(hookB)); assertEq(vault.recordInflow(address(usdc)), 100e6); }`

### F-41 — `TurboFeeVault.depositFee` credits split amounts from the requested `amount` rather than the measured balance delta (not fee-on-transfer safe)

- **Subsystem:** Fee + rebate vaults • **Contract:** `TurboFeeVault` • **Location:** `src/hub/TurboFeeVault.sol:64-88`
- **Root cause:** Unlike `KawaiiRebateVault.fund` (which credits the measured balance delta), `depositFee` distributes shares computed from `amount` directly. For a fee-on-transfer/deflationary token it would distribute more than received, breaking solvency. Gated safe today because `depositFee` reverts unless `token == USDC` and Arc USDC is not fee-on-transfer.
- **Exploit scenario:** No live exploit (token hard-restricted to USDC). Becomes a solvency bug only if USDC support is widened or a FoT token whitelisted.
- **Invariant broken:** None currently.
- **Fix:** Compute the split from `(balanceOf after − before)` like `KawaiiRebateVault.fund`. Document the USDC-only assumption if intentional.
- **Verifier sharpening:** Correctly informational. USDC is `immutable`, no `setToken`/whitelist setter exists, so the token set can never widen post-deploy. Caller role-gated (`FEE_DEPOSITOR_ROLE`) + `nonReentrant`. Latent defense-in-depth/consistency footgun, cheap fix.
- **PoC:** N/A on live config (reverts at the `token != USDC` guard).

### F-42 — `FxRouter.setPairAllowed` permits `sellToken == buyToken` (no self-pair guard)

- **Subsystem:** Routing + registries • **Contract:** `FxRouter` • **Location:** `contracts/src/hub/FxRouter.sol:316-320`
- **Root cause:** `setPairAllowed` rejects only the zero address, not `sellToken == buyToken`; `executeIntent` never asserts `sellToken != buyToken`. The downstream adapters DO guard with `SellEqualsBuy`, and `setRoute` rejects self-pairs, so an `(A,A)` route can never be enabled.
- **Exploit scenario:** Not externally exploitable — same-token swap reverts (atomically rolling back the Permit2 pull/fee skim); actually reverts with `RouteDisabled` first because no `(A,A)` route can exist. Purely a consistency gap.
- **Invariant broken:** None.
- **Fix:** Add `if (sellToken == buyToken) revert SellEqualsBuy();` in `setPairAllowed` (and optionally at the top of `executeIntent`).
- **Verifier sharpening:** The "fee-skim-then-revert" framing overstates it — the revert is fully atomic; nothing is skimmed. Doubly defended (`RouteDisabled` before `SellEqualsBuy`). Informational.
- **PoC:** `function test_SelfPairAllowed() public { vm.prank(owner); router.setPairAllowed(address(usdc), address(usdc), true); assertTrue(router.isPairSupported(address(usdc), address(usdc))); }`

### F-43 — `FxMarketRegistry` grants Morpho an unbounded (`type(uint256).max`) standing allowance via `_ensureApproval`

- **Subsystem:** Routing + registries • **Contract:** `FxMarketRegistry` • **Location:** `contracts/src/hub/FxMarketRegistry.sol:324-330` (called from supply/supplyCollateral/repay)
- **Root cause:** `_ensureApproval` sets the registry's allowance to MORPHO to `type(uint256).max` and leaves it standing. The registry holds tokens only transiently (pull-then-forward), so an unbounded approval to trusted Morpho Blue core is acceptable; the risk is conditional on `registerMarket`/`createAndRegisterMarket` (DEFAULT_ADMIN-gated, → FxTimelock in deploy scripts) ever registering a malicious/attacker-controlled token.
- **Exploit scenario:** No external exploit — Morpho is the only spender; the registry holds no idle balance; the only way a non-canonical token gets approved is via timelock-gated registration, with damage bounded by Morpho being the sole beneficiary + per-call `safeTransferFrom`.
- **Invariant broken:** None.
- **Fix:** Optionally scope the approval to the exact `needed` amount per call (the `forceApprove(needed)/forceApprove(0)` pattern), removing standing allowances. Confirm DEFAULT_ADMIN is the real FxTimelock on every live registry.
- **Verifier sharpening:** Standard gas-saving infinite-approval-to-trusted-spender pattern; inert because the registry holds no funds. The only residual nit: the max allowance persists after de-listing. Informational.
- **PoC:** `function test_RegistryHasMaxAllowanceToMorpho() public { registry.supply(address(usdc), address(eurc), 1e6, address(this)); assertEq(usdc.allowance(address(registry), address(morpho)), type(uint256).max); }`

### F-44 — `FxOracleV2` / `MorphoOracleAdapter`: decimals > 18 from a fallback aggregator underflows `10**(18 - dec)`; `ManualPriceFeed` accepts arbitrary constructor decimals

- **Subsystem:** Oracle / pricing • **Contract:** `FxOracleV2` / `MorphoOracleAdapter` / `ManualPriceFeed` • **Location:** `FxOracleV2.sol:110-111`; `MorphoOracleAdapter.sol:38`; `ManualPriceFeed.sol:32-35`
- **Root cause:** `_getMidFromChainlink` computes `price * 10**(18 - baseDec)`; for `decimals() > 18` this underflows on the unsigned exponent and reverts. `setChainlinkFeed` does no decimals sanity check; `ManualPriceFeed`'s constructor stores an arbitrary `uint8 dec`. `MorphoOracleAdapter.SCALE_FACTOR = 10**(36 + ld - cd)` reverts at deploy if `cd > 36 + ld`. Construction/config-time reverts (DoS), not value-extraction.
- **Exploit scenario:** Admin wires a Chainlink/Manual feed reporting >18 decimals → every `_getMidFromChainlink` for that token reverts; combined with F-28's fallthrough, the tertiary source is silently removed.
- **Invariant broken:** None (liveness/config robustness).
- **Fix:** Bound decimals (`require dec <= 18`) in `ManualPriceFeed`'s constructor and in `setChainlinkFeed` (read `agg.decimals()`); use a signed-exponent helper (mirror `FxOracle._toE18`) so `dec > 18` scales down rather than reverting.
- **Verifier correction:** Downgraded to informational — none of the inputs are attacker-controlled (all admin-gated/immutable); real FX aggregators and the project's own `ManualPriceFeed` use 8 decimals; fails closed (revert), not value-extraction. Defensive-coding gap.
- **PoC:** `function test_chainlinkDecimalsOver18Reverts() public { MockAgg agg = new MockAgg(19, 1e19); vm.prank(admin); v2.setChainlinkFeed(TOKEN, address(agg)); vm.expectRevert(); v2.getMid(TOKEN, USDC); }`

### F-45 — `FxHedgeHook` TWAP deviation circuit-breaker is bypassable on the first observation and uses an attacker-influenced implied spot price

- **Subsystem:** Spot executor + hedge • **Contract:** `FxHedgeHook` • **Location:** `FxHedgeHook.sol:300-319` (TWAP gate), `380-388` (`_updateTwap`), `337-378` (`_impliedSpotPrice`)
- **Root cause:** The 2% TWAP deviation pause is the only on-chain guard against rebalancing on a manipulated price. But (a) on the first observation `_updateTwap` seeds twap=spot so the gate trivially passes (first event unclamped); (b) the "spot price" is `_impliedSpotPrice` from the v4 `BalanceDelta` ratio with a dead `otherDecimals` heuristic and no decimal normalization; (c) for liquidity add/remove both deltas share a sign and `_impliedSpotPrice` returns 0, so the gate is skipped for the exact attacker-controlled add/remove flow (F-15).
- **Exploit scenario:** Attacker times the first hedge-relevant event (after deploy/unpause) to seed the TWAP arbitrarily, or uses LP add/remove (implied spot 0) so the gate is never evaluated.
- **Invariant broken:** None.
- **Fix:** Seed the TWAP from the oracle (the hook has the per-pool pythFeedId) and evaluate the gate even on the first observation against the oracle price; do not rely on the BalanceDelta-derived implied price; apply the gate to add/remove-driven exposure too (or exclude add/remove from hedge-target computation, which also fixes F-15).
- **Verifier corrections:** Severity overstated → informational. Breaks no hard invariant; the spot price never enters exposure/hedge-size math, so a manipulated spot cannot mis-size the hedge or move money — only fail to pause (false negative) or wrongly pause (recoverable DoS). The "removes the only on-chain brake" claim is FALSE — the clearinghouse independently enforces initial/maintenance margin, max leverage/OI/skew, and a maxFee cap; the TWAP gate is defense-in-depth on top. Sub-claim (b)'s mechanism is largely wrong (the variable is dead; the relative deviation comparison is internally consistent).
- **PoC:** `function test_twapGateSkippedForLiquidityEvents() public { vm.prank(poolManager); hook.afterAddLiquidity(attacker, key, _modifyParams(1), toBalanceDelta(-1e12, -2_000e18), ZERO, ""); assertFalse(hook.hedgePaused(poolId)); assertEq(hook.poolHedgeSizeE18(poolId), -2_000e18); }`

### F-46 — `FxHyperlaneHubReceiver.handle()` does not consult `interchainSecurityModule()`; ISM enforcement relies entirely on the Mailbox default ISM

- **Subsystem:** Spoke + Hyperlane intents • **Contract:** `FxHyperlaneHubReceiver` • **Location:** `FxHyperlaneHubReceiver.sol:128-135,160-163`
- **Root cause:** The contract implements `ISpecifiesInterchainSecurityModule` (operators believe they can harden per-recipient source verification), but `handle()` never reads `_interchainSecurityModule`; enforcement is delegated to the Mailbox calling `recipient.interchainSecurityModule()`. This is the canonical Hyperlane pattern and is safe **if** the Mailbox honors the recipient ISM — but `_interchainSecurityModule` defaults to `address(0)` (no constructor/initializer sets it), so the Mailbox falls back to its DEFAULT ISM (the weak `trustedRelayerIsm`, F-6). Nothing self-enforces a minimum.
- **Exploit scenario:** Operator deploys, sets `trustedSpokes`, assumes strong source verification because the contract advertises an ISM hook, never calls `setInterchainSecurityModule` → `_interchainSecurityModule` stays 0 → Mailbox uses the default `trustedRelayerIsm`.
- **Invariant broken:** None (defense-in-depth gap).
- **Fix:** Set a non-zero app-specific ISM in the constructor/initializer and revert `handle()` if `_interchainSecurityModule == address(0)` (fail-closed), or loudly document that the recipient inherits the Mailbox default ISM and gate go-live on a strong ISM.
- **Verifier correction:** "Low" overstates → informational. The independent `trustedSpokes[origin][sender]` allowlist (`:162`) authenticates the Hyperlane-supplied sender/origin regardless of which ISM ran — the default ISM governs whether the *relayer* is trusted to deliver, not whether an attacker can forge the sender field. Residual risk is narrow (no app-specific ISM aggregation), not "anyone can inject arbitrary intents." Contract is not referenced in any deploy script/manifest — a future-state hardening note.
- **PoC:** `assertEq(address(hub.interchainSecurityModule()), address(0)); // unset by default => Mailbox uses trustedRelayerIsm`

### F-47 — `relayExecute` binds `adapterId` (a mutable number) into the proof, not the adapter address — owner can re-point an in-flight execution

- **Subsystem:** Privacy pool + Ghost Mode • **Contract:** `FxPrivacyEntrypoint` • **Location:** `src/hub/FxPrivacyEntrypoint.sol:414-416`, `:235-242` (`registerExecutionAdapter` rotates an id)
- **Root cause:** The Groth16 proof commits to `ExecutionRelayData.adapterId` (a `uint256` index), but `executionAdapters[adapterId]` is owner-mutable. Between proof generation and relayer submission the owner can re-point `adapterId` to a different (malicious) adapter, and the user's `_amountAfterFee` is transferred to whatever the id currently resolves to. The doc comment claims "a relayer cannot redirect the execution" — true for relayers, but the OWNER can. For non-settle-back adapters (Morpho supply, perp margin) there is no economic backstop.
- **Exploit scenario:** Owner (already fully trusted: OWNER_ROLE + UUPS upgrade) re-points `adapterId 5` from `FxMorphoSupplyAdapter` to a malicious adapter just before a known relay, capturing the shielded funds.
- **Invariant broken:** None.
- **Fix:** Bind the adapter ADDRESS into `_withdrawal.data` (resolve+verify against the registry), or make adapter registration append-only / timelocked. Correct the comments to state the owner CAN redirect non-economically-bounded executions.
- **Verifier sharpening:** Strictly within existing owner trust (UUPS upgrade already permits arbitrary fund movement), so it adds no new privilege escalation and breaks no hard invariant — informational. `relayCrossCurrency`'s `swapAdapter` is the same class but economically backstopped (measured-delta + recipient-delta + `minBuyAmount`); `relayExecute`'s non-settle-back path is the genuinely backstop-free one.
- **PoC:** N/A (owner-trust; documentation/hardening).

### F-48 — `FxGhostCommitmentRegistry` nullifier/commitment state gates no funds and `consumeNullifier` has no on-chain consumer — false sense of double-spend protection

- **Subsystem:** Privacy pool + Ghost Mode • **Contract:** `FxGhostCommitmentRegistry` • **Location:** `src/ghost/FxGhostCommitmentRegistry.sol:141-147` (`consumeNullifier`), `:112-139` (`registerCommitment`); no `src` caller for `consumeNullifier`
- **Root cause:** The registry stores `commitmentRegistered`/`nullifierConsumed` and rejects duplicates, but nothing in the audited set consumes a nullifier or treats a registry commitment as authorization to move funds. Real double-spend protection lives in the vendored `PrivacyPool`/`State` (`State._spend`, `nullifierHashes`) behind the Groth16 verifier. The registry's "nullifier" is an arbitrary `bytes32` any authorized consumer can mark, with no cryptographic link to a note.
- **Exploit scenario:** No fund impact today (registry gates nothing). Forward-looking: if a future withdrawal router trusts `registry.nullifierConsumed` as the only double-spend guard, an authorized-consumer key could replay/withhold marks with no ZK binding.
- **Invariant broken:** None.
- **Fix:** Document that the registry is non-authoritative metadata and all spend-authority is the vendored pool's verifier + `State.nullifierHashes`; when the production verifier lands, consume nullifiers in the same tx/contract that verifies the proof.
- **Verifier sharpening:** Accurate and correctly informational. Add a code comment/assert that registry state is event-ledger-only and must never be the authoritative spend guard, with a NatSpec pointer to `State._spend`. Also note `commitmentRegistered` is only a uniqueness check (not deposit-finality).
- **PoC:** N/A (informational).

---

## 3. Remediation Checklist (ordered by severity)

**Critical**
- [ ] **F-1** Before any pool is bound to `TelaranaGatewayHubHook`: make `beforeSwap` collect input (`inputCurrency.take(...)`, return `toBeforeSwapDelta(+amountIn, -amountReceived)`, price from oracle). Until fixed, `clearPoolGatewayRoute` on all bindings and pause the hook.

**High**
- [ ] **F-2** Route `withdrawMargin` (and open/increase) through an equity-vs-maintenance check across all of a trader's open markets using the verified oracle; block withdrawals that leave equity < Σ maintenance.
- [ ] **F-3** Atomically transfer perp `FxOracle.DEFAULT_ADMIN_ROLE` to `FxTimelock` and renounce the deployer's role; add per-feed sanity guards/2-step change to `setPythFeedConfig`/`setFeed`.
- [ ] **F-4** Split privacy `ASP_POSTMAN` from `OWNER_ROLE` from the UUPS upgrader; move `OWNER_ROLE`/`_authorizeUpgrade` behind a multisig+timelock; rotate `ASP_POSTMAN` off the owner key now.
- [ ] **F-5** Enforce the USYC compliance wall on-chain in `SharedFxVault` (institutional-only gate on deposit/mint, OR remove `_yieldAdapterAssets` from retail `totalAssets`, OR split share classes); add a retail-`totalAssets`-invariant-to-USYC test — before opening public deposits.
- [ ] **F-6** Replace the live `trustedRelayerIsm` with a multisig/aggregation ISM and `setInterchainSecurityModule` to a real quorum before value-bearing Hyperlane traffic; separate the relayer key from the Gateway key; add per-intent acceptance cap/expiry.
- [ ] **F-25** (recorded `low`; high-impact) Bind the `exitHub` recipient to the attested CCTP message (`hookData`/`mintRecipient`) and/or gate `exitHub` with a trusted relayer role, before any exit-bearing CCTP flow goes live.

**Medium**
- [ ] **F-7** Cap `maxWithdraw`/`maxRedeem` at liquid+Morpho-withdrawable, or add a `_redeemSeniorFromYield` fallback in `_withdraw`; reconcile gateway-in-transit accounting against hook events.
- [ ] **F-8** Bind `relayMintFromRemote` to the originating relayer (per-relayer pending set) or parse the BurnIntent recipient on-chain; until then enforce single-relayer on-chain (revert if >1 whitelisted).
- [ ] **F-9** Split `KawaiiRebateVault` admin/allocator/funder/pauser across distinct keys (admin+pauser → multisig/timelock); add a per-epoch allocation cap.
- [ ] **F-10** Add an explicit payee param to `TurboFeeVault.insurancePayout`; route `INSURANCE_ADMIN_ROLE` to a multisig/timelock distinct from `DEFAULT_ADMIN`/treasury; optional per-call cap.
- [ ] **F-11** Move `KawaiiRebateVault` `PAUSER_ROLE` to a separate guardian; bound pause duration / exempt already-vested `claim()` from pause; route `unpause` to a multisig/timelock.
- [ ] **F-12** Do not delete the liquidation flag after a partial close unless the position is healthy; keep `flaggedAt` while the account remains liquidatable.
- [ ] **F-13** Bound `settleMatch` `fillPriceE18` to `getMidVerified` within `maxFillDeviationBps`; require MARKET orders to carry a slippage bound.
- [ ] **F-14** Move `FxRouter`/`FxRouterSwapAdapter`/`FxFixedRateSwapAdapter` ownership to `FxTimelock`; make `FxRouter` `Ownable2Step`; gate `setSwapAdapter` behind the timelock; separate non-keeper treasury.
- [ ] **F-15** Gate `executeHedge` (keeper role and/or per-pool cooldown + per-epoch notional cap + hysteresis); source exposure from `afterSwap`, not reversible LP add/remove.
- [ ] **F-16** Force the verified (deviation-gated) price path for hedge open/close (verified `openOrIncrease`/`decreaseOrClose` or RedStone-payload settlement).
- [ ] **F-17** Add an emergency hot-only withdrawal path for `FxPrivacyPool` and a circuit-breaker that forces 100%-hot without needing a Morpho withdraw to succeed; wrap deposit `_rebalance` in try/catch; snapshot the market id per `morphoShares`.
- [ ] **F-37** Move `TelaranaGatewayHubHook` route/proof/mailbox/pool-binding setters under `FxTimelock` (keep only `pause` on a fast OPERATIONS multisig); replace the single timelock proposer/executor with a ≥2-of-N multisig + distinct CANCELLER set; apply the same to `FxGatewayHook`.
- [ ] **F-38** Route `TelaranaGatewayHubHook.beforeSwap` through `_validatedRouteForMint` (or at minimum call `_verifyGatewayContextProof` + whitelistedCaller check) before minting; factor shared validation into one internal function.

**Low**
- [ ] **F-18** Move `setYieldAdapter`/`setOracle`/`setPoolManager` behind `FxTimelock`; bound `_yieldAdapterAssets` to deployed principal + a sane yield cap.
- [ ] **F-19** Re-wire the vault-backed swap fee to a fee accumulator routed via `feeVault.depositFee`, or remove the dead protocol-fee surface and document that spread accrues to junior LPs in-vault.
- [ ] **F-20** Revert `beforeSwap` when targets/`amountOut` are 0 before taking input; guard `_invertE18` against a zero denominator.
- [ ] **F-21** Add a `(sourceDomain, senderSpoke)` allowlist (with `CctpMessageLib` `sourceDomain()`/`sender()` readers) and validate in `executeDeposit`.
- [ ] **F-22** Make `_pushHome` consume `(homeChain, lp)` and bind the destination mint recipient to the LP (BurnIntent recipient) or switch to a pull pattern; gate `claimYieldFor` if push is kept.
- [ ] **F-23** Accrue `lpShare` into a pending bucket (fold into `rewardPerShareStored` on first stake) when `totalShares==0`, or seed a minimal protocol stake at deploy.
- [ ] **F-24** Stream `TurboFeeVault` distributions over time (`rewardRate`/`periodFinish`) or add a minimum-stake-duration / withdrawal cooldown.
- [ ] **F-26** Bind delivered funds to the intent (transfer-and-call with `intentId`, or post-delivery balance-delta == `inputAmount` for that id; per-token `creditedForIntent` ledger).
- [ ] **F-27** Add a time-gated admin clawback in `KawaiiRebateVault` for allocations unclaimed past a long grace window, returning the remainder to `unallocated`.
- [ ] **F-28** Make `getMid` catch only `OracleFeedUnknown` (rethrow `OracleLowConfidence`/`OracleStale`); fix the `IFxOracle` docstring; consider routing money paths through `getMidVerified`.
- [ ] **F-29** Add a per-spoke counter / tx entropy to the `FxSpoke` local key, or document it as a non-unique convenience identifier (canonical key = CCTP nonce on the hub).
- [ ] **F-30** Bind the KYC pass to a value `FxGhostKycHook` can authenticate (router-verified beneficiary or signed `account`→pool/nonce attestation); gate `trustedRouter` behind the timelock — before any Ghost v4 pool goes live.
- [ ] **F-31** Bound `FxLiquidator`'s payout sweep to per-call deltas (transfer only `seized` collateral and `maxRepayAssets − repaid` debt); never forward pre-existing balances.
- [ ] **F-32** Measure `intent.recipient`'s buyToken balance delta in `executeIntent` and assert `>= minBuyAmount`; treat the adapter return as advisory; gate `setSwapAdapter` behind the timelock.
- [ ] **F-33** Multiply funding by notional (`size * mark/entry price`) before applying `deltaIndex`, or bake price into the index; add a price≠1.0 long-paid==short-received test.
- [ ] **F-34** Compute maintenance notional from the current verified mark price, not entry price.
- [ ] **F-35** Add `resultToken != asset` guard in `relayExecute`; forward only the measured result-token delta; move/re-assert the `InvalidPoolState` check after the settle-back.
- [ ] **F-36** Enforce the denomination gate on the POST-vetting-fee amount, or forbid `vettingFeeBPS > 0` while the gate is enabled (mutual-exclusion guard).

**Informational**
- [ ] **F-39** Seed a dead-share at deploy (or override `_decimalsOffset()` to ~6) before opening public deposits; add a first-deposit inflation test.
- [ ] **F-40** Authenticate the intended hook/poolId in `recordInflow` (assert measured delta against the calling hook's configured legs); document that donations are first-come, first-credited.
- [ ] **F-41** Credit `TurboFeeVault.depositFee` splits from the measured balance delta; document the USDC-only assumption.
- [ ] **F-42** Add `require(sellToken != buyToken)` in `FxRouter.setPairAllowed` (and optionally `executeIntent`).
- [ ] **F-43** Optionally scope `FxMarketRegistry`'s Morpho approval to the exact `needed` amount; confirm DEFAULT_ADMIN is the real `FxTimelock` on every live registry.
- [ ] **F-44** Bound decimals (`<= 18`) in `ManualPriceFeed`'s constructor and `setChainlinkFeed`; use a signed-exponent scaler for `dec > 18`.
- [ ] **F-45** Seed `FxHedgeHook`'s TWAP from the oracle and evaluate the deviation gate on the first observation and on add/remove events.
- [ ] **F-46** Set a non-zero app-specific ISM in `FxHyperlaneHubReceiver`'s constructor and fail-closed in `handle()` if `_interchainSecurityModule == address(0)`, or gate go-live on a strong ISM.
- [ ] **F-47** Bind the adapter ADDRESS into the `relayExecute` proof (or make `registerExecutionAdapter` append-only/timelocked); correct the "relayer cannot redirect" comment to note the owner can.
- [ ] **F-48** Document/assert that `FxGhostCommitmentRegistry` state is event-ledger-only and never the authoritative spend guard; point NatSpec to `State._spend`.

---

## 4. Coverage & Caveats

### What was audited
- Static review of the 11 subsystems' Solidity source (vault core, `FxSwapHook`, cross-hub rail / CCTP receiver, fee+rebate vaults, oracle/pricing, routing+registries, perps stack, spot executor+hedge, spoke+Hyperlane intents, privacy pool+Ghost Mode, governance + `TelaranaGatewayHubHook`).
- Cross-referenced against the live deployment manifests (`deployments/*.json`) for role assignments, ISM wiring, and pool/route bindings, and against the project's own Foundry tests (several of which encode the buggy behavior as passing assertions, e.g. `SharedFxVaultCrossChainAccounting.t.sol`, the `TurboFeeVault` insurance tests, and `FxHubMessageReceiverRelay.t.sol`).
- Vendored libraries reviewed where load-bearing: OZ `ERC4626Upgradeable`/`TimelockController`/`AccessControl` 5.x, `lib/v4-core` `Hooks`/`Pool`, `lib/privacy-pools` `Entrypoint`/`PrivacyPool`/`State`, Morpho Blue `withdraw` liquidity guard, RedStone `PrimaryProdDataServiceConsumerBase`.

### What could NOT be fully verified without a fork or external-dep behavior
- **Invariant #4 (Gateway exclusivity):** not independently verified in this pass; F-1/F-8/F-10 touch the rail but no global "only `FxGatewayHook` moves cross-hub USDC" invariant was asserted. Needs a fork test enumerating every `gatewayMint`/`relayToRemoteHub` caller.
- **F-1 end-to-end value drain:** confirmed at the `BeforeSwapDelta` shape level; the existing test uses a mock PoolManager that does not perform real swap netting, so the full empty-pool v4 settlement drain must be reproduced against a real `PoolManager` fork to demonstrate the credited `+amountReceived`.
- **F-28 (oracle fallback):** confirmed fail-closed on the three money paths only because they carry no RedStone payload; a fork test driving an actual Pyth low-confidence tick through `MorphoOracleAdapter.price()`/`FxSwapHook.beforeSwap` should confirm the revert (and test any relayer-style caller that DOES append a payload).
- **F-17 (Morpho liquidity DoS) and F-16 (Pyth-mark manipulation):** depend on live Morpho utilization / Pyth confidence-band dynamics; need a mainnet/testnet fork against the real Morpho market and Pyth feed.
- **Deployment-claim discrepancies:** several raw findings cited deployment JSON line numbers/files that do not exist in the repo (`arc-testnet.json:73`, `arc-testnet.json:223-224`, no `turbo-fee-vault-*.json` in manifests). The corresponding code-level findings stand; the deployment-state claims should be re-checked against the actual live configuration before relying on the "latent vs live" framing.

### Recommended next steps
1. **Fork tests** for F-1 (real `PoolManager` empty-pool settlement), F-28 (Pyth low-confidence through Morpho/swap paths), F-16/F-17 (real Pyth + Morpho market).
2. **Invariant / fuzz campaigns to add:**
   - Perp solvency: fuzz `deposit/open/priceMove/withdrawMargin/liquidate` sequences and assert `protocolLiquidity` is never spent on socialized bad debt that a pre-withdraw health gate would have prevented (catches F-2, F-12, F-34).
   - Vault compliance wall: assert retail-tier `totalAssets()` is invariant to any USYC price/balance change (catches F-5) and that `maxWithdraw`/`maxRedeem` never advertise more than reachable liquidity (catches F-7).
   - Gateway exclusivity invariant (#4): assert no contract outside the sanctioned path calls `gatewayMint`/`relayToRemoteHub`.
   - Fee accounting: assert the 50/40/10 split is preserved for all `totalShares` states and that `insuranceBalance` only grows by funds actually received (catches F-23, F-41).
3. **Governance hardening pass before mainnet:** enumerate every privileged setter across all contracts, confirm each is behind `FxTimelock` (multisig proposer + distinct executor) or a fast OPERATIONS multisig as appropriate, and assert no single EOA holds admin+keeper+treasury+pauser+proposer+executor (the recurring root cause behind F-3, F-4, F-9, F-10, F-11, F-13, F-14, F-18, F-37).
4. **Adapter-interface consistency:** standardize recipient-delta measurement across `FxRouter`, `FxPrivacyEntrypoint.relayExecute`, and `relayCrossCurrency` so the strongest existing pattern (`RecipientUnderdelivered`) is uniform (catches F-32, F-35).
