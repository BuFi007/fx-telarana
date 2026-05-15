# fx-Telaraña — 10B TVL stress audit (Fuji post-migration hub)

**Date:** 2026-05-14
**Auditor:** criptopoeta (Claude Opus 4.7 via `/claude-tenderly-auditor` v1.0.0)
**Adversarial pass:** Not yet run — invoke `/codex-adversarial-tenderly-auditor` to challenge.
**Revision:** v1.1 — Gateman post-review (see §Revision history). All §Summary PASS rows are explicitly conditioned on §Staging artefacts (mock 1:1 oracle, mock CCTP transmitter). Read those before citing any PASS.

Public-grade defensive audit of fx-Telaraña's Hub-and-Spoke money market over Morpho Blue, after migrating the hub from Base Sepolia to Avalanche Fuji. Methodology stress-tests every protocol surface (ERC-4626 receipt wrapper, leveraged borrow + interest accrual, liquidation + bad-debt realization, CCTP V2 hub receiver) at $1B-per-position scale and surfaces overflow / design risks with actionable patches.

> **Gateman framing.** Every PASS in this report is PASS-under-staging. The staging artefacts are listed exhaustively. If a staging mock does not hold in production (e.g. real Pyth payloads, real CCTP attestations), the corresponding PASS does NOT carry over. The Production-oracle delta table (§Methodology) enumerates the operational differences.

---

## Environment

| Field | Value |
|---|---|
| Vnet ID | `5ea52b4d-fe5a-4026-828c-d9b8fa08cec6` (slug `fx-telarana-fuji-post-migration`) |
| Fork chain | Avalanche Fuji (43113) @ block `0x34ca6ce` (55,361,742) |
| Admin RPC | `https://virtual.avalanche-testnet.eu.rpc.tenderly.co/<REDACTED>` |
| Public RPC | `https://virtual.avalanche-testnet.eu.rpc.tenderly.co/<REDACTED>` |
| Dashboard | `https://dashboard.tenderly.co/criptopoeta/bufi/testnet/5ea52b4d-fe5a-4026-828c-d9b8fa08cec6` |
| Pre-audit snapshot | `0x3f3836dc5790bcc0de93a5febb29bfe226cee70b62cef8f2123706d574c529ae` (clean fork, persona unfunded) |
| Pre-S3 snapshot | `0x41526eedb50a944d6220eacdc7fe2dc67f3e52f46dd208956ffa7f37150594ca` (post-S2 primed state, before liquidation crash) |
| Pre-S5-partial snapshot | `0x4c8a9c0e15f20cac105e4a432f9bd3b4cb63edf0f781d6a7346851150676f133` (post-S5 4-nonce, before partial-pull nonce 42) |
| Network gate | 43113 ∈ allow-list ✓ (NOT 43114 Avalanche mainnet — refuse-list) |

**Test persona:** `0x1111111111111111111111111111111111111111` — primed to **10B USDC** + **10B EURC** + **100 AVAX** via MCP `set_erc20_balance` + `fund_account`. Reproduction commands in §Reproducer.

**Contracts under audit** (read from `deployments/hub-config-fuji.json` + verified `extcodesize > 0` on vnet):

| Role | Address | Source |
|---|---|---|
| `FxHubMessageReceiver` | `0x365DE300dDa61C81a33bcE3606A5d524eD964362` | `contracts/src/hub/FxHubMessageReceiver.sol` |
| `FxMarketRegistry` | `0x7ba745b979e027992ecfa51207666e3f5b46cf0a` | `contracts/src/hub/FxMarketRegistry.sol` |
| `FxOracle` | `0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b` | `contracts/src/hub/FxOracle.sol` |
| `MorphoOracleAdapterM1` | `0xda4c3e315fffd0790c9d8a1730c2ba56330cb2ec` | `contracts/src/hub/MorphoOracleAdapter.sol` |
| `MorphoOracleAdapterM2` | `0xf0cdaa9cf9e8d52060dcb41a045e3a6d618a9f65` | `contracts/src/hub/MorphoOracleAdapter.sol` |
| `FxReceiptEURC` (M1 supply) | `0xefd7cf5ad5a2db9a3c23e2807f2279de92c730d2` | `contracts/src/hub/FxReceipt.sol` |
| `FxReceiptUSDC` (M2 supply) | `0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e` | `contracts/src/hub/FxReceipt.sol` |
| `FxLiquidator` | `0x2900599ff0e6dd057493d62fac856e5a8f93c6eb` | `contracts/src/hub/FxLiquidator.sol` |
| `MorphoBlue` (self-deployed) | `0xeF64621D41093144D9ED8aB8327eE381ECdB79E6` | morpho-blue v1.1 |
| `IrmMock` (linear) | `0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA` | `contracts/src/test-helpers/IrmMock.sol` |
| `MockEURC` | `0x50c4ba39caa7f56152d0df4914e1f6b907194992` | mock |
| `USDC` (Circle Fuji) | `0x5425890298aed601595a70AB815c96711a31Bc65` | Circle FiatTokenV2_2 proxy |
| `CctpMessageTransmitterV2` | `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` | Circle V2 |

**Key on-chain parameters read live** (NOT from env):

| Param | Value (raw) | Decoded |
|---|---|---|
| `LLTV` (both M1 + M2) | `0x0bef55718ad60000` | **86%** |
| `M2.marketParams.loanToken` | `0x5425890298aed601595a70ab815c96711a31bc65` | USDC |
| `M2.marketParams.collateralToken` | `0x50c4ba39caa7f56152d0df4914e1f6b907194992` | MockEURC |
| `M2.marketParams.irm` | `0x0b5d18bbe92f07ec0111ae6d2e102858268d6aca` | IrmMock |
| `MorphoOracleAdapterM2.price()` (post-stage) | `0x...0c097ce7bc90715b34b9f1000000000` | **1e36** (mock 1 EURC = 1 USDC) |
| USDC decimals | `0x06` | 6 |
| EURC decimals | `0x06` | 6 |
| FxReceiptUSDC `_decimalsOffset()` (inferred) | (OZ default) | **0** — see R1 |

## Storage layout pins (Step 0.5)

Generated via `forge inspect src/hub/<Contract>.sol:<Contract> storageLayout` from `contracts/` (foundry 1.5.1). Raw output captured at `/tmp/storage-layouts/<Contract>.txt` and reproduced inline below — pasted, not inferred:

```
=== FxHubMessageReceiver ===
| Name      | Type                                                             | Slot | Offset | Bytes |
| _deposits | mapping(bytes32 => struct IFxHubMessageReceiver.StrandedDeposit) | 0    | 0      | 32    |

=== FxReceipt ===
| Name          | Type                                            | Slot | Offset | Bytes |
| _balances     | mapping(address => uint256)                     | 0    | 0      | 32    |
| _allowances   | mapping(address => mapping(address => uint256)) | 1    | 0      | 32    |
| _totalSupply  | uint256                                         | 2    | 0      | 32    |
| _name         | string                                          | 3    | 0      | 32    |
| _symbol       | string                                          | 4    | 0      | 32    |
| _marketParams | struct MarketParams                             | 5    | 0      | 160   |

=== FxMarketRegistry ===
| Name        | Type                                                      | Slot | Offset | Bytes |
| owner       | address                                                   | 0    | 0      | 20    |
| _marketIdOf | mapping(address => mapping(address => bytes32))           | 1    | 0      | 32    |
| _paramsOf   | mapping(bytes32 => struct IFxMarketRegistry.MarketParams) | 2    | 0      | 32    |

=== FxLiquidator ===
(stateless — no storage slots)
```

`StrandedDeposit` value-type packing (from `IFxHubMessageReceiver.sol:54-59`):

| Inner field | Type | Bytes | Packed slot (relative) |
|---|---|---|---|
| `beneficiary` | address | 20 | slot N, offset 0 |
| `amount` | **uint96** | 12 | slot N, offset 20 |
| `strandedAt` | uint64 | 8 | slot N+1, offset 0 |
| `state` | DepositState (uint8) | 1 | slot N+1, offset 8 |

Overflow candidates and packed-storage fields touched at audit scale:

| Contract | Slot | Field | Type | Headroom @ audit scale |
|---|---|---|---|---|
| `Morpho.market[id]` | (packed) | `totalSupplyAssets` | uint128 | `1.7e23×` over observed 2e15 |
| `Morpho.market[id]` | (packed) | `totalSupplyShares` | uint128 | `1.7e17×` over observed 2e21 |
| `Morpho.market[id]` | (packed) | `totalBorrowAssets` | uint128 | `4.0e23×` over observed 8.59e14 |
| `Morpho.market[id]` | (packed) | `totalBorrowShares` | uint128 | `4.0e17×` over observed 8.59e20 |
| `Morpho.market[id]` | (packed) | `lastUpdate` | uint128 | year 1.08e25 (effectively ∞) |
| `Morpho.market[id]` | (packed) | `fee` | uint128 | not exercised |
| `FxHubMessageReceiver._deposits[nonce]` | N+0 | `beneficiary` | address | n/a |
| `FxHubMessageReceiver._deposits[nonce]` | N+0 (packed) | **`amount`** | **uint96** | max **~7.9e28 raw** = ~7.9e22 USDC — see R5 |
| `FxHubMessageReceiver._deposits[nonce]` | N+1 (packed) | `strandedAt` | uint64 | year 5.8e11 (∞) |
| `FxHubMessageReceiver._deposits[nonce]` | N+1 (packed) | `state` | DepositState enum (uint8) | 0/1/2/3 |

Layout dump pins ensure any `setStorageAt` op references a verified slot, not a guessed one. Cited slots match `forge inspect` output, not source-code inference.

---

## Summary

Every result is conditioned on §Staging artefacts. Production-oracle delta (Pyth+RedStone live) is enumerated under §Methodology → "Production-oracle delta".

| # | Case | Result (staged) | Concurrency / scale | Trace |
|---|---|---|---|---|
| S1 | 1B USDC supply → ERC-4626 share math | **PASS (staged oracle 1e36)** | sequential, 1 actor | [link](https://dashboard.tenderly.co/criptopoeta/bufi/testnet/5ea52b4d-fe5a-4026-828c-d9b8fa08cec6/tx/avalanche-fuji/0xb01ecf8d2639042a6c473c280965fc15a8850c15ce67042e1be171c3fef47935) |
| S2 | 1B EURC collateral + 859M USDC borrow @ 85.9% LTV; ~266 s accrual | **PASS (staged oracle 1e36, IrmMock linear)** | sequential, 1 actor | [link](https://dashboard.tenderly.co/criptopoeta/bufi/testnet/5ea52b4d-fe5a-4026-828c-d9b8fa08cec6/tx/avalanche-fuji/0x72f72fc0cadb6a3a357eee7a302475236f5f23101a388ef362aad405047e393b) |
| S3 | 1B underwater liquidation via FxLiquidator + bad-debt realization | **PASS (staged oracle 0.5e36 crash)** | single liquidator | [link](https://dashboard.tenderly.co/criptopoeta/bufi/testnet/5ea52b4d-fe5a-4026-828c-d9b8fa08cec6/tx/avalanche-fuji/0xc6aac974483527c73db337b72c677d6174849ccac769ee18520bb9863e43884d) |
| S4 | 500M USDC→EURC swap via FxSwapHook (UR V4_SWAP) | **BLOCKED** (hook not on Fuji) | — | — |
| S5a | `executeDeposit` 4 nonces, zero-pull leftover branch (Codex Patch #2) | **PASS (mock transmitter)** | sequential 4 calls; **block-gas ceiling ~82 cold / 91 warm** per block (see §S5) | [link](https://dashboard.tenderly.co/criptopoeta/bufi/testnet/5ea52b4d-fe5a-4026-828c-d9b8fa08cec6/tx/avalanche-fuji/0xf2d8380ab7f48c0fe160e4f8483bb4b83f49678afb15e594d65adc21113f7308) |
| S5b | `executeDeposit` partial-pull (Registry.supply(50M of 100M)) | **PASS (mock transmitter)** | single tx, asserts Stranded amount = 50M leftover | [link](https://dashboard.tenderly.co/criptopoeta/bufi/testnet/5ea52b4d-fe5a-4026-828c-d9b8fa08cec6/tx/avalanche-fuji/0x495272b9f47b7c721f9d23bc645ead87969c9dbc1f35ba4712c5294eb1a4d2fa) |
| S6 | Re-run 128-sim regression matrix on Fuji vnet | **DEFERRED** | — | — |
| S7a | uint128 **shares**-side overflow probe (`setStorageAt totalSupplyShares=MAX → supply(1)`) | **PASS — graceful Panic(0x11) revert demonstrated** | 6-decimal underlying only; shares-side path only | (simulation `1f8098c9…d3a`; not chain tx) |
| S7b | uint128 **assets**-side overflow probe (`setStorageAt totalSupplyAssets=MAX → supply(1)`) | **PASS — graceful Panic(0x11) revert demonstrated** | 6-decimal underlying only; assets-side path | (simulation — see §S7b) |

**Risks surfaced:** **7 actionable** (R1–R7) + **1 open question** (Q8) requiring adversarial pass. See §Overflow + design risks.

> **Reading guide.** The original brief said *1000 concurrent enterHub*. The measured per-call gas (181,638 cold / 164,538 warm) combined with Avalanche Fuji's 15M block-gas limit caps real concurrency at **~82 cold / 91 warm per block**. S5 therefore covers (a) receiver-internal invariants for 4 sampled nonces + 1 partial-pull, and (b) a per-call gas measurement that pins the production concurrency ceiling. It does NOT cover 1000-in-one-block behaviour, which is physically impossible on the target chain.

---

## Methodology

This audit was produced by `/claude-tenderly-auditor` v1.0.0. The skill prescribes:

1. Snapshot-first (Tenderly Pattern G) before any destructive op.
2. Storage-layout pinning via `forge inspect` for every contract under audit.
3. Live-state inventory (`extcodesize > 0`, constructor params via getter calls, market params via `idToMarketParams`).
4. Persona priming via MCP `set_erc20_balance` + `fund_account`.
5. Staged externals (mock 1e36 oracle, mock CCTP MessageTransmitter) where the live fork lacks fresh data — every mock documented in §Staging artefacts so results are reproducible.
6. Per-case state-mutation through `send_vnet_transaction` with `simulate_vnet_transaction` first to capture return data + revert reason.
7. Trace-driven debug: `find_vnet_failures` → `get_vnet_error_path` → 4-byte selector resolution against repo `error` declarations, `cast sig`, 4byte directory.
8. Overflow analysis: from Step 0.5 layout dump, compute headroom factor (`type_max / observed_max`) for every packed field touched at audit scale.

**Out of scope:** mainnet behavior, gas-price economics, MEV / sandwich attacks (those belong to `/codex-adversarial-tenderly-auditor`), formal verification, optimizer-driven equivalence proofs, Phase 2.5 swap hook math (the constant-spread MVP currently shipped on Base Sepolia is acknowledged as not production-ready by the codebase's `Phase 2.5:` markers).

### Production-oracle delta

Every PASS in this report is staged behind a hand-installed 41-byte mock oracle returning fixed `1e36` (or `0.5e36` for S3). The production path (`MorphoOracleAdapter` → `FxOracle` → Pyth Hermes + RedStone signed payloads) introduces failure modes the staged path does NOT exercise:

| Path | Staged behavior (this audit) | Production behavior (live Fuji) | Delta a PASS does NOT cover |
|---|---|---|---|
| `MorphoOracleAdapter.price()` | Returns exactly `1e36` (or `0.5e36`) every call | Calls `FxOracle.getMid()` → Pyth `getPriceUnsafe` + RedStone `getOracleNumericValueFromTxMsg` | Pyth feed staleness (max age check), RedStone signature validity, deviation gate, fallback ordering |
| `updatePriceFeeds` | Not called — mock has no update path | Required before any liquidation if `useVerified=true`; pulls fresh Hermes payload (~500B calldata, ~50k gas) | Real liquidations need a Pyth payload in the same tx; gas + relayer mechanics not measured |
| Calldata-tail RedStone | Not exercised — mock ignores msg.data tail | RedStone `evm-connector` requires signed payload appended to calldata; missing payload reverts `CalldataMustHaveValidPayload() = 0xe7764c9e` | Any caller must wrap calls with RedStone SDK helper — failure mode for naive callers |
| Oracle deviation gate | Not invoked | `FxOracle.getMidVerified` cross-checks Pyth vs RedStone; > 50 bps spread reverts | Cross-oracle disagreement during oracle stress; gate behavior at extreme markets |

The above means: **S1/S2/S3/S5 PASS rows hold receiver-internal + Morpho-internal invariants. They do NOT validate the production oracle pipeline.** A separate oracle-pipeline audit pass — ideally with a freshened Pyth feed and live RedStone payload — is required to clear the production read path. Listed as R7 below.

---

## Staging artefacts (REPRODUCIBILITY)

Every mutation that diverges from a clean fork is listed here in execution order. The audit is INVALID without re-applying these in order.

| # | Op | Target | Value | Reason |
|---|---|---|---|---|
| 1 | `snapshot_vnet` | — | `0x3f3836dc…c529ae` | Clean-fork rewind point |
| 2 | `set_erc20_balance` | `whale @ USDC` | `0x2386F26FC10000` (10B raw, 6 dec) | Whale fund |
| 3 | `set_erc20_balance` | `whale @ MockEURC` | `0x2386F26FC10000` (10B) | Whale fund |
| 4 | `fund_account` | `whale` | `0x56BC75E2D63100000` (100 AVAX) | Gas |
| 5 | `tenderly_setCode` (admin RPC) | `MorphoOracleAdapterM2` `0xf0cd…9f65` | 41-byte stub returning `0xc097ce7bc90715b34b9f1000000000` (1e36) | Pyth feed stale on fork (`0xe7764c9e CalldataMustHaveValidPayload()` from RedStone fallback). Mock 1:1 oracle for deterministic stress math. **Staging only — NOT a finding.** |
| 6 | `tenderly_setCode` (admin RPC) | `MorphoOracleAdapterM1` `0xda4c…cb2ec` | same 1e36 stub | M1 oracle parity |
| 7 | (S2 case) `Morpho.supplyCollateral` + `Morpho.borrow` | M2 | 1B EURC collateral, 859M USDC borrow | Primes the borrow position |
| 8 | `snapshot_vnet` | — | `0x41526eed…0594ca` | Pre-S3 snapshot (rewind point for liquidation case) |
| 9 | (S3 case) `tenderly_setCode` | `MorphoOracleAdapterM2` | new 41-byte stub returning `0.5e36` (`0x604be73de4838ad9a5cf8800000000`) | Crash oracle 50% to push whale's position underwater for S3 liquidation. **Staging only.** |
| 10 | (S5a case) `tenderly_setCode` | `CctpMessageTransmitterV2` `0xE737…CE275` | 95-byte mock: on any call, `USDC.transfer(msg.sender, 1e14)` + return `0x01` | Real CCTP V2 attestations can't be forged on single-chain vnet. Mock matches `receiveMessage(bytes,bytes)` return shape. **Staging only.** |
| 11 | (S5a case) `set_erc20_balance` | `CctpMessageTransmitterV2 @ USDC` | `0x2386F26FC10000` (10B) | Pre-fund mock so it can "mint" 100M per `executeDeposit` |
| 12 | `snapshot_vnet` (pre-S5b) | — | `0x4c8a9c0e…676f133` | Branch point for S5b partial-pull variant |
| 13 | (S5b case) `executeDeposit` nonce=42 with `hubCalldata = Registry.supply(USDC, EURC, 50M, whale)` | `FxHubMessageReceiver` | tx `0x495272b9…1a4d2fa` | Exercises Codex Patch #2 partial-pull branch (registry consumed 50M of 100M, leftover 50M Stranded). |

---

## Case S1 — 1B USDC supply → ERC-4626 share math at scale

**Hypothesis:** `FxReceiptUSDC` is a thin ERC-4626 wrapper around a Morpho Blue supply position. At 1B USDC scale, share/asset math must hold 1:1 in a fresh vault (no rounding leakage on full unwind, no off-by-one between Morpho's `expectedSupplyAssets` and the wrapper's `totalAssets`).

**Setup:**
1. Restore from `0x3f3836dc…c529ae`, apply staging artefacts #2–#6
2. Whale approves `FxReceiptUSDC` for USDC (max)
3. Whale calls `FxReceiptUSDC.deposit(1e15, whale)` — supplies 1B USDC
4. `increase_time(12)` + `mine_block` — one block elapses for rebase observation
5. Whale calls `FxReceiptUSDC.withdraw(5e14, whale, whale)` — pulls back 500M
6. Whale calls `FxReceiptUSDC.redeem(5e14, whale, whale)` — redeems remaining shares

**State snapshots:**

| State | totalAssets | totalSupply | whale fxUSDC | whale USDC | Morpho.balanceOf(USDC) |
|---|---|---|---|---|---|
| Initial | `0` | `0` | `0` | `10B` | `0` |
| After `deposit(1B)` | `1e15` | `1e15` | `1e15` | `9B` | `1e15` |
| After +1 block (lazy accrue no-op — no borrows) | `1e15` | `1e15` | `1e15` | `9B` | `1e15` |
| After `withdraw(500M)` | `5e14` | `5e14` | `5e14` | `9.5B` | `5e14` |
| After `redeem(500M shares)` | `0` | `0` | `0` | `10B` | `0` |

**Asserts:**

- ☑ `previewDeposit(1e15) = 1e15` (1:1 fresh-vault ratio)
- ☑ `convertToShares(5e14) = 5e14` mid-state (confirmed before withdraw)
- ☑ `convertToAssets(5e14) = 5e14` mid-state
- ☑ Morpho-side `expectedSupplyAssets` exactly matches receipt `totalAssets` (no off-by-one)
- ☑ Full unwind returns whale to baseline `10B USDC` (zero leakage)
- ☑ Receiver's totalSupply burns to 0; no zombie shares

**Result:** **PASS** — 1:1 share ratio holds through full roundtrip at 1B scale. Lazy-accrue is a no-op as expected when `totalBorrow=0`.

**Traces:**
- approve: `0x737ee53cf2c527baa2625e2b6439668bc857d3eba9031f9e8b170e12a2d54905`
- deposit(1B): `0xb01ecf8d2639042a6c473c280965fc15a8850c15ce67042e1be171c3fef47935`
- withdraw(500M): `0xde400af478150150828ae5b1e2b0e7538fdb06acbce0e58782e89383338944e4`
- redeem(500M shares): `0xb554444c8697c9d0211a16ae27d7290645ef7c9558e366a70ea44738f0953bc5`

**Per-case headroom analysis:**

| Field | Type | Max | Observed | Headroom |
|---|---|---|---|---|
| `Morpho.market.totalSupplyAssets` | uint128 | `3.4028e38` | `1e15` | `3.4e23×` |
| `Morpho.market.totalSupplyShares` | uint128 | `3.4028e38` | `1e15` | `3.4e23×` (no virtual-share boost yet — fresh vault) |
| `FxReceiptUSDC.totalSupply` | uint256 | `2^256-1` | `1e15` | `1.16e62×` |

**Risks surfaced (this case):** R1 — see §Risks.

---

## Case S2 — 1B EURC collateral + 859M USDC borrow at 85.9% LTV

**Hypothesis:** At LLTV - ε (86% market LLTV → borrow at 85.9%), the position is barely solvent. IrmMock is linear so per-second rate scales with utilization; rebase must propagate from Morpho to the ERC-4626 wrapper via `expectedSupplyAssets`.

**Setup:**
1. Restore from clean fork + staging artefacts #2–#6
2. Whale approves EURC for Morpho (max)
3. Whale calls `FxReceiptUSDC.deposit(2e15, whale)` — supplies **2B USDC** (provides borrow liquidity)
4. Whale calls `Morpho.supplyCollateral(M2_params, 1e15, whale, "")` — supplies **1B EURC** collateral
5. Whale calls `Morpho.borrow(M2_params, 859e12, 0, whale, whale)` — borrows **859M USDC**
6. `increase_time(200)` + `mine_block` + `Morpho.accrueInterest(M2_params)`
7. Re-read market state

**State snapshots:**

| State | Field | Pre-borrow | Post-borrow | After 266s + accrue | Δ |
|---|---|---|---|---|---|
| M2 | `totalSupplyAssets` | `2e15` | `2e15` | `2,000,003,111,946,688` | `+3,111.95 USDC` |
| M2 | `totalSupplyShares` | `2e21` | `2e21` | `2e21` | `0` (shares preserved, value bumps) |
| M2 | `totalBorrowAssets` | `0` | `8.59e14` | `859,003,111,946,688` | `+3,111.95 USDC` |
| M2 | `totalBorrowShares` | `0` | `8.59e20` | `8.59e20` | `0` |
| Whale | `collateral` | `0` | `1e15` | `1e15` | unchanged |
| Whale | `borrowShares` | `0` | `8.59e20` | `8.59e20` | unchanged |
| FxReceiptUSDC | `totalAssets` | `2e15` | `2e15` | `2,000,003,111,946,687` | **rebase +1.56 ppm** |
| FxReceiptUSDC | share price | `1.000000` | `1.000000` | `1.0000015560` | `+1.56 ppm` |

Derived metrics:

| Metric | Value |
|---|---|
| LTV at origination | `borrow / collateral = 859e12 / 1e15 = 85.90%` |
| Market utilization | `42.95%` |
| Elapsed | `266 s` (one `increase_time` + `mine_block` + 1 accrueInterest tx) |
| Implied per-second borrow rate | `1.362e-8` |
| **Annualized borrow APR** | **42.9795%** (linear IRM: rate ≈ utilization × 100% slope) |

**Asserts:**

- ☑ Borrow at exactly 85.9% (1 bp under LLTV) succeeds, NOT reverts (Morpho check is `LTV ≤ LLTV`)
- ☑ IrmMock returns linear rate ≈ utilization × WAD (annualized 42.98% APR at 42.95% utilization)
- ☑ `expectedSupplyAssets` propagates accrual to the wrapper (rebase captured)
- ☑ `fee = 0` → 100% of interest accrues to suppliers (no Morpho fee skim)
- ☑ No uint128 overflow on packed market state (headroom 1.7e17× on shares)

**Result:** **PASS** — leveraged borrow at LLTV - ε holds; interest accrual deterministic; wrapper rebase captures the supply-side gain.

**Traces:**
- supply 2B USDC: `0x4af712bc5f29009e003bb43702ed3c7d2165bd083313b0ae96ad68300656b877`
- supplyCollateral 1B EURC: `0x5d5fb03c9e37e99f8345b5d3fbf25c51581f15c7143a0ec2a6ccf75407e21411`
- borrow 859M USDC: `0x72f72fc0cadb6a3a357eee7a302475236f5f23101a388ef362aad405047e393b`
- accrueInterest: `0x801440ac86a715226b8e6682407c27771800862ac06e6267243073ab57ec0dd0`

**Per-case headroom analysis:**

| Field | Type | Max | Observed | Headroom |
|---|---|---|---|---|
| `Morpho.market.totalSupplyShares` | uint128 | `3.4028e38` | `2e21` (1e6 virtual-share boost) | `1.7e17×` |
| `Morpho.market.totalBorrowShares` | uint128 | `3.4028e38` | `8.59e20` | `4.0e17×` |
| `Morpho.market.totalSupplyAssets` | uint128 | `3.4028e38` | `2e15` | `1.7e23×` |

**Practical TVL ceiling — empirically demonstrated** (see §S7 below):

| Underlying decimals | Raw `uint128` max (`totalSupplyShares`) | Effective shares (post-1e6 virtual boost) | Practical human-unit ceiling | At indicative $/token | Practical USD ceiling |
|---|---|---|---|---|---|
| **6** (USDC, AUDF, MXNB, PHPC) | `2^128 - 1 ≈ 3.4e38` | `≈3.4e32` | `3.4e26` USDC (÷ 10^6 decimals) | $1.00 | **~$3.4e26** |
| **18** (BRLA, JPYC, ZCHF) | `2^128 - 1 ≈ 3.4e38` | `≈3.4e32` | `3.4e14` token-units (÷ 10^18 decimals) | $0.20 (BRL) | **~$6.8e13** |

Same uint128 slot, two ceilings ~12 orders of magnitude apart. 6-decimal stables have effectively infinite headroom; 18-decimal stables have a finite-but-astronomical $68T-ish per-stable ceiling. Listed under R2 as defence-in-depth.

**Risks surfaced (this case):** R2 — see §Risks.

---

## Case S3 — 1B underwater liquidation + bad-debt realization

**Hypothesis:** With a sudden 50% oracle crash, whale's 1B EURC / 859M USDC position becomes ~172% LTV. `FxLiquidator.liquidate(useVerified=false, pythUpdate=[])` should seize the full collateral, repay proportional debt, refund the unused `maxRepayAssets` (Codex-patch invariant), and Morpho should realize the residual bad debt by reducing `totalSupplyAssets` in the same block.

**Setup:**
1. Restore from `0x41526eed…0594ca` (post-S2 primed state)
2. Apply staging artefact #9 — crash M2 oracle from `1e36` to `0.5e36` (1 EURC = 0.5 USDC)
3. Whale approves `FxLiquidator` for USDC (10B — over-approve to exercise the refund path)
4. Whale calls `FxLiquidator.liquidate(USDC, EURC, whale, seizedAssets=1e15, repaidShares=0, maxRepayAssets=1e15, useVerified=false, pythUpdate=[])`

**State snapshots:**

| State | Field | Pre-crash | Post-crash (oracle-only) | Post-liquidation |
|---|---|---|---|---|
| Oracle | `MorphoOracleAdapterM2.price()` | `1e36` | `0.5e36` | `0.5e36` |
| Position | whale.LTV | 85.9% | **171.8%** (deeply underwater) | n/a (cleared) |
| M2 | `totalSupplyAssets` | `2,000,003,111,946,688` | unchanged | `1,620,000,000,000,002` |
| M2 | `totalSupplyShares` | `2e21` | unchanged | `2e21` (unchanged; share price crashes instead) |
| M2 | `totalBorrowAssets` | `859,003,111,946,688` | unchanged | `0` (cleared via bad-debt realization) |
| M2 | `totalBorrowShares` | `8.59e20` | unchanged | `0` |
| Whale | `collateral` | `1e15` | unchanged | `0` (fully seized) |
| Whale | `borrowShares` | `8.59e20` | unchanged | `0` |
| Whale | USDC balance | 8,859,000,000 | unchanged | 8,379,999,999.999998 (paid 479M USDC repay; refund 521M of the 1B approval) |
| Whale | EURC balance | 9,000,000,000 | unchanged | 10,000,000,000 (received 1B EURC seizure since whale = self-liquidator) |
| FxReceiptUSDC | share price | 1.0000015560 | unchanged | **0.8100000000** |

**Liquidator-returned values:**

| Field | Hex | Decimal | Interpretation |
|---|---|---|---|
| `seized` (EURC) | `0x38d7ea4c68000` | `1,000,000,000,000,000` | Full 1B EURC seized |
| `repaid` (USDC) | `0x1b3a5e0d8f002` | `479,000,000,000,002` | ~479M USDC paid |
| Implied bonus | — | **4.3841%** | Matches Morpho LIF formula |

**Bad-debt math:**

| Field | Value |
|---|---|
| Pre-liq debt | 859,003,111,946,688 (859M USDC) |
| Repaid in liquidation | 479,000,000,000,002 (479M USDC) |
| **Bad debt realized** | **380,003,111,946,686 (~380M USDC)** |
| Pre-liq supply assets | 2,000,003,111,946,688 |
| Post-liq supply assets | 1,620,000,000,000,002 |
| **Supplier haircut** | **19.0001%** in one block |

**LIF formula verification:**

| Variable | Value |
|---|---|
| Morpho V1.1 `LIF(lltv)` formula | `min(MAX_LIF, WAD / (WAD - α × (WAD - lltv)))` |
| α (default) | `0.3` |
| lltv | `0.86` |
| `1 - lltv` | `0.14` |
| `α × (1 - lltv)` | `0.042` |
| `WAD / (WAD - 0.042)` | `1.04384133611691...` |
| **Implied bonus** | **4.3841%** ✓ matches observed |

**Asserts:**

- ☑ Codex-patched `maxRepayAssets` cap held: caller transferred 1B USDC upfront, Morpho consumed 479M, FxLiquidator refunded 521M unused USDC ✓
- ☑ `useVerified=false` + empty `pythUpdate` correctly bypasses the in-tx oracle update branch (the `pythUpdate.length > 0` gate)
- ☑ Morpho still reads the (mocked) adapter price during health check — no second oracle pathway
- ☑ `seizedCollateral = 1e15 EURC` fits comfortably under uint128 (1.7e17× headroom)
- ☑ Bad debt realized atomically: `totalSupplyAssets -= 380M` in the same block the borrow clears
- ☑ Share-burn invariant: `totalSupplyShares` unchanged (suppliers eat the loss via reduced asset/share ratio, not via burn)

**Result:** **PASS** — liquidation path holds at 1B; Codex-patch refund invariant verified; bonus = 4.38% (NOT the brief's assumed 5% — see R3).

**Traces:**
- approve liquidator: `0x92e96aa400eddcf73d35ca8991c2f6a80ad9190ca2f19336fd71ee2bd4eda05b`
- liquidate(1B EURC seize): `0xc6aac974483527c73db337b72c677d6174849ccac769ee18520bb9863e43884d`

**Per-case headroom analysis:**

| Field | Type | Max | Observed | Headroom |
|---|---|---|---|---|
| `seizedAssets` arg | uint256 | `2^256-1` | `1e15` | `1.16e62×` |
| `repaid` return | uint256 | `2^256-1` | `4.79e14` | `2.4e62×` |
| Bad-debt delta | uint128 (in `totalSupplyAssets`) | `3.4028e38` | `3.8e14` | `8.9e23×` |

**Risks surfaced (this case):** R3, R4, Q8 (open) — see §Risks.

---

## Case S4 — 500M UR `V4_SWAP` USDC→EURC via FxSwapHook — BLOCKED

**Reason:** `FxSwapHook` is not deployed on the Fuji hub stack. Per `deployments/hub-config-fuji.json`, the migration commit `bbb0302` moved the hub from Base Sepolia to Fuji but skipped the swap hook because:
- Uniswap V4 PoolManager is not deployed on Avalanche Fuji
- `FxSwapHook` is wired to the v2 hub oracle/registry on Base Sepolia (`0xc7260EF7D95D155aD6CA18ED539373a7576c8AC8`), not the v3/v4 patched contracts
- The swap hook is acknowledged as a constant-spread MVP per `Phase 2.5:` comments in `contracts/src/hub/FxSwapHook.sol`

What this audit could NOT verify (deferred to S4 unblock):
- PMM quote saturation at 500M scale (size-impact curve behavior)
- Hot-reserve depletion (`hotReservePct=2000` = 20% → 500M swap likely reverts at `InsufficientLiquidity(effective, requested)`)
- JIT-borrow path (Phase 2.5, not implemented)
- afterSwap fee → Morpho supply (Phase 2.5, not implemented)
- Bunni-pattern integration

**Result:** **BLOCKED** — see §Out-of-scope for unblock path.

---

## Case S5 — CCTP V2 receive-side stress (5 sampled + gas-based concurrency ceiling)

> **Gateman rebadge.** The original brief said "1000 concurrent". On Avalanche Fuji's 15M block-gas limit and the measured per-call gas, true concurrency caps at ~82-91/block. This case therefore covers: (S5a) 4 sampled `executeDeposit` calls with zero-pull leftover invariant + replay-protection; (S5b) 1 partial-pull variant exercising Codex Patch #2 on the half-consumed branch; and a per-call gas table that pins the production concurrency ceiling. It does NOT cover 1000-in-one-block — that is physically impossible.

**Hypothesis:** `FxHubMessageReceiver.executeDeposit` has constant-time invariants per call: (a) mapping access is O(1), (b) `forceApprove → registry.call → forceApprove(0)` lifecycle is per-call atomic, (c) `balBefore = USDC.balanceOf(this)` baselines correctly against prior stranded deposits, (d) Patch #2 correctly marks Stranded with `leftover` (not `minted`) when the registry call succeeds but consumed less than the full bridged amount.

**Why scaled:** producing 1000 valid CCTP V2 attestations requires Circle's signer set; cannot be forged on a single-chain vnet. Solution: install a **mock MessageTransmitterV2** (hand-assembled 95-byte runtime stub) at `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` that, on any `receiveMessage(...)` call, transfers a fixed 100M USDC from itself to `msg.sender` and returns success. This exercises the **real** `FxHubMessageReceiver.executeDeposit` end-to-end against the actual deployed receiver bytecode.

**Mock transmitter runtime bytecode (95 bytes):**
```
0x63a9059cbb60e01b600052336004527f00000000000000000000000000000000000000000000000000005af3107a4000
  60245260206000604460006000735425890298aed601595a70ab815c96711a31bc655af150600160005260206000f3
```
Logic: build `transfer(msg.sender, 1e14)` calldata in memory → CALL USDC → pop success → return 0x01.

**Setup:**
1. Restore from clean fork + staging artefacts #2–#6 + #10 + #11
2. Construct cctpMessage bytes with valid V2 layout: 148B outer header (sourceDomain=6 Base Sepolia, destDomain=1 Fuji, varying `nonce`) + 228B burn body (mintRecipient=FxHubMessageReceiver, amount=1e14, feeExecuted=0) + 192B hookData = 568 bytes total
3. hookData = `abi.encode(beneficiary=whale, hubCalldata=registry.paramsOf(USDC, EURC))` — a benign registry view call that succeeds without pulling USDC (forces the "succeed but leftover" branch — exercises Codex Patch #2)
4. Submit `executeDeposit(message, attestation="", whale, hubCalldata)` for nonces 1, 2, 5, 10
5. Test replay protection by re-submitting nonce 1

**Per-tx invariants (all 4 nonces):**

| Invariant | nonce 1 | nonce 2 | nonce 5 | nonce 10 |
|---|---|---|---|---|
| `executeDeposit` status | ✓ | ✓ | ✓ | ✓ |
| `depositState(nonce)` post | `Stranded` (2) | `Stranded` (2) | `Stranded` (2) | `Stranded` (2) |
| `strandedDeposit.amount` | 100M | 100M | 100M | 100M |
| `strandedDeposit.beneficiary` | whale | whale | whale | whale |
| `USDC.allowance(receiver, registry)` post | **0** | **0** | **0** | **0** |
| Untouched nonce 3 | `Unknown` (0) | — | — | — |

**Aggregate state:**

| Field | Value | Verification |
|---|---|---|
| `USDC.balanceOf(FxHubMessageReceiver)` | 400,000,000.000000 | = 4 × 100M ✓ (no double-counting, no skim) |
| `USDC.balanceOf(MockTransmitter)` | 9,600,000,000.000000 | = 10B - (4 × 100M) ✓ (exact accounting) |
| Replay protection | Reverts on nonce=1 retry | sim trace `ba58fb2f-9e8e-43b0-9631-28a8256bfa3c`, `gas_used=0x8a46`, status=false ✓ |

**Asserts:**

- ☑ Mapping `_deposits[nonce]` accepts arbitrary bytes32 keys without collision
- ☑ `forceApprove → registry.call → forceApprove(0)` lifecycle resets allowance to 0 after every call (Codex Patch #1 invariant)
- ☑ Codex Patch #2 ("succeed + leftover → Stranded, not Executed") fires correctly: `paramsOf` returned success but consumed 0 USDC → receiver marked Stranded with full 100M as leftover
- ☑ `balBefore = USDC.balanceOf(this)` baseline correctly excludes prior stranded deposits from the delta calculation
- ☑ Replay protection via `if (s != DepositState.Unknown) revert AlreadyExecuted(nonce);`

**Per-call gas breakdown** (read live via `mcp__tenderly__get_vnet_simulation_gas_breakdown`):

| Tx | Nonce | State | Total gas | Top consumers |
|---|---|---|---|---|
| `0xf2d8…7308` | 1 | cold | **181,638** | receiver (154,530) → transmitter (32,241) → USDC delegatecall (31,363) |
| `0x57ce…9510` | 2 | warm | **164,538** | receiver (137,430) → USDC.transfer (25,341) → transmitter (15,141) |
| `0xd926…3b86` | 5 | warm | **164,538** | (identical breakdown) |
| `0xa0e6…fa57` | 10 | warm | **164,538** | (identical breakdown) |

Cold-vs-warm delta of 17,100 gas = first-time SSTOREs on the receiver's `_deposits[nonce]` slot pair (warm SSTORE is 2,900; cold-store SLOAD + non-zero write is ~22,100 — matches).

**Block-gas concurrency ceiling** (Avalanche Fuji block_gas_limit = 15,000,000):

| Regime | Per-call gas | Calls per Fuji block | What this means for "1000 concurrent" |
|---|---|---|---|
| Cold (every deposit a fresh nonce, no warm caching) | 181,638 | **~82** | 1000-in-one-block impossible by ~12× |
| Warm (back-to-back same-block calls, share SLOAD cache) | 164,538 | **~91** | Same conclusion |
| Theoretical relay rate to clear 1000 | — | — | ~11-13 sequential blocks (~22-26s on Fuji's ~2s blocktime) |

**Implication:** the receiver invariants we verified do NOT depend on N because the state machine is per-mapping-key. But the calling protocol (relayer fleet) must batch across blocks, not stuff into one. This is a tooling/relayer concern, not a receiver concern — but it must be acknowledged so the brief's "1000 concurrent" wording doesn't propagate uncorrected.

---

### S5b — Partial-pull variant (Codex Patch #2 on the half-consumed branch)

**Why this exists:** S5a only exercised the *succeed + zero-pull* branch of Patch #2 (hubCalldata = `paramsOf` view; registry returned success without touching USDC). A more dangerous branch is *succeed + partial-pull*: registry consumed half the bridged amount, returned success, and the receiver must record the unconsumed remainder as Stranded — NOT mark the deposit Executed and lose the leftover.

**Setup:**
1. Restore to post-S5a state (snapshot `0x4c8a9c0e…676f133`)
2. Construct CCTP V2 message with `nonce=42`, `mintedAmount=100M` (1e14 raw)
3. `hubCalldata = FxMarketRegistry.supply(USDC, EURC, 50_000_000_000_000, whale)` — Registry pulls 50M of the 100M bridged, succeeds, supplies into Morpho M2 on behalf of whale
4. Submit `executeDeposit(message, "", whale, hubCalldata)`

**Expected (Codex Patch #2 invariant):**

```solidity
// FxHubMessageReceiver.sol:154
uint96 stranded = ok ? uint96(leftover) : uint96(minted);
```

When `ok=true` and `leftover=50M`, `stranded` must be 50M, NOT 100M. State must be `Stranded` (NOT `Executed`).

**Live read after tx** (`vnet_multicall` on receiver):

| Call | Selector | Result | Decoded |
|---|---|---|---|
| `depositState(0x2a)` | `0xf8d26828` | `0x...0002` | **Stranded (2)** ✓ |
| `strandedDeposit(0x2a)` | `0x25ec4acd` | (4 packed slots) | beneficiary=whale, **amount=`0x2d79883d2000` = 50,000,000,000,000 (50M USDC)** ✓, strandedAt=`0x6a063ad5`, state=2 |

**Asserts:**

- ☑ `ok=true` branch fires (registry call succeeded)
- ☑ `leftover = minted - registry_pulled = 100M - 50M = 50M` ✓
- ☑ `stranded = uint96(leftover)` not `uint96(minted)` — Patch #2 verified on the partial path
- ☑ Deposit state = `Stranded(2)`, NOT `Executed(1)`
- ☑ Beneficiary preserved as the spoke-side intent specified (whale, not `msg.sender` of the relayer)
- ☑ Morpho M2 received 50M USDC supply on behalf of whale (whale's supply balance in M2 increased by 50M)

**Result:** **PASS (mock transmitter)** — Patch #2 invariant holds on the partial-pull branch.

**Trace:** `0x495272b9f47b7c721f9d23bc645ead87969c9dbc1f35ba4712c5294eb1a4d2fa` ([dashboard](https://dashboard.tenderly.co/criptopoeta/bufi/testnet/5ea52b4d-fe5a-4026-828c-d9b8fa08cec6/tx/avalanche-fuji/0x495272b9f47b7c721f9d23bc645ead87969c9dbc1f35ba4712c5294eb1a4d2fa))

---

**Receiver-internal invariants generalization (S5a + S5b → arbitrary N):**

The receiver's per-call state is in-frame; cross-call state is only the `_deposits` mapping. Properties:
- O(1) mapping access (proven by EVM semantics)
- Per-call mutex via `nonReentrant`
- Allowance lifecycle scoped per call (`forceApprove(minted)` → call → `forceApprove(0)`; reset is unconditional regardless of branch)
- Balance-delta math computed in-frame from `USDC.balanceOf(this)` snapshot pair — correctly excludes prior stranded deposits
- No bounded array / no enumerable storage that grows with N
- Patch #2 invariant `stranded = ok ? uint96(leftover) : uint96(minted)` verified on **both** branches (zero-pull via S5a; partial-pull via S5b)

Therefore N sequential `executeDeposit` calls — across multiple blocks — behave identically per-call to the 5 we observed. **N concurrent within one block is bounded by `15M / 181,638 ≈ 82`** (cold) — this is the protocol-level concurrency ceiling.

**Result:** **PASS (mock transmitter)** — receive-side invariants hold across S5a (4 nonces) + S5b (1 partial-pull); replay protection live; Codex Patches #1 and #2 verified on both succeed branches; concurrency ceiling pinned to block gas.

**Traces:**
- nonce 1: `0xf2d8380ab7f48c0fe160e4f8483bb4b83f49678afb15e594d65adc21113f7308`
- nonce 2: `0x57ce83b955da717b8bcd8e955170cd79d10d8bb78be28efbaf87f4ec2dd19510`
- nonce 5: `0xd9267913c7aedef6a59f18c60b7b82203bf4b6aa740170fbb38761dadb263b86`
- nonce 10: `0xa0e6e6a8831f2652c4cbd5ec75010f9c37fc259115acfdbc1dc0281bf6e1fa57`

**Per-case headroom analysis:**

| Field | Type | Max | Observed | Headroom |
|---|---|---|---|---|
| `_deposits[nonce].amount` | **uint96** | `7.9e28` | `1e14` per entry | `~7.9e14×` per-entry; but see R5 (silent truncating cast) |
| `_deposits[nonce].strandedAt` | uint64 | `1.84e19` (year 5.8e11) | current block timestamp ~1.78e9 | effectively ∞ |
| `nonce` keyspace | bytes32 | `2^256` | 4 used | `2^254×` |

**Risks surfaced (this case):** R5, R6 — see §Risks.

---

## Case S6 — 128-sim regression matrix on Fuji vnet — DEFERRED

**Reason:** `packages/sdk/scripts/simulator/run-matrix.ts:60` hardcodes `deployments/base-sepolia.json` as the hub manifest. Categories B–H index `hub.contracts.FxSwapHook`, `hub.external.EURC`, `hub.external.MorphoBlue` — none exist (or exist in the expected key) in `hub-config-fuji.json`. Additionally, `.env.local` does not exist in this workspace; the runner aborts at line 28 (`throw new Error(".env.local missing at ${path}")`).

**Result:** **DEFERRED** — see §Out-of-scope for unblock path.

---

## Case S7a — uint128 SHARES-side overflow probe (empirical, Pattern G branch)

**Why this exists:** v1.0 of this audit cited "$1.7e26 practical ceiling" as a finding. That was arithmetic extrapolation (`uint128_max / observed_max`), not measurement. v1.1 patches by actually pushing `Morpho.market[id].totalSupplyShares` to `2^128 - 1` via `tenderly_setStorageAt` and observing whether `Morpho.supply(1)` reverts gracefully or silently truncates.

**Hypothesis:** Morpho v1.0 / v1.1 uses Solidity 0.8.19 with default checked arithmetic. `Morpho.sol:187` performs `market[id].totalSupplyShares += shares.toUint128()`. Two failure modes possible at saturation: (a) graceful Panic(0x11) revert from the EVM, or (b) silent truncation if any path is `unchecked`. The protocol is safe iff (a).

**Setup:**
1. Snapshot vnet at current state (id `0x681228b2…dafa50`)
2. Compute Morpho storage slot for `market[M2_id]`:
   - `marketsMappingSlot = 3` (verified from `Morpho.sol` state-var ordering)
   - `M2_id = keccak256(abi.encode(USDC, EURC, MorphoOracleAdapterM2, IrmMock, lltv=0x0bef55718ad60000))`
     = `0x1700104cf29eceb113e01a1bcdc913e5e10d3d37314cee235752aa88bf153197`
   - `slot0 = keccak256(abi.encode(M2_id, 3))` = `0x4ed92523f783d319ad2de283ec4c4fb751d0b5592c2e6506dd16f3108bf985a3`
3. Read current packed slot 0 via `Morpho.market(M2_id)` view — confirm:
   - `totalSupplyAssets = 0x5eedb2cc66002 ≈ 1.67e15 (1.67B USDC)` (low 16B)
   - `totalSupplyShares = 0x6fc43aabcdae8af93e ≈ 2.06e21` (high 16B)
4. `tenderly_setStorageAt(Morpho, slot0, 0xffffffffffffffffffffffffffffffff_00000000000000000005eedb2cc66002)` — push shares to MAX (2^128-1), preserve assets
5. Verify state read: `Morpho.market(M2_id)` returns `totalSupplyShares = 0xffffffffffffffffffffffffffffffff` ✓
6. Simulate `Morpho.supply(M2_params, 1, 0, whale, "")` from whale persona
7. Restore snapshot to clean slate

**Result:** **PASS — graceful revert demonstrated**

| Field | Value |
|---|---|
| Simulation status | `false` (reverted) |
| Revert reason | `arithmetic underflow or overflow` (Panic(0x11)) |
| Operation ID | `1f8098c9-304f-43fe-9495-99634abb5d3a` |
| Gas used | `0xc36d = 50,029` |
| Error site | Inside Morpho contract `0xeF64621D…79e6`, internal opcode panic |
| Sibling operations before panic | accrueInterest path (5× SLOAD, IRM call to `IrmMock`, 4× SSTORE, 1× LOG2 AccrueInterest emit) — all completed; revert undoes them |
| `USDC.transferFrom` reached? | **No** — panic precedes the transferFrom at `Morpho.sol:198` |

**Asserts:**

- ☑ At `totalSupplyShares = 2^128 - 1`, any positive `supply()` reverts cleanly
- ☑ Revert mode is EVM Panic(0x11), NOT silent uint128 truncation
- ☑ State is untouched (the `+=` at line 187 is what panics; transferFrom never reached, no asset siphoning possible)
- ☑ `shares.toUint128()` SafeCast at `UtilsLib.sol:27` did not trigger (the bound check is on `shares`, not on the sum)
- ☑ The relevant overflow site is the `+=` at storage write, not the toUint128 cast

**Implication for R2:** The uint128 share-encoding ceiling is a **soft cap, not an unsafe limit**. The protocol cannot accept supplies that would push `totalSupplyShares > 2^128 - 1`; the next supply just reverts. Demoting from "theoretical overflow risk" to "operational soft cap" — no fund loss path exists. The TVL ceiling stands at ~$3.4e26 for 6-decimal stables and ~$6.8e13 for 18-decimal stables (different decimal offset), both far above any realistic protocol scale.

**Trace:** simulation operation `1f8098c9-304f-43fe-9495-99634abb5d3a` (reverted; not stored as a chain tx since simulation, not send).

**Caveats:**
- Probe was on Morpho-side overflow only. `FxReceipt._mint` (OZ ERC-4626) uses uint256 internally — no parallel ceiling. The Morpho ceiling propagates to `FxReceipt.totalSupply` because the wrapper depends on Morpho's view of shares.
- 18-decimal stable behavior was NOT live-tested (would require deploying a fresh 18-dec mock + FxReceipt wrapper). Math above is arithmetic extrapolation from the same uint128 mechanism, NOT measurement. Listed as unblock under §Out-of-scope.
- §S7a covers ONLY the shares-side `+=` at `Morpho.sol:187`. The asset-side `+=` at `Morpho.sol:188` is a separate uint128 packed-field overflow path. **Probed independently — see §S7b below.**

---

## Case S7b — uint128 ASSETS-side overflow probe (sibling to S7a)

**Why this exists:** Gateman v1.2.1 review (G-2) flagged §S7a as generalizing from one of two parallel overflow sites. `Morpho.sol` packs `totalSupplyAssets` (low 16B of slot 0) and `totalSupplyShares` (high 16B) into the same word; both flow through `UtilsLib.toUint128`, and both are incremented in sequence at supply():

```solidity
// Morpho.sol:186-188
position[id][onBehalf].supplyShares += shares;
market[id].totalSupplyShares += shares.toUint128();   // S7a probed this
market[id].totalSupplyAssets += assets.toUint128();   // S7b probes this
```

**Hypothesis:** Same Solidity 0.8.19 checked-arithmetic regime should produce Panic(0x11) when `totalSupplyAssets` saturates and `supply(1)` runs. Asset-side specifically matters because **`accrueInterest` also writes `totalSupplyAssets += interest`** — a high-utilization market with long-duration interest accrual could saturate via that path independently of any user-driven supply.

**Setup:**
1. Snapshot the vnet (Pattern G) — `0x681228b28ba16c12868bf49e1af8acad858cbac9c50e3a7f650c315edadafa50` (reused from S7a).
2. Read live slot 0 of `market[M2_id]` to confirm baseline: `totalSupplyAssets = 0x5eedb2cc66002`, `totalSupplyShares = 0x6fc43aabcdae8af93e`, `totalBorrowAssets = 0`, `totalBorrowShares = 0`. (Confirmed via `Morpho.market(M2_id)` view at block `0x34ca6eb`.)
3. `tenderly_setStorageAt(Morpho, slot0, 0x000000000000006fc43aabcdae8af93e_ffffffffffffffffffffffffffffffff)` — high 16B preserves `totalSupplyShares`, low 16B sets `totalSupplyAssets = 2^128 - 1`.
4. Verify post-write via `Morpho.market(M2_id)` view → returns `totalSupplyAssets = 0xffffffffffffffffffffffffffffffff`, `totalSupplyShares = 0x6fc43aabcdae8af93e` (preserved) ✓.
5. Simulate `Morpho.supply(M2_params, 1, 0, whale, "")` from whale persona.
6. Revert snapshot.

**Result:** **PASS — graceful Panic(0x11) revert demonstrated**

| Field | Value |
|---|---|
| Simulation status | `false` (reverted) |
| Revert reason | `arithmetic underflow or overflow` (Panic(0x11)) |
| Operation ID | `4ae30c13-d38b-4d48-aa12-69ad6d3a363b` |
| Gas used (sim envelope) | `0xbb43 = 47,939` (vs S7a `50,029` — 4% lower, consistent with reaching the panic site one `+=` later and skipping shares-side state mutations) |
| Error path top of stack | `panic: arithmetic overflow / underflow` at `call_depth=1, absolute_position=23` inside Morpho `0xeF64621D…79e6` |
| Sibling ops before panic | accrueInterest path (5× SLOAD + IrmMock CALL + 2× SLOAD + 1× SSTORE + 1× SLOAD + 1× SSTORE + 1× SLOAD + 1× LOG2 `AccrueInterest` emit) + supply body (1× SLOAD + 2× SSTORE before panic) — all rolled back by the revert |
| `USDC.transferFrom` reached? | **No** — panic precedes `IERC20.safeTransferFrom` at `Morpho.sol:194` |

**Asserts:**
- ☑ At `totalSupplyAssets = 2^128 - 1`, any positive `supply()` reverts cleanly with Panic(0x11)
- ☑ Revert mode is EVM checked-arithmetic panic, NOT silent uint128 truncation (the assets-side `+=` is `checked`, not `unchecked` — confirmed by reading `Morpho.sol:188`, no `unchecked` block surrounds it)
- ☑ Failure happens at `Morpho.sol:188`'s `+=`, AFTER line 187 wrote a no-op (`shares.toUint128() = 0` because `toSharesDown(1, MAX, preserved) ≈ 0` floored)
- ☑ Position-side state (`position[id][whale].supplyShares`) at line 186 was reached but `+= 0` is functionally a no-op, and the revert undoes any SSTORE side-effects regardless
- ☑ `transferFrom` never reached → no USDC siphoning possible at the saturation boundary
- ☑ Asset-side overflow path is also reachable via `accrueInterest` (line 142 of Morpho.sol: `market[id].totalSupplyAssets += feeAmount.toUint128() + interest`); same `checked` arithmetic, same Panic(0x11) expected on a long-running market — NOT measured this round, but identical code path

**Implication for R2:** Both halves of slot 0 (shares AND assets) revert cleanly at saturation. The uint128 ceiling is a **bounded soft cap on EACH packed field independently** — there is no fund-loss path on either side, no path that allows state corruption to slip past the boundary. The earlier claim "uint128 ceiling is a soft cap" is now empirically backed for the two write sites at `Morpho.sol:187` and `Morpho.sol:188`. Fee-accrual write site (`_accrueInterest` line 142) is identical-pattern, inferred but not measured (`/codex-adversarial-tenderly-auditor` could probe this if it wants belt-and-suspenders).

**Trace:** simulation operation `4ae30c13-d38b-4d48-aa12-69ad6d3a363b` (reverted; not stored as chain tx since simulation, not send).

**Caveats:**
- `simulate_vnet_transaction` is non-committing by design — "state is untouched" is the tool contract, not a measurement (G-4 from Gateman v1.2.1). The PERSISTENT `set_storage_at` at step 3 was reverted via the snapshot at step 6, returning the slot to baseline. Post-revert `Morpho.market(M2_id)` would re-show the pre-probe values (`totalSupplyAssets = 0x5eedb2cc66002`); explicit re-read deferred as routine.
- 18-decimal variant still unmeasured — code-path identity argues for same revert mode, but per the v1.2.1 rule, "assumed" ≠ "demonstrated". Carried in §Out-of-scope.

---

## Overflow + design risks surfaced

Actionable rows only. Each row carries explicit preconditions + a concrete recommended check.

| # | Class | Severity | Surface | One-liner | Preconditions | Recommended check |
|---|---|---|---|---|---|---|
| **R1** | ERC-4626 inflation attack | **Medium** (mechanism corrected by adversarial pass) — **LANDED in v1.2.2** | `FxReceipt.sol` | OZ default `_decimalsOffset()=0` admits first-depositor inflation. **Adversarial pass disproved the direct-donation variant**: `FxReceipt.totalAssets()` is overridden to read `MORPHO.expectedSupplyAssets`, NOT `asset.balanceOf(this)` — raw USDC sent to the wrapper is dead dust and does not affect share price. The vulnerability class is reachable only via a **Morpho-side donation**: anyone can call `MORPHO.supply(params, x, 0, wrapper, "")` to mint shares to the wrapper's Morpho position, which IS counted by `expectedSupplyAssets`. | Hub flow does NOT pass through `FxReceipt.deposit()` (Registry → Morpho direct). Vulnerable surface is the public ERC-4626 entry point on `FxReceiptUSDC`/`EURC` before the wrapper has scale. Operative reproducer is: actorA `deposit(1)` → actorA `MORPHO.supply(params, 1e9, 0, wrapper, "")` → actorB `deposit(V)`; with offset=0 and V < (D+2)/2, actorB rounds to 0 shares. | **Fix landed in `FxReceipt.sol`** — `_decimalsOffset()` overridden to return 6, raising the attacker's required donation by 1e6× and turning the steal into negative-EV at any realistic victim deposit. Doc-comment on `totalAssets()` records the direct-donation defence so the next reader doesn't reintroduce the classical pattern. **Forge test (recommended for follow-up):** donation step must use `MORPHO.supply(params, 1e9, 0, wrapper, "")`, NOT `IERC20(USDC).transfer(wrapper, 1e9)` — a direct-transfer test would falsely green. |
| **R2** | uint128 share/asset encoding | **Low (operational soft cap — graceful revert demonstrated on BOTH packed halves)** | `morpho-blue/src/Morpho.sol:187` (shares) + `:188` (assets) | At `totalSupplyShares = 2^128 - 1` OR `totalSupplyAssets = 2^128 - 1`, any positive `supply()` reverts with Panic(0x11) before `transferFrom` is reached. **Empirically demonstrated in §S7a** (shares, operation `1f8098c9…d3a`) and **§S7b** (assets, operation `4ae30c13…363b`). | Per-stable, shares-side ceiling: ~$3.4e26 USD-pegged 6-decimal; ~$6.8e13 BRL-equivalent 18-decimal. Assets-side ceiling identical-ish (same uint128 + same VIRTUAL_ASSETS=1 anchor). For 18-decimal stables (BRLA, JPYC, ZCHF) the ceiling is closer to realistic horizons than for 6-decimal; ERC-20 issuance caps + Morpho fee-accrual scaling are *plausible* tighter bounds but NOT verified here. | **No code change required** — overflow is gracefully bounded by Solidity 0.8.x's checked arithmetic + Morpho's `toUint128` SafeCast on *both* packed halves. Document the per-decimal ceiling in design docs so 18-decimal spokes aren't sized on the 6-decimal assumption. Optional defence-in-depth: per-market `maxSupplyAssets` configurable bound that reverts earlier with a domain-specific error rather than Panic(0x11). |
| **R3** | Liquidation bonus assumption | **Low** | `FxLiquidator` keeper docs + downstream bounty-economics tooling | Brief / docs assume 5% liquidation bonus; on-chain reality (Morpho LIF for LLTV=86%) is **4.38%**. Keeper economics built on 5% will under-deliver by 12.4%. | Whenever liquidations occur. At 1B liquidation scale this is a 6.2M USDC delta per event. | Update bounty-economics tooling + docs to reference `WAD / (WAD - α × (WAD - lltv))` formula directly. Add a `getLiquidationBonus(MarketParams)` view to `FxLiquidator` that computes and returns the live LIF. |
| **R4** | Bad-debt rounding direction | **Low** | `FxReceipt` redeem after bad-debt event + OZ ERC-4626 default `Math.Rounding.Floor` | Post-bad-debt redemptions floor-round, leaving 1-wei dust per redemption. At 1B scale: relative error = 1e-15, immaterial. Risk amplifies if any rebasing wrapper is composed on top of `FxReceipt` (e.g. Hinkal-wrapped flows). | Bad-debt event has occurred (S3 demonstrated 19% haircut). Composed wrapper compounds the rounding. | Forge property test: round-trip `deposit/withdraw` after bad-debt realization across 10k iterations; assert dust < ε. If composing wrappers planned, audit each layer's rounding direction independently. |
| **R5** | uint96 truncating cast | **Low** (Circle-gated threshold) — **LANDED in v1.2.2** | `FxHubMessageReceiver.sol` (`uint96(minted)` / `uint96(leftover)`) | Solidity 0.8.x does not revert on explicit truncating casts. A CCTP message with `mintedAmount ≥ 2^96` (~7.9e28 raw USDC) would silently store 0 as `_deposits[nonce].amount`. **Adversarial pass mechanism clarification:** on the Stranded branch (path b — registry call reverts or partial-pulls), `sweepStrandedDeposit` then executes `safeTransfer(beneficiary, 0)` and the raw USDC sits permanently on the receiver with no admin sweep function. **Not "cosmetic" — severs the only intended recovery path.** | Threshold (2^96 raw ≈ 7.9e22 USDC tokens, ~1.6e12× the global USDC supply) is Circle-mint-cap-gated and unreachable in practice, but the qualitative failure mode is "permanent USDC loss" rather than "wrong stored amount". | **Fix landed**: `uint256.toUint96()` (OZ SafeCast) at both sites. Reverting `executeDeposit` lets Circle's relayer retry or escalate; the prior truncation bricked funds on the receiver. Mitigation rationale reframed from defence-in-depth to **hard requirement** for the integrity of the sweep recovery path. |
| **R6** | Stranded-deposit batch sweep | **Low** | `FxHubMessageReceiver.sweepStrandedDeposit(bytes32)` | At 1000 stranded entries, the beneficiary needs 1000 separate sweep txs — 1000× gas overhead vs. a batch. Operational ergonomics only; no fund loss. | Mass stranded event (e.g. registry-side migration causes all in-flight deposits to land Stranded). | Add `sweepStrandedDeposits(bytes32[] calldata nonces)` that loops the existing single-nonce path. Bounded gas check inside the loop to prevent OOG-class DoS. |
| **R7** | Oracle staleness on cold-fork vnets | **Low** | All paths reading `MorphoOracleAdapter.price()` | Pyth + RedStone payload requirement means cold-fork vnets revert with `CalldataMustHaveValidPayload() = 0xe7764c9e` until Pyth is freshened. **Operational, not security** — affects testing methodology, not production. | Auditor runs fresh stress matrix on a cold fork. | Document in `prime-vnet.sh` that post-fork bootstrap MUST either (a) call `Pyth.updatePriceFeeds` with a fresh Hermes payload, OR (b) install a mock adapter (this audit's Staging Artefact #5/#6) and clearly mark it as staging-only. |
| **Q8** | Bad-debt socialization ordering | **OPEN — adversarial pass required (no severity until demonstrated)** | `Morpho.liquidate` semantics across consecutive liquidations | When N positions go underwater in one block, the order of liquidations may affect the realized haircut per supplier (later liquidators see a lower asset/share ratio after earlier ones). If true, this is a MEV path: front-running the most-undercollateralized position extracts more bonus. | Multiple positions underwater simultaneously in one market in one block. Realistic during a sharp oracle move. | **Hypothesis only — not demonstrated.** Per the actionable-severity rubric (no severity tier without demonstration), Q8 is filed as an open question for `/codex-adversarial-tenderly-auditor`. Adversarial probe: snapshot post-S3, prime 10 underwater positions, batch-liquidate in one block, measure per-liquidator profit and per-supplier haircut order-dependence. If ordering-dependent profit > 1 bp, escalate to Medium and design fair-ordering mitigation. |

---

## Out-of-scope / blocked

| Case | Blocker | Unblock path | Est. effort |
|---|---|---|---|
| **S4** (FxSwapHook 500M swap) | `FxSwapHook` not on Fuji hub; UniV4 PoolManager not on Fuji | (a) Fork Base Sepolia for swap-hook tests, OR (b) Deploy stub UniV4 PoolManager on the Fuji vnet + redeploy `FxSwapHook` wired to v3/v4 hub | 4–8 hours |
| **S6** (128-sim matrix re-run) | `loadHub()` hardcoded to `deployments/base-sepolia.json`; `.env.local` missing in workspace | (a) Patch `run-matrix.ts:60` to accept `HUB_DEPLOYMENT_PATH` env override, (b) normalize `hub-config-fuji.json` to expose `external.EURC` / `external.MorphoBlue` keys, (c) scaffold `.env.local` from the active vnet's admin/public RPC URLs | 30 min |
| **Q8 adversarial probe** (10 chained liquidations in one block) | Not run in defensive pass — surfaced for adversarial follow-up | Snapshot post-S3, prime 10 underwater positions, batch-liquidate in one block, measure per-liquidator return | 1–2 hours; deferred to `/codex-adversarial-tenderly-auditor` |
| **S7 18-decimal variant** (uint128 ceiling on BRLA/JPYC/ZCHF-shaped stables) | Fuji deployment ships USDC + MockEURC, both 6-decimal — no 18-dec stable to probe live | Deploy a `MockBRLA(18)` + `FxReceipt` wrapper for it, register the market in Morpho, repeat the §S7a/S7b probes with `setStorageAt → supply(1)`. **TO BE MEASURED** — assumed equivalent only by code-path identity (`UtilsLib.toUint128` + `Morpho.sol` `+=` sites), not yet observed. | 2–3 hours |

---

## Reproducer

```bash
# 1. Auth + activate (Tenderly MCP must be OAuth'd in the session)
# mcp__tenderly__set_active_project --account_slug=criptopoeta --project_slug=bufi
# mcp__tenderly__set_active_vnet --vnet_id=5ea52b4d-fe5a-4026-828c-d9b8fa08cec6
# mcp__tenderly__revert_vnet --snapshot_id=0x3f3836dc5790bcc0de93a5febb29bfe226cee70b62cef8f2123706d574c529ae  # clean state

# 2. Re-apply staging artefacts (canonical sequence per §Staging artefacts table)
# mcp__tenderly__set_erc20_balance whale=0x1111...1111 token=USDC value=0x2386F26FC10000
# mcp__tenderly__set_erc20_balance whale=0x1111...1111 token=MockEURC value=0x2386F26FC10000
# mcp__tenderly__fund_account whale=0x1111...1111 amount=0x56BC75E2D63100000

# Mock oracle install (1e36 — 1 EURC = 1 USDC):
RPC="https://virtual.avalanche-testnet.eu.rpc.tenderly.co/<REDACTED>"
CODE="0x7f0000000000000000000000000000000000c097ce7bc90715b34b9f100000000060005260206000f3"
curl -X POST "$RPC" -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"tenderly_setCode\",\"params\":[\"0xf0cdaa9cf9e8d52060dcb41a045e3a6d618a9f65\",\"$CODE\"],\"id\":1}"
curl -X POST "$RPC" -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"tenderly_setCode\",\"params\":[\"0xda4c3e315fffd0790c9d8a1730c2ba56330cb2ec\",\"$CODE\"],\"id\":2}"

# 3. Per-case command sequences are in the body of each §Case S{{N}} section.
```

**Raw calldata builders + decode helpers** (Python, used throughout the audit):

```python
def pad(x, n=32):
    if isinstance(x, int): return f"{x:0{n*2}x}"
    return f"{int(x, 16):0{n*2}x}"

def addr(a): return pad(int(a.replace("0x","").lower(), 16))

# Example: FxReceiptUSDC.deposit(assets, receiver)
def deposit(amount, receiver):
    return "0x6e553f65" + pad(amount) + addr(receiver)

# Example: Morpho.supplyCollateral(MarketParams, assets, onBehalf, data)
def supplyCollateral(params_hex, amount, onBehalf):
    return ("0x238d6579" + params_hex + pad(amount) + addr(onBehalf)
            + pad(0x100) + pad(0))  # offset to empty bytes, length=0

# Mock oracle bytecode for given price (scaled by 1e36):
def mock_oracle(price_e36):
    return "0x7f" + f"{price_e36:064x}" + "60005260206000f3"

# Mock CCTP transmitter (always-transfer-100M-USDC stub):
USDC = "5425890298aed601595a70ab815c96711a31bc65"
MOCK_TRANSMITTER = (
    "0x63a9059cbb60e01b600052336004527f"
    + f"{10**14:064x}"
    + "60245260206000604460006000" + "73" + USDC + "5af150600160005260206000f3"
)
```

CCTP V2 message constructor + executeDeposit calldata builder available in the audit transcript on request.

---

## Sign-off

| Field | Value |
|---|---|
| Methodology | `/claude-tenderly-auditor` v1.0.0 |
| Model | Claude Opus 4.7 (`claude-opus-4-7`) |
| Date | 2026-05-14 |
| Defensive pass | ☑ Complete |
| Adversarial pass | ☑ Complete — `reports/CODEX_ADVERSARIAL_v1.2.1.md` (Claude Opus 4.7 contrarian; Codex blocked 3× by OpenAI moderation; concordance caveat in §Sign-off of that report) |
| Next action | (1) ☑ R1 `_decimalsOffset()=6` + `totalAssets()` doc comment landed in `FxReceipt.sol`; (2) ☑ R5 `uint256.toUint96()` landed at both cast sites in `FxHubMessageReceiver.sol`; (3) ☑ dead `_ensureApproval` deleted from `FxHubMessageReceiver.sol`; (4) ☐ re-run Items 4/5/6 of the adversarial pass on a fresh Tenderly vnet once write-quota recovers (Q8 ordering-dependence, S7b accrueInterest, 18-decimal S7); (5) ☐ file Tenderly bug — `simulate_vnet_transaction.state_overrides.stateDiff` silently dropped; (6) ☐ unblock S4 by forking Base Sepolia. |

This report is reproducible from snapshot `0x3f3836dc…c529ae` + the §Staging artefacts table in order. Any divergence in re-runs MUST be investigated — the methodology is forensic, not statistical.

---

## Revision history

| Version | Date | Author | Notes |
|---|---|---|---|
| v1.0 | 2026-05-14 | criptopoeta (Opus 4.7) | Initial defensive pass. 8 actionable risks. |
| v1.1 | 2026-05-14 | criptopoeta (Opus 4.7) | Gateman post-review applied. Changes: (a) §Summary rebadged to "PASS (staged)" with explicit oracle/transmitter conditioning; (b) §Production-oracle delta section added; (c) §Storage layout pins replaced source-code inference with real `forge inspect` output (R7); (d) R1 narrative corrected — hub flow does NOT route through `FxReceipt.deposit()`, so the inflation window is wider than v1.0 claimed (Registry → Morpho.supply direct); (e) R8 demoted to **Q8 (Open Question)** — Medium severity was undemonstrated and violated the actionable-only rubric; (f) S5 rewritten: added per-call gas table (181k cold / 165k warm), pinned real concurrency ceiling at ~82-91/block on Fuji, added S5b partial-pull variant (tx `0x495272b9…1a4d2fa`) verifying Codex Patch #2 on the half-consumed branch — not just the zero-pull branch.|
| v1.2 | 2026-05-14 | criptopoeta (Opus 4.7) | Empirical follow-up: §S2 "~$1.7e26 ceiling" line was extrapolation, not measurement. Added §S7 — live overflow probe via `setStorageAt(Morpho.market[M2].totalSupplyShares = 2^128 - 1)` then `Morpho.supply(1)`. Result: clean Panic(0x11) at `Morpho.sol:187`, no silent truncation, no state corruption. R2 demoted from "theoretical overflow" to **operational soft cap with graceful revert demonstrated**. New §S2 table separates 6-decimal vs 18-decimal ceilings (~12 orders of magnitude apart). 18-decimal variant queued under §Out-of-scope for fresh-stable test. |
| v1.2.1 | 2026-05-14 | criptopoeta (Opus 4.7) | Gateman v1.2 patch-delta review applied (G-1, G-2, G-3 landed pre-Codex). Changes: (a) §S2 per-decimal table split into two columns — `raw uint128 max` and `effective shares` — so 6-dec/18-dec rows share a consistent denominator (G-3); (b) Summary table S7 row split into **S7a** (shares-side) + **S7b** (assets-side); both rows tagged "6-decimal underlying only" (G-1); (c) §Out-of-scope 18-dec entry rephrased from "Same revert mode expected" → "TO BE MEASURED — assumed equivalent only by code-path identity"; effort estimate revised 1h → 2-3h (G-1, G-7); (d) §Case S7 renamed §S7a; new §S7b added with sibling assets-side probe (operation `4ae30c13…363b`, gas 47,939, clean Panic(0x11) at `Morpho.sol:188`) — closes G-2; (e) R2 updated to reference BOTH probes (shares + assets); R2 caveat softened to acknowledge that "ERC-20 issuance caps + fee-accrual scaling" tighter bounds are *plausible* but unverified (G-5); (f) §S7b caveats explicitly note `simulate_vnet_transaction` is non-committing by design — "state is untouched" is tool contract, not measurement (G-4). G-6 (Morpho slot=3 inference) and G-7 (effort estimate) absorbed into S7b setup prose. |
| v1.2.2 | 2026-05-14 | criptopoeta (Opus 4.7) | Adversarial-pass fixes landed (`reports/CODEX_ADVERSARIAL_v1.2.1.md`). Source changes: (a) `FxReceipt.sol` — `_decimalsOffset()` override returns 6 (R1 defense, both direct- and Morpho-side donation variants); `totalAssets()` doc comment records the existing Morpho-read defence so the direct-donation pattern can't be reintroduced by accident; (b) `FxHubMessageReceiver.sol` — `uint256.toUint96()` (OZ SafeCast) at both cast sites (R5); dead `_ensureApproval` helper deleted (adversarial NEW-FINDING #B). Report changes: R1 narrative rewritten to specify **Morpho-side donation** as the operative mechanism (direct-donation was DISPUTED — `totalAssets()` reads `MORPHO.expectedSupplyAssets`, not `asset.balanceOf(this)`); forge-test reproducer corrected to use `MORPHO.supply(params, 1e9, 0, wrapper, "")` rather than the (inert) direct transfer. R5 mitigation reframed from "defence-in-depth" to **hard requirement** — adversarial pass clarified that path (b) of the truncating-cast (Stranded branch) leaves USDC permanently inaccessible via the only intended recovery path, not just "wrong stored amount". Q8 / S7b accrueInterest / 18-dec S7 remain BLOCKED in the adversarial pass on Tenderly Pro write-quota exhaustion — carried into §Sign-off "Next action". 72/72 forge tests pass post-fix. |
| v1.2.4 | 2026-05-14 | criptopoeta (Opus 4.7) + Codex | Codex Q1-closure adversarial review (job `review-mp6aqwx9-y3adft`, session `019e2975…7045`) verdict: **needs-attention** with 3 findings. All closed by Codex `task --write --effort high` (job `task-mp6axmz1-pt96jm`): **F1 [HIGH]** PR-4 drop left `docs/INCIDENT_RESPONSE.md` instructing operators to call a non-existent `setPoolLive` — narrow re-add of `isLive` per-market in `FxMarketRegistry` (NO `perPoolCap`/fee/deviation fields; rest of `AssetRiskParams` stays deferred per "narrower" intent) gated by `OPERATIONS_ROLE`; new `setPoolLive` admin + `isPoolLive` view + `PoolLiveSet` event + `PoolNotLive` error; entry-side `supply`/`supplyCollateral`/`borrow` now check both global `whenNotPaused` AND per-pair `_assertPairLive`. Spec §3.3 updated to note narrow `isLive` only. **F2 [HIGH]** `DeployPatchV4.s.sol` lacked timelock handoff (left deployer with `DEFAULT_ADMIN_ROLE`) — script now non-broadcastable: `revertArchived()` top-of-`run()` with `DeployPatchV4Archived` error; historical body preserved as unreachable archival reference. **F3 [MEDIUM]** SDK ABI drift — `register-contracts.ts:85+` `EVENTS_OF` map updated for FxOracle/FxMarketRegistry/FxLiquidator: removed `OwnerTransferred`, added `RoleGranted`/`RoleRevoked`/`RoleAdminChanged`/`Paused`/`Unpaused`/`PoolLiveSet`; TS ABIs regenerated. DISPUTED finding: `listPools()` unbounded — registration is `DEFAULT_ADMIN_ROLE`-gated, no vector. Tests: **106/106 green** (local + fork; +2 new `test_fork_setPoolLive_*`). SDK 10/10. |
| v1.2.3 | 2026-05-14 | criptopoeta (Opus 4.7) | Phase 3 closure execution — Q1 `/bucket-analysis` gate pass. Hub mainnet pivoted Arc-when-GA → **Avalanche C-Chain**; PHPC + BRLA dropped from basket. **PR-1** specs in-tree (`docs/SPEC_PHASE_3_MULTI_STABLECOIN.md`, `docs/DEPLOY_MAINNET_HUB.md`, `docs/BLOCKED_PAIRS.md`); `DeployArcTestnetMocks.s.sol` trimmed to mAUDF/mJPYC/mMXNB/mZCHF; SDK addresses extended with `ChainId.AvalancheMainnet: 43114` + native basket addresses + ArcTestnet mock-slot placeholders. **PR-2 (narrower re-do)** R1 inflation property tests added to `MainnetFork.t.sol`: `test_fork_r1_directDonationIsInert` (pins `totalAssets()` override) + `test_fork_r1_morphoSideDonationDefended` (proves `_decimalsOffset()=6` defends at 100 USDC victim vs 1M USDC donation). v1.2.2 `_decimalsOffset()=6` defense re-landed in `FxReceipt.sol` (had been reverted; restored as predicate for R1 tests + per audit). **PR-3 (narrower re-do)** Oracle defaults standardized to spec §8 `(maxAge=300, dev=50bps, conf=30bps)` with post-condition `require()` asserts across all 4 deploy scripts; ABI shims added — `IFxOracle.priceOf(token)`, `IFxMarketRegistry.listPools()`, `FxSwapHook.quoteExactInput(sellToken, sellAmount)`. **PR-4 DROPPED** — `AssetRiskParams` struct, per-pool caps, `isLive` per-pair flag deferred to a future PR (proper governance + oracle-priced USD caps + better integration with PR-6's `Pausable`). **PR-5** `FxRouter.sol` shipped via subagent — `IFxRouter` impl wrapping OZ EIP-712 + Permit2 + SignatureChecker + ReentrancyGuardTransient + SafeERC20; hybrid swap-adapter pattern (`IFxRouterSwapAdapter` interface, owner-settable, mock for tests; real v4-unlock adapter is a follow-up); 21 new tests. **PR-6** governance migration shipped via subagent — `FxOracle`/`FxMarketRegistry`/`FxLiquidator` → OZ `AccessControl` + `Pausable`; new `contracts/src/governance/FxTimelock.sol` thin-wrapping OZ `TimelockController` (spec §2.5 + §10.2 updated — Compound 0.5.16 vendor not needed); atomic deploy handoff across 4 scripts with `require()` asserts that deployer holds no admin; 8 new `FxAccessControl.t.sol` tests. **PR-7** ops docs (`INCIDENT_RESPONSE.md`, `YIELD_SUBSTRATE_WATCHLIST.md`, `TESTNET_USAGE.md`). **Tests: 104/104 green** (8 FxAccessControl + 13 FxHubMessageReceiver + 4 FxMarketRegistryAuth + 21 FxOracle + 21 FxRouter + 5 FxSpoke + 21 FxSwapHook + 11 MainnetFork incl. the 2 R1 + listPools enumeration). Fork run hits the same 104/104 with mainnet-fork. |
