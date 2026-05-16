# Codex Brief — Phases B/C/D/E + SDK & Wiring

Context handoff for Codex to take Telarana from "spot live (Phase A v0)" to
"perp engine + signed-order settlement live (Phase E)". The session is
expected to run in a separate worktree.

## Non-negotiable rules (memory: feedback_no_novel_math)

1. **No novel math in production.** Every formula, accumulator, curve,
   solver, interest-rate model, signature scheme — vendor from a cited
   reference (Perennial v2, GMX Synthetics, Synthetix v3, Morpho-Blue,
   Curve, OZ Math, Uniswap v4-core, Bunni). If a reference doesn't have
   what you need, stop and ask. Acceptable: thin wrappers/adapters,
   plumbing, sign conventions copied verbatim from canonical hooks.
   **Not acceptable**: rederiving an inverse, hand-rolling a Newton solver,
   approximating an integral, writing a "temporary" math placeholder.
2. **OZ standard primitives only**: AccessControl over hand-rolled owner
   maps, ReentrancyGuard over manual locks, SafeERC20 over raw transfer,
   Pausable for incident response, `Math.mulDiv` for any `a*b/c`. CEI
   ordering. Custom errors not require-strings.
3. **Path A preserved**: BUFX request layer stays passive. All on-chain
   protocol mutations happen via a keeper EOA (currently the deployer
   `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`). Adding a perp engine
   does not change BUFX's "no Gateway / no hook" boundary.
4. **No frontend or SDK changes in this brief's first 3 phases** until
   the contract surface stabilizes. SDK/wiring lands in the dedicated
   SDK phase at the end.

## Live testnet state (build against this)

### Telarana (Arc — chainId 5042002)

| Contract | Address | Role |
|---|---|---|
| `FxHubMessageReceiver` (V2) | `0x44B50E93eCC7775aF99bcd04c30e1A00da80F63C` | Hub message hub, cross-hub relay surface |
| `FxGatewayHook` (V2) | `0x2931C50745334d6DFf9eC4E3106fE05b49717DF1` | Circle Gateway adapter (mint-to-hub flows) |
| `TelaranaGatewayHubHook` | `0x74E894aFf25c89d707873347cd2554d30E0541fa` | Spot-FX-aware destination wrapper |
| `FxSpotExecutor` (Phase A) | `0x23AB8992585Ff2E40833198f661374a070398876` | Oracle-anchored spot swap pool |
| `FxOracle` | `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865` | Pyth (+ optional RedStone) read surface |
| `FxMarketRegistry` | `0x813232259c9b922e7571F15220617C80581f1464` | Morpho-Blue lend/borrow surface |
| `FxLiquidator` | `0xa50f7D4D4a1A0D3CF418515973545b80E037B379` | Existing Morpho liquidator (NOT perps) |
| `FxReceiptUSDC` (ERC-4626) | `0xdd22365Bba7330BE537c9BC26da9b1b4Db9aC431` | USDC vault |
| `FxReceiptEURC` (ERC-4626) | `0xF829f57Db8530fa93FCD6e13b00193cbe8cE1493` | EURC vault |
| `MorphoBlue` | `0x3c9b95C6E7B23f094f066733E7797C8680760830` | Self-deployed Morpho on Arc |
| `USDC` (native gas) | `0x3600000000000000000000000000000000000000` | 6-dec ERC20 |
| `EURC` | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | 6-dec ERC20 |
| `MockJPYC` | `0x499347b5448660Ab17Cd4E32fA61c35D2ada7A5b` | 6-dec testnet mock |
| `MockMXNB` | `0x80e65233d83547dE3d78396f1Fb0338728C5e42b` | 6-dec testnet mock |
| `MockCHFC` | `0x2EacaCDAEf6a7ec82C168aFbdDd1B0E7D7993E69` | 6-dec testnet mock |

### Telarana (Fuji — chainId 43113)

| Contract | Address | Role |
|---|---|---|
| `FxHubMessageReceiver` (V2) | `0x7eAdfD0c08dd6544f763285bBD31be14179d594B` | Primary user-deposit hub |
| `FxGatewayHook` (V2) | `0x7dA191bfB85D9F14069228cf618519BFb41f371E` | Gateway adapter |
| Same `FxMarketRegistry`, `FxOracle`, etc. (see `deployments/hub-config-fuji.json`) | | |

### BUFX (Fuji + Arc)

| Contract | Address |
|---|---|
| `BuFxTelaranaRequestRouter` (Fuji) | `0x46cC11feD4F497C0C091b7bE5a1A21af133c26f1` |
| `BuFxVenueRequestRouter` (Fuji) | `0x84EE03C52B89B01315C9572520192274b570D2c3` |
| `BuFxTelaranaRequestRouter` (Arc) | `0xea11AfDc70eD0489346AC9d488C17155384B459c` |
| `BuFxVenueRequestRouter` (Arc) | `0xa73208b62AF9a87fb5e2b694B27f510D70e17746` |

### Live routeIds (BUFX + TGH share the same ID per pair)

| Direction | tokenOut | routeId |
|---|---|---|
| Fuji → Arc (mint-to-hub) | USDC | `0xf78147c98547731be048740d9d9089e6258e5e712e0c66f7b9d9d57d6af3a968` |
| Arc → Fuji (mint-to-hub) | USDC | `0x1a255f6aaa29b7ffd589c882eda0ab42f2613bfe51f271b6a677b318321a1efb` |
| Fuji → Arc spot | EURC | `0x4b50d101784ab33ee4adc9ca42080b10cdd2b23d71004a34a9625f3554e97f19` |
| Fuji → Arc spot | JPYC | `0xda73657812ef2aa4a59ca67e8d757ac98155cf6aac04e6c0a1723b6f2799a47b` |
| Fuji → Arc spot | MXNB | `0x4e26b194dd0f03e769ec58a34bcd4bbbe88f27d2aa1c502eb50dc20d4569512c` |
| Fuji → Arc spot | CHFC | `0x84d69f49ece767181be6ee9d8706e5007bc8dda02fed481bb21446760d3c3e4f` |

### Circle Gateway (deterministic across testnets)

| Contract | Address |
|---|---|
| `GatewayWallet` | `0x0077777d7EBA4688BDeF3E311b846F25870A19B9` |
| `GatewayMinter` | `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B` |
| BurnIntent authority | `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` (deployer EOA; rotates to hub via EIP-1271 mid-2026) |

## Reference repos (already cloned)

In `references/` (BUFX repo also has local copies under same names):

- **`perennial-v2`** → Phase B oracle-version settlement (`Market.sol`,
  `Global.sol`, `Local.sol`, version-keyed accumulators), Phase C funding
- **`gmx-synthetics`** → Phase C borrowing fees (`BorrowingFeesUtils`),
  Phase D position math (`PositionUtils`), Phase H event payloads
- **`synthetix-v3`** + **`synthetix-sample-v3-keeper`** → Phase E async
  order pattern (`AsyncOrderModule`, `AsyncOrderSettlementPythModule`),
  Phase D liquidation flagging, keeper-as-first-runner model
- **`perp-curie-contract`** → for **architectural reference only**;
  we are explicitly NOT doing vAMM
- **`morpho-blue`** + **`morpho-blue-snippets`** + **`metamorpho`** →
  Phase F LP capital (deferred; not in this brief)
- **`uniswap-v4-core`** + **`uniswap-v4-periphery`** +
  **`uniswap-v4-hooks-public`** → Phase A v1 upgrade (defer); not here
- **`openzeppelin-uniswap-hooks`** → safe hook templates for reference

## Architecture seam

```
contracts/src/
  hub/                        # existing Telarana (untouched)
  spot/
    FxSpotExecutor.sol        # Phase A v0 — shipped
  perp/                       # NEW — Phase B/C/D
    clearinghouse/
      FxPerpClearinghouse.sol
      FxPerpMarket.sol
      FxMarginAccount.sol
    settlement/
      FxOrderSettlement.sol   # Phase E
      FxOraclePriceCommit.sol # Pyth-version commit pattern
    funding/
      FxFundingEngine.sol
      FxBorrowingFeeModule.sol
    risk/
      FxLiquidationEngine.sol
      FxInsuranceFund.sol
      FxHealthChecker.sol
    fees/
      FxPerpFeeModule.sol
      FxFeeDistributor.sol
      FxReferralRegistry.sol
      FxLiquidatorRewards.sol
    interfaces/
      IFxPerpClearinghouse.sol
      IFxPerpMarket.sol
      IFxMarginAccount.sol
      IFxFundingEngine.sol
      IFxLiquidationEngine.sol
      IFxOrderSettlement.sol
```

---

## Phase B — Perp Clearinghouse Skeleton

**Goal:** USDC-margined perp positions can be opened/increased/decreased/
closed against an oracle mid. No funding, no liquidations yet. Position
state lives on-chain.

**Surface to build:**

### FxMarginAccount.sol

Per-trader USDC margin. Cross-mode v1 (isolated comes in Phase G).

```solidity
interface IFxMarginAccount {
    function depositMargin(address trader, uint256 amount) external;
    function withdrawMargin(address trader, uint256 amount) external;
    function marginOf(address trader) external view returns (uint256);
    function reserveMargin(address trader, uint256 amount) external; // clearinghouse-only
    function releaseMargin(address trader, uint256 amount) external; // clearinghouse-only
}
```

**Reference:** Synthetix v3 `PerpsAccountModule` for the deposit/withdraw
shape + free-margin vs reserved-margin split. Don't copy the synth
exchange machinery — we don't need it.

### FxPerpMarket.sol

Per-market state. One contract per pair (USD/EUR, USD/JPY, USD/MXN,
USD/CHF). Holds open interest long/short, total notional, position
registry, oracle reference.

```solidity
struct Position {
    int256 size;           // signed: long > 0, short < 0
    uint256 entryPriceE18; // oracle mid at last settlement
    uint256 marginReserved;
    uint64  lastSettleVersion;
}

interface IFxPerpMarket {
    function marketId() external view returns (bytes32);
    function position(address trader) external view returns (Position memory);
    function openInterestLong() external view returns (uint256);
    function openInterestShort() external view returns (uint256);
    function maxOpenInterest() external view returns (uint256);
    // Settlement hook called by clearinghouse, not user-facing.
    function _applyPositionDelta(address trader, int256 sizeDelta, uint256 priceE18, uint256 version)
        external returns (Position memory);
}
```

**Reference:** Perennial v2 `Market.sol` for the oracle-version settlement
shape. Each market has a `Global` + per-account `Local` accumulator
keyed by oracle version. Position deltas commit pending; next oracle
version settles them.

### FxPerpClearinghouse.sol

Orchestrates orders, validates margin, checks OI caps, talks to oracle,
calls market.

```solidity
interface IFxPerpClearinghouse {
    function openOrIncrease(
        bytes32 marketId,
        address trader,
        int256 sizeDelta,        // signed
        uint256 maxFee
    ) external returns (bytes32 positionKey);

    function decreaseOrClose(
        bytes32 marketId,
        address trader,
        int256 sizeDelta
    ) external returns (uint256 marginReleased);

    // Reads
    function quoteFee(bytes32 marketId, address trader, int256 sizeDelta)
        external view returns (uint256 fee, uint256 priceE18);
}
```

Oracle reads: `FxOracle.getMidVerified(USDC, tokenOut)` (Pyth + RedStone
deviation gate). Caller must wrap tx with RedStone calldata; alternatively,
use `getMidWithUpdate` and bundle Pyth payload as `bytes[]`.

**Math reference for margin / leverage check:**
`requiredMargin = abs(sizeDelta) * priceE18 / leverageBps / 1e18`.
Identical to Synthetix v3 `PerpsMarket.getRequiredMargins` shape. Use OZ
`Math.mulDiv`.

**BUFX integration:** `BuFxVenueRequestRouter.requestPerpLiquidity` (live)
already records perp intents. Wire the clearinghouse to read those
events via the keeper; do **not** call BUFX directly from the
clearinghouse.

**Tests:** Foundry unit (`FxPerpClearinghouse.t.sol`):
- open long, oracle settles next version, position state correct
- increase existing long
- decrease (partial close), margin released
- full close
- revert on OI cap
- revert on insufficient margin
- revert on oracle stale
- multi-trader symmetry: long vs short OI accounting

**Sizing:** ~3-4 weeks. Oracle-version settlement is the hard part —
budget time for it.

**Exit criteria:** Demo loop works on Arc testnet: trader deposits 100
USDC, opens 5× long EUR/USD position, closes, withdraws margin minus fee.

---

## Phase C — Funding + Borrowing Fees

**Goal:** Longs pay shorts (or vice versa) hourly funding. LPs earn
utilization-based borrow fees.

### FxFundingEngine.sol

Peer-to-peer funding rate. Per-oracle-version accrual to long vs short
side.

**Reference:** Perennial v2 `Global.update` + `Local.accumulate`. The
funding index is keyed by oracle version. Each position settles at the
version it was opened/last-touched at; funding accrues by reading
`globalFundingIndex[currentVersion] - globalFundingIndex[lastSettleVersion]`
and applying to position size.

```solidity
interface IFxFundingEngine {
    function settleFunding(bytes32 marketId, address trader) external returns (int256 fundingPaid);
    function getFundingIndex(bytes32 marketId, uint64 version)
        external view returns (int256 cumulativeFundingE18);
    function pokeFundingRate(bytes32 marketId) external; // permissionless
}
```

Funding rate formula (cite + use verbatim):
- Perennial v2: `fundingRate = clamp(k * skew, -maxRate, +maxRate)`
  where `skew = (OI_long - OI_short) / OI_max`, `k` is funding curvature.
  See `references/perennial-v2/contracts/types/RiskParameter.sol`.
- **Do not** invent your own funding curve.

### FxBorrowingFeeModule.sol

Utilization-based fee. As perp pool utilization grows, LP borrow rate
goes up.

**Reference:** GMX `BorrowingFeesUtils` (`references/gmx-synthetics/
contracts/borrowing/BorrowingFeesUtils.sol`). Use the same
`cumulativeBorrowingFactor` pattern.

```solidity
interface IFxBorrowingFeeModule {
    function getCumulativeBorrowingFactor(bytes32 marketId, bool isLong)
        external view returns (uint256);
    function updateBorrowingFactor(bytes32 marketId) external;
    function pendingFee(bytes32 marketId, address trader) external view returns (uint256);
}
```

**Tests:**
- Funding accrues correctly across multiple oracle versions
- Long pays funding when long-heavy skew
- Short pays funding when short-heavy skew
- Borrowing factor monotonic
- Position close pays exact pending funding + borrow

**Sizing:** ~2 weeks. Math is well-trodden; just need careful
oracle-version bookkeeping.

---

## Phase D — Liquidation + Insurance Fund

**Goal:** Unhealthy positions can be liquidated. Bad debt absorbed by
insurance fund.

### FxHealthChecker.sol

```solidity
interface IFxHealthChecker {
    function healthFactor(bytes32 marketId, address trader)
        external view returns (uint256 ratioBps);
    function isLiquidatable(bytes32 marketId, address trader)
        external view returns (bool);
    function maintenanceMargin(bytes32 marketId, address trader)
        external view returns (uint256);
}
```

**Reference:** Synthetix v3 `LiquidationModule.getAccountLiquidatable`
shape (`references/synthetix-v3/protocol/synthetix/contracts/modules/
core/LiquidationModule.sol`). Maintenance margin ratio per market is a
risk param, set by admin.

### FxLiquidationEngine.sol

Partial + full liquidation. Liquidator submits, gets bounty, position
mark-down absorbed by insurance.

**Reference:**
- Synthetix v3 `flagAccount` + `liquidate` two-step (gives time for
  trader to add margin)
- GMX Synthetics `PositionUtils.decreasePosition` for the partial-close
  shape under liquidation

```solidity
interface IFxLiquidationEngine {
    function flagAccount(bytes32 marketId, address trader) external;
    function liquidate(bytes32 marketId, address trader, uint256 maxSizeToCloseAbs)
        external returns (uint256 liquidatorReward, int256 socializedLoss);
}
```

### FxInsuranceFund.sol

USDC pool. Absorbs negative-equity gaps from liquidations.

**Reference:** Perennial v2 `Vault` for the deposit/withdraw + share-based
accounting (anyone can underwrite; share value drops when insurance pays
out). DO NOT do owner-only-insurance; vendor the share math.

### FxLiquidatorRewards.sol

Liquidator bounty = `min(positionRemainingMargin * bountyBps,
bountyCap)`. Standard pattern — see GMX `LiquidationUtils.calculateLiquidatorRewardAmount`.

**Tests:**
- Healthy position cannot be liquidated
- Unhealthy: flagAccount → wait → liquidate
- Partial liquidation reduces size to bring health back to threshold
- Full liquidation when remaining margin < maintenance
- Negative-equity case: insurance fund absorbs, share value drops
- Bounty paid correctly to liquidator

**Sizing:** ~3 weeks. Liquidation is where protocols die — invariant
tests are required.

**Exit criteria:** Trader opens 25× position with thin margin, oracle
moves against them, keeper flags + liquidates, insurance covers any
shortfall.

---

## Phase E — Signed-Order Settlement (the "orderbook")

**Goal:** Off-chain matching engine produces signed maker+taker fills.
On-chain settlement validates EIP-712 sigs and mutates positions
atomically. UI sees a CLOB; chain sees a fill.

### FxOrderSettlement.sol

```solidity
struct SignedOrder {
    address trader;
    bytes32 marketId;
    int256 sizeDelta;
    uint256 priceE18;        // limit price; ignored for market orders
    uint8  orderType;        // 0=MARKET, 1=LIMIT, 2=STOP, 3=TP_SL
    uint8  flags;            // bit0=REDUCE_ONLY, bit1=POST_ONLY
    uint64 nonce;
    uint64 deadline;
}

interface IFxOrderSettlement {
    function settleMatch(
        SignedOrder calldata maker,
        bytes calldata makerSig,
        SignedOrder calldata taker,
        bytes calldata takerSig,
        uint256 fillSize,
        uint256 fillPriceE18
    ) external;

    function cancelOrder(uint64 nonce) external; // user-callable
    function nonceBitmap(address trader, uint256 wordPos) external view returns (uint256);
}
```

**Reference:**
- Synthetix v3 `AsyncOrderModule` for the order-commit + later-settle
  pattern (cite `references/synthetix-v3/markets/perps-market/contracts/
  modules/AsyncOrderModule.sol`)
- Permit2 `nonceBitmap` for replay protection — vendor verbatim from
  Uniswap's Permit2 (don't hand-roll)
- Hyperliquid L1 batched settlement pattern for the matched-fill shape

EIP-712 typed data for `SignedOrder` — vendor the typed-data hashing
from OZ `EIP712.sol`; do not hand-roll the domain separator.

### Off-chain matcher service (separate repo / bun service)

- Subscribes to on-chain `OrderPlaced` events (orders submitted but not
  filled — or accepts orders via a REST API + signature)
- Price-time priority matching
- Emits matched fills as a (maker, taker, fillSize, fillPrice) tuple
- Submits to FxOrderSettlement via a keeper EOA

**Reference:** dYdX v4's order book (Go service, but the matching logic
is well-documented). Or Hyperliquid's published L1 spec.

**Tests:** Foundry unit:
- Match two opposite-side limit orders → both positions update
- Reject mismatched sigs
- Reject expired orders
- Reject filled-twice (nonce already consumed)
- Reduce-only flag enforced
- Post-only rejects on cross

**Sizing:** Contract ~3 weeks. Matcher service ~4 weeks if production-grade.

**Exit criteria:** UI submits a limit order, off-chain matcher posts a
fill, on-chain position state updates atomically.

---

## SDK + Wiring Phase (after B/C/D/E land)

### Telarana SDK additions (`packages/sdk/src/`)

New modules:
- `perp.ts` — `openPosition`, `closePosition`, `getPositionHealth`,
  `quoteFee` helpers
- `funding.ts` — `pendingFunding`, `pendingBorrow`
- `liquidation.ts` — `isLiquidatable`, `liquidatorReward`
- `settlement.ts` — `signOrder` (EIP-712), `cancelOrder`, `verifyOrder`

ABI files under `packages/sdk/src/abis/`:
- `FxPerpClearinghouse.ts`
- `FxPerpMarket.ts`
- `FxMarginAccount.ts`
- `FxFundingEngine.ts`
- `FxLiquidationEngine.ts`
- `FxInsuranceFund.ts`
- `FxOrderSettlement.ts`

Sync via the existing `packages/sdk/scripts/sync-abis.mjs` (already in
repo).

### BUFX SDK additions (separate repo: `git@github.com:BuFi007/BUFX.git`)

Extend `packages/sdk/src/`:
- Re-export the perp ABIs from Telarana (or copy-paste; BUFX SDK is
  consumed by the frontend)
- `bufxPerpRequest` builder: BUFX-side perp request that the keeper
  reads and forwards to the clearinghouse
- Event indexer extensions in `scripts/stage12TraceCrossHubFlow.ts` to
  also decode perp events

### Smoke + integration scripts (BUFX repo)

Extend `scripts/stage12SmokeKeeperRelay.ts` with new actions:
- `--action=open-perp` — keeper-driven open
- `--action=close-perp`
- `--action=add-margin`
- `--action=withdraw-margin`
- `--action=settle-order` (Phase E)
- `--action=liquidate` (Phase D)

### Deployment scripts (Telarana)

One forge script per phase, env-driven, same pattern as
`DeployFxSpotExecutor.s.sol`:
- `DeployFxPerpStack.s.sol` (clearinghouse + market + margin account)
- `DeployFxFunding.s.sol`
- `DeployFxLiquidation.s.sol`
- `DeployFxInsurance.s.sol`
- `DeployFxOrderSettlement.s.sol`

Each script must:
- Be idempotent (skip if existing address provided via env)
- Write to `deployments/<chain>.json`
- Emit a post-deploy wiring checklist in the console output

### Per-pair config (Phase B/C/D)

For each market (USD/EUR, USD/JPY, USD/MXN, USD/CHF) on Arc:
- Deploy one `FxPerpMarket` instance
- Configure max OI, initial/maintenance margin ratios, funding curvature
  (Perennial-style `k`), max leverage
- Grant clearinghouse role to interact
- Wire to FxOracle for price reads
- Add per-market route in BUFX SDK (analogous to spot routeIds)

## Sequence + dependency graph

```
Phase B (clearinghouse + market + margin)
   ↓ requires
Phase C (funding + borrow)
   ↓ requires
Phase D (liquidation + insurance)
   ↓ requires
Phase E (signed-order settlement)
   ↓ requires
SDK + wiring phase
```

Phase B can start without A's reverse-leg done (perp positions don't
need an automatic spot hedge in v1; manual hedge via Phase A is fine).

## Decisions Codex needs from the user (do not invent)

1. **Maintenance margin ratio per market** (default = 5%? user pick)
2. **Max leverage per market** (default = 25× per the screenshot)
3. **Funding rate cap** (Perennial-style, e.g. ±0.01% per oracle version)
4. **Liquidator bounty** (e.g. 10% of remaining margin, capped at $50)
5. **Insurance fund seed** (initial USDC deposit, source)
6. **Order types** at v1 (Market + Limit minimum; Stop + TP/SL nice-to-have)
7. **Matcher service**: build in-house vs adapt an open-source matcher
8. **Per-market OI caps** — risk team should pick
9. **Spread / fee schedule** at the perp layer (Telarana fee, BUFX fee)
10. **Treasury splits** — what % of fees go where

Codex should ask the user before locking these in, NOT pick defaults
silently.

## Stop-the-world checks before each phase ships

- [ ] All new contracts use OZ AccessControl + ReentrancyGuard + Pausable
      + SafeERC20 + Math.mulDiv
- [ ] Every formula has a NatSpec citation to a vendored reference
- [ ] Foundry tests: unit + invariant + at least 256 fuzz runs per
      math-heavy entry point
- [ ] `forge build --sizes` shows no contract over the 24KB cap
- [ ] No `require` strings — all custom errors
- [ ] Pause path tested for incident response
- [ ] Deployer doesn't accidentally get `DEFAULT_ADMIN_ROLE` in
      production — explicit transferAdmin via deploy script
- [ ] Live verify test (`bun run live:verify:foundry` equivalent for
      perp markets) once deployed

## Open seams not yet covered (defer to a later session)

- **Phase F (LP capital via Morpho + MetaMorpho)**: replaces
  owner-seeded liquidity on FxSpotExecutor + insurance fund + perp pool.
  Builds on `references/morpho-blue` + `references/metamorpho`.
- **Phase G (cross-hub margin portability)**: trader on Fuji funds perp
  on Arc via Stage 12 rail. Hyperlane message lane for position-state
  mirror.
- **Phase H (production hardening)**: external audit, mainnet risk
  params, circuit breakers, oracle-staleness fallbacks.
- **Reverse spot leg** (Phase A v0.5): tokenOut → USDC on FxSpotExecutor.
  Small extension to the current contract.
- **Phase A v1 (Uniswap v4 hook upgrade)**: replace the constant-spread
  pool with the existing `FxSwapHook.sol` (836 lines, on Base Sepolia
  today) once Uniswap v4 PoolManager is on Arc.

## Where to read the spot work

- Contract: `contracts/src/spot/FxSpotExecutor.sol`
- Tests: `contracts/test/FxSpotExecutor.t.sol` (17/17 pass)
- Deploy: `contracts/script/DeployFxSpotExecutor.s.sol`
- Operator runbook: `docs/PHASE_A_SPOT_EXECUTOR.md`
- BUFX-side smoke: `scripts/stage12SmokeKeeperRelay.ts` in the BUFX repo
- Live smoke report (1 USDC → 0.86 EURC end-to-end):
  `reports/stage13/phase-a-live-smoke.json` in the BUFX repo

## Where to read prior cross-hub work

- Operator runbook: `docs/STAGE12_OPERATOR_RUNBOOK.md` in the BUFX repo
- Architecture: `docs/BUFX_INTEGRATION.md` in this Telarana repo
- Gateway signer: `packages/sdk/scripts/gateway-signer.ts` in this repo
