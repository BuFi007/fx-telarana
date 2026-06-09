# Security Remediation — fx-Telaraña

Tracking the disposition of every finding in [`AUDIT_REPORT.md`](./AUDIT_REPORT.md).
Branch: `fix/audit-remediation`.

**Disposition legend**
- ✅ **fixed (code)** — Solidity change landed on this branch, with a fails-before/passes-after PoC.
- 🔧 **code affordance + ops** — code change adds the missing lever (timelock-gated setter, configurable
  recipient, etc.); the actual key rotation / multisig wiring is a **deploy/ops action** listed below.
- 🚀 **deploy/ops only** — no code defect; remediation is a deployment/key-management action.
- ⏸ **excluded** — explicitly deferred by the owner (compliance wall).
- ⬜ **pending** — not yet started.

> **Test baseline note:** the unit suite is 600/601 green. The single failure
> `AvalancheBasketSmoke::test_basketDeploySeedAndSwapMatrix (UseVault())` is **pre-existing on
> the base branch** (reproduced on a clean checkout before any remediation edit) and is unrelated
> to this work. CLAUDE.md's "42/42" baseline is stale; the suite has grown to 601 tests.

---

## Critical

| ID | Title | Disposition | Notes |
|----|-------|-------------|-------|
| F-1 / F-38 | `TelaranaGatewayHubHook.beforeSwap` free-USDC drain + skipped proof/whitelist | ✅ fixed (code) | `beforeSwap` now requires `sender == route.whitelistedCaller` (non-zero) and runs `_verifyGatewayContextProofMemory`; collects input via `inputCurrency.take(...)` and returns `toBeforeSwapDelta(+amountIn, -amountReceived)`. PoC: `test_beforeSwap_revertsWhen_callerNotWhitelisted`. Commit `aaaa382`. **Full empty-pool drain still warrants a real-PoolManager fork test (see Caveats §4 of the report).** |

## High

| ID | Title | Disposition | Notes |
|----|-------|-------------|-------|
| F-2 | `withdrawMargin` ignores unrealized PnL → socialized bad debt | ⬜ pending | Route withdraw/open through an equity-vs-maintenance gate using the verified oracle. |
| F-3 | Oracle `DEFAULT_ADMIN` = keeper EOA, feed setters un-timelocked | 🔧 code affordance + ops | Add per-feed sanity guard / 2-step feed change; **transfer admin → FxTimelock at deploy** (ops). |
| F-4 | Privacy `Entrypoint` single-EOA owner+postman, UUPS-drain | 🚀 deploy/ops only | Vendored `lib/privacy-pools`; split roles + multisig+timelock upgrader, rotate ASP_POSTMAN (ops). |
| F-5 | Compliance wall not enforced in `SharedFxVault` | ⏸ excluded | **Deferred by owner.** Do not implement. |
| F-6 | Hyperlane single `trustedRelayerIsm` | 🚀 deploy/ops only | Replace with multisig/aggregation ISM before value-bearing traffic; add per-intent cap/expiry (code, see F-26). |
| F-25 | `exitHub` redirects CCTP funds to caller-supplied recipient | ✅ fixed (code) | `exitHub`/`exitHubForToken` now gated to `owner` + `exitRelayer[]` allowlist (`setExitRelayer`), closing the permissionless front-run. PoC: `test_exitHub_revertsForUntrustedCaller` / `test_exitHub_relayerCanSettle`. **Follow-up:** full on-chain recipient↔message binding needs the hub-side exit burn to encode the recipient in `hookData` (cross-contract; deferred). |

## Medium

| ID | Title | Disposition | Notes |
|----|-------|-------------|-------|
| F-7 | `totalAssets()` counts unreachable USYC/in-transit → redeem DoS | ⬜ pending | **Cap `maxWithdraw`/`maxRedeem` at reachable liquidity ONLY** (no `totalAssets` USYC change — that's the excluded F-5). |
| F-8 | `relayMintFromRemote` bearer front-run | ⬜ pending | Bind mint to originating relayer / parse recipient; else enforce single-relayer on-chain. |
| F-9 | `KawaiiRebateVault` 4-roles-one-EOA | 🔧 code affordance + ops | Add per-epoch allocation cap (code); split roles (ops). |
| F-10 | `TurboFeeVault.insurancePayout` pays `msg.sender` | ⬜ pending | Add explicit `to` payee; route role to multisig (ops). |
| F-11 | `KawaiiRebateVault` pauser can freeze vested claims | ⬜ pending | Exempt vested `claim()` from pause or bound pause duration. |
| F-12 | Partial-liquidation flag reset re-arms `flagDelay` | ⬜ pending | Don't delete flag unless post-close position is healthy. |
| F-13 | Keeper-settled fills have no oracle band | ⬜ pending | Bound `fillPriceE18` to `getMidVerified` ± `maxFillDeviationBps`. |
| F-14 | Router/adapters owner = keeper EOA, no timelock | 🔧 code affordance + ops | `Ownable2Step` on `FxRouter`; ownership → timelock (ops). |
| F-15 | Permissionless `executeHedge` drains protocol margin | ⬜ pending | Gate caller + per-pool cooldown/cap; source exposure from `afterSwap`. |
| F-16 | Hedge open/close uses lenient `getMid` | ⬜ pending | Force verified price path for hedge. |
| F-17 | Privacy pool Morpho coupling DoS | ⬜ pending | Hot-only emergency withdrawal + no-revert force-hot. |
| F-37 | Hook route/proof/Gateway-authority setters bypass timelock | 🔧 code affordance + ops | Setters → `DEFAULT_ADMIN`==timelock; multisig proposer/executor (ops). |

## Low

| ID | Title | Disposition | Notes |
|----|-------|-------------|-------|
| F-18 | Untimelocked `setYieldAdapter`/`setOracle`/`setPoolManager` | 🔧 code affordance + ops | Behind timelock; bound `_yieldAdapterAssets`. |
| F-19 | Dead protocol-fee sleeve in vault-backed hook | ⬜ pending | Wire fee accumulator or remove dead surface + document. |
| F-20 | Zero-target swap takes input for zero out; `_invertE18(0)` | ⬜ pending | Revert before taking input when targets/amountOut == 0. |
| F-21 | `executeDeposit` accepts any source domain/sender | ⬜ pending | `(sourceDomain, senderSpoke)` allowlist + lib readers. |
| F-22 | `FxYieldRelay` yield not bound to `(homeChain, lp)` | ⬜ pending | Bind mint recipient to LP or pull pattern. |
| F-23 | `TurboFeeVault` routes LP share to insurance when no stakers | ⬜ pending | Pending bucket folded on first stake. |
| F-24 | `TurboFeeVault` no stake cooldown → JIT sandwich | ⬜ pending | Stream distributions / min-stake duration. |
| F-26 | `executeRoutedIntent` funds not bound to intent | ⬜ pending | Per-intent balance-delta / `creditedForIntent` ledger. |
| F-27 | `KawaiiRebateVault` allocate to non-claiming addr strands funds | ⬜ pending | Time-gated admin clawback. |
| F-28 | `getMid` silently single-sources on Pyth low-confidence | ⬜ pending | Catch only `OracleFeedUnknown`; rethrow confidence/staleness; fix docstring. |
| F-29 | `FxSpoke` local `messageNonce` collision | ⬜ pending | Per-spoke counter / document as non-canonical. |
| F-30 | `FxGhostKycHook` pass not bound to swapper | ⬜ pending | Bind pass to beneficiary; gate `trustedRouter` behind timelock. |
| F-31 | `FxLiquidator` sweeps full balance to caller | ⬜ pending | Bound payout to per-call deltas. |
| F-32 | `FxRouter` trusts adapter `buyAmount` vs measured delta | ⬜ pending | Measure recipient balance delta. |
| F-33 | Funding scales by raw size, not notional | ⬜ pending | Multiply by notional / fold price into index. |
| F-34 | Maintenance margin uses entry-price notional | ⬜ pending | Use current verified mark price. |
| F-35 | `relayExecute` over-forwards result-token balance | ⬜ pending | `resultToken != asset` guard + measured delta. |
| F-36 | Non-zero `vettingFeeBPS` bricks denominated withdraws | ⬜ pending | Gate on post-fee amount or mutual-exclusion guard. |

## Informational

| ID | Title | Disposition | Notes |
|----|-------|-------------|-------|
| F-39 | First-depositor share inflation (offset 0) | ⬜ pending | Seed dead-share / `_decimalsOffset` before public deposits. |
| F-40 | Multi-hook `recordInflow` donation grief | ⬜ pending | Authenticate caller's configured legs. |
| F-41 | `TurboFeeVault.depositFee` not fee-on-transfer safe | ⬜ pending | Credit measured balance delta. |
| F-42 | `FxRouter.setPairAllowed` allows self-pair | ⬜ pending | `require(sellToken != buyToken)`. |
| F-43 | `FxMarketRegistry` unbounded Morpho approval | ⬜ pending | Optionally scope to `needed`. |
| F-44 | Oracle decimals > 18 underflow; `ManualPriceFeed` unchecked dec | ⬜ pending | Bound decimals ≤ 18; signed-exponent scaler. |
| F-45 | `FxHedgeHook` TWAP gate bypassable on first obs | ⬜ pending | Seed TWAP from oracle; gate add/remove. |
| F-46 | `handle()` doesn't consult `interchainSecurityModule()` | ⬜ pending | Set app ISM; fail-closed on zero. |
| F-47 | `relayExecute` binds mutable `adapterId`, not address | ⬜ pending | Bind adapter address into proof. |
| F-48 | `FxGhostCommitmentRegistry` non-authoritative state | ⬜ pending | Document/assert event-ledger-only. |

---

## Deployment & key-management actions (cannot be closed in Solidity)

The recurring root cause across F-3, F-4, F-6, F-9, F-10, F-11, F-13, F-14, F-18, F-37 is that the
deployer/keeper EOAs `0x0646…` / `0xcA02…` collapse admin + keeper + treasury + pauser + proposer +
executor across the vault, fee/rebate vaults, router, oracle, hooks, and the timelock itself. Before
mainnet:

- [ ] Transfer every contract's `DEFAULT_ADMIN_ROLE` / `owner` to `FxTimelock`, and renounce the
      deployer's role (the pattern the cirBTC oracle already followed; the perp oracle did not).
- [ ] Configure `FxTimelock` with a **multisig proposer set** and a **distinct executor** (or open
      execution) — not a single EOA holding proposer + executor + canceller.
- [ ] Split operational roles onto distinct keys: ALLOCATOR = keeper, FUNDER = treasury,
      PAUSER/admin = guardian multisig.
- [ ] Rotate privacy `ASP_POSTMAN` off the owner key; put the UUPS upgrader behind multisig+timelock.
- [ ] Replace the Hyperlane `trustedRelayerIsm` with a multisig/aggregation ISM and separate the
      Hyperlane relayer key from the Gateway burn-intent signer key.
- [ ] Re-check the deployment-state claims the auditor flagged as unverifiable
      (`turbo-fee-vault-*.json`, `arc-testnet.json` line refs) against the actual live config.
