# Integration handoff — frontend + rust-matcher

Snapshot of fx-Telaraña at `main` HEAD `c0ff0d3` (2026-05-22). This is the single artifact to wire the frontend and the rust-matcher orderbook against.

## What's live as of this snapshot

### Sprint-1 perp stack (Fuji + Arc, broadcast 2026-05-21)

| Contract | Arc Testnet (5042002) | Fuji (43113) |
|---|---|---|
| `FxOracle` | `0xf9b0356A31BC7125e2eD0DADf8b5957860d42c78` | `0xC9CBF1c262871F0D1A401558adDf66008fe1c735` |
| `FxPerpClearinghouse` | `0x7707d108F6Ce3d95ceA38D3965448F00C21CaFdC` | `0x5fe82aFd87bdEE8911FfED1427c2bF653Bca4AcA` |
| `FxMarginAccount` | `0x77BBAef17257AD4800BE12A5D36AF87f3a49FBb7` | `0x2EacaCDAEf6a7ec82C168aFbdDd1B0E7D7993E69` |
| `FxFundingEngine` | `0xE08a146B9081A8dd32203fC5e7B5988352489518` | `0xB3142418EacEc98dCD33f722603043c830DED376` |
| `FxHealthChecker` | `0x234E06a0761cde322E4Fc5065A8256247669F362` | `0x80c6CA073b7e22ebff0E2e49b717E5902C5bC6C7` |
| `FxLiquidationEngine` | `0x18DEA7845c36d45AaDbcCeC04aC6cFc103748D80` | `0x6690b4B9Cb9B97B5752F86c6354A55D3eF55876C` |
| `FxOrderSettlement` | `0xCeae7846c8ED2Dd9E6f541798a657875305EA0d8` | `0x01A3186ffb7c0c4b8f7A352Dbb8F8A5EA4649F5D` |

**Invariants on both chains (verified live):**
- `MAX_ORACLE_AGE_HARD_CAP = 1800s`, `MAX_DEVIATION_BPS_HARD_CAP = 500`, `MAX_CONFIDENCE_BPS_HARD_CAP = 500`
- `oracle.config() = (300s, 50bps, 30bps)`
- `liquidationConfig = (bountyBps=500, bountyCap=5e6, flagDelay=120s)`
- `rescindFlag()` + auto-rescind early-return present

**Arc markets listed:** EURC, tJPYC, tMXNB, cirBTC (tCHFC unlisted, market entry inert on-chain)
**Fuji markets listed:** EURC, MXNB

### Arc canonical Morpho markets (broadcast 2026-05-21)

| Pair | marketId | OracleAdapter |
|---|---|---|
| USDC / MXNB | `0x64c65920ab4d9565b8f5a99ba8b209e9a4ccad0a9ef4a4f60b926cfa73872558` | `0x6a4d892A264a6738b13703d41F741062CCA4917c` |
| USDC / QCAD | `0xd5987f44b0ecb725e800435d91bfa3fc5217177951753ca8a06ee9d40c4dbb8c` | `0xF06C3F37c8feF2248aA728189F8883B99B1589f2` |
| USDC / cirBTC | `0xa1abaefec3fcc67588b43f62509609fc03c2417352b30afe6aa9bdd87e02910d` | `0xCbE5d3b833F221462C15FE35A9C2cb1d21670Ed8` |

All on canonical MorphoBlue `0x65f435eB…`, AdaptiveCurveIrm `0xBD583cc9…`, LLTV 86%.

### Arc canonical Morpho infrastructure

| Contract | Address |
|---|---|
| MorphoBlue | `0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4` |
| AdaptiveCurveIrm | `0xBD583cc9807980f9e41f7c8250f594fB6173abE3` |
| MorphoChainlinkOracleV2Factory | `0xEBef760B0CA0d1Fa9578f47001A184Ee53EaE839` |
| VaultV2Factory | `0x6b7F638B64539F83810A1f6ea81C703b561C3Be6` |
| MorphoMarketV1AdapterV2Factory | `0x9372EbEDF2C64344817c67dAeD99512F4b9DC434` |
| RegistryList | `0xcba6be0EF65176CE7D440A4a93657fb2dd84200c` |

### Arc token registry

| Token | Address | Status |
|---|---|---|
| USDC | `0x3600000000000000000000000000000000000000` | native gas |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | issuer |
| MXNB | `0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461` | issuer (NEW 2026-05-21) |
| QCAD | `0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d` | issuer (NEW 2026-05-21) |
| cirBTC | `0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF` | issuer (NEW 2026-05-21) |
| FxEscrow (Circle StableFx) | `0x4A3c9ede465dE9AEb185aEBF841B325e0C808661` | external — Permit2-witnessed FX escrow |

### Privacy hook (Fuji + Arc)

`FxPrivacyEntrypoint` (UUPS proxy, ERC-7201 namespaced storage) + per-currency `FxPrivacyPool` with Morpho rehypothecation + `FxFixedRateSwapAdapter` (cross-currency relay). Vendored 0xbow privacy-pools-core + lean-imt + PSE Poseidon (CREATE2 canonical addresses). End-to-end USDC-shielded → cross-currency-withdraw to EURC fresh address proven live on both chains.

Addresses in `deployments/privacy-hook-fuji.json` + `deployments/privacy-hook-arc.json`.

## Frontend wiring (defi-web-app)

### SDK consumption

```ts
import { ChainId, getAddresses } from "@bu/fx-engine";
import { FxPerpClearinghouseAbi, FxLiquidationEngineAbi, FxHealthCheckerAbi } from "@bu/fx-engine/abis";
import { PrivacyTradeClient } from "@bu/fx-engine/privacy";

const arc = getAddresses(ChainId.ArcTestnet);
arc.fxPerps.clearinghouse;  // 0x7707d108…
arc.morphoBlue;             // 0x65f435eB… (canonical)
arc.usdc;                   // 0x3600000000000000000000000000000000000000
arc.stablecoinBasket?.mxnb; // { address: 0x836F73Fb…, decimals: 6, ... }
arc.stablecoinBasket?.qcad; // { address: 0x23d7CFFd…, decimals: 6, ... }
```

### Required env for production keepers + frontends

- `DEPLOYER_PRIVATE_KEY` — protocol admin EOA (current: `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`; **flagged for rotation** — see Security note)
- `ARC_RPC_URL`, `FUJI_RPC_URL` — Arc + Fuji testnet RPCs
- `REDSTONE_DATA_SERVICE_ID` (default `redstone-primary-prod`) — for keeper RedStone payload wrap
- `REDSTONE_UNIQUE_SIGNERS_COUNT` (default 2) — for keeper RedStone payload wrap

### Key UX surfaces

- **Perp open / decrease / close** — call `FxPerpClearinghouse.openOrIncrease / decreaseOrClose` via SDK helpers. EIP-712 signed-order path via `FxOrderSettlement.settleMatch` for orderbook flow (this is what the rust-matcher consumes).
- **Margin** — `FxMarginAccount.depositMargin / withdrawMargin / marginOf / reservedMarginOf`.
- **Health** — read-only via `FxHealthChecker.healthFactor / isLiquidatable`. Frontend SHOULD show the **lenient** read for display; keepers MUST use `…Verified` variants with RedStone payload wrap.
- **Liquidation** — keepers call `flagAccount → wait 120s → liquidate`, all wrapped with RedStone via `writeWithRedstone` (see `packages/sdk/src/perps-keeper.ts:310`).
- **Privacy** — `PrivacyTradeClient` facade in `packages/sdk/src/privacy/services/`. Deposit / withdraw / cross-currency-relay are all behind the facade.

## Rust-matcher orderbook wiring

### EIP-712 signed-order surface

The matcher signs orders that get submitted via `FxOrderSettlement.settleMatch(maker, makerSig, taker, takerSig, fillSize, fillPrice)`.

Order struct (canonical):
```solidity
struct SignedOrder {
    address trader;
    bytes32 marketId;
    int256  sizeDeltaE18;
    uint256 priceE18;
    uint256 maxFee;
    uint8   orderType;   // ORDER_TYPE_LIMIT, ORDER_TYPE_MARKET
    uint8   flags;       // FLAG_POST_ONLY, etc.
    uint64  nonce;
    uint64  deadline;
}
```

EIP-712 domain: `name="FxOrderSettlement"`, `version="1"`, `chainId=5042002`, `verifyingContract=ARC_FX_ORDER_SETTLEMENT`.

Typehash and digest: read via `FxOrderSettlement.hashOrder(order)` (free view function).

**Reference TS implementation:** `packages/sdk/scripts/perp-arc-trading-smoke.ts` (lines 215–260) builds + signs + submits a maker/taker pair end-to-end. Port this signature recipe to Rust:
- `secp256k1` sig over the EIP-712 digest
- 65-byte `r||s||v` packed encoding
- `v ∈ {27, 28}` (NOT 0/1)

### Nonce + replay semantics
- `_useNonce` burns the per-trader nonce on successful match
- Re-using a nonce reverts `NonceAlreadyUsed(trader, nonce)`
- `deadline < block.timestamp` reverts

### Recommended matcher subscription set

Index these events for orderbook state + position state:
- `FxPerpClearinghouse.PositionIncreased(marketId, trader, sizeDeltaE18, resultingSizeE18, entryPriceE18, marginReserved, fee)`
- `FxPerpClearinghouse.PositionDecreased(marketId, trader, sizeDeltaE18, resultingSizeE18, priceE18, marginReleased, pnl, badDebt)`
- `FxOrderSettlement.OrderMatched(maker, taker, marketId, fillSize, fillPrice, makerNonce, takerNonce)` (verify the actual event signature in `IFxOrderSettlement`)
- `FxLiquidationEngine.AccountFlagged / AccountLiquidated / AccountFlagRescinded`
- `FxFundingEngine.FundingPoked / FundingSettled`

### Reading market state from Rust

Use the `FxPerpClearinghouse` view surface:
- `marketConfig(bytes32)` → `MarketConfig` struct
- `position(bytes32, address)` → `Position` struct
- `openInterestLong(bytes32)`, `openInterestShort(bytes32)`, `maxOpenInterest(bytes32)`
- `unrealizedPnl(bytes32, address)` — lenient (matcher use)
- `unrealizedPnlVerified(bytes32, address)` — strict (liquidation use; needs RedStone payload in calldata tail)

ABI exports are in `packages/sdk/src/abis/` — sync via `bun run sdk:abis:sync`.

## Test commands (verified green on this commit)

```bash
bun run contracts:test         # 397/398 forge (1 pre-existing skip)
bun run contracts:test:fork    # 413/414 — ETH mainnet fork vs real Morpho Blue
bun run sdk:test               # 83/83 (299 expect calls)
bun run contracts:size:guard   # all under EIP-170
```

## What's NOT yet on main

These items are open as PRs or sit on branches awaiting integration:

- **PR #41** — Wave M1/M4/N2a/N4 deploy artifacts on Arc (FxSwapHook, TelaranaGatewayHubHook v4 hook, PoolSwapTest periphery router, FxV4RouterHarness). `git merge-tree` reports clean against current main; GitHub UI shows phantom conflict from a partially-squashed L2 base. Land manually via the parent worktree.
- **Morpho V2 vault deploy** (Telaraña-curated MetaMorpho-V2 vault) — design + factory ABI vendoring deferred to next sprint. The factory addresses are recorded; only the deploy script + curated config decisions remain.

## Security note — deployer key rotation pending

Per `MEMORY.md` `feedback_key_safety.md` (if it exists; flagged this session): the deployer EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` was inadvertently echoed in this session's transcript via a shell `run()` helper that expanded `$*` containing `--private-key`. **The key controls admin/owner on every deployed contract listed above.** Rotation is non-blocking for development against testnet but should happen before any production load.

Rotation runbook (high level):
1. Generate new EOA
2. Transfer Arc USDC + Fuji AVAX from old EOA to new EOA
3. For each contract: either `grantRole(role, new) + revokeRole(role, old)` (AccessControl) or `transferOwnership(new)` (Ownable)
4. Update `.env.local` `DEPLOYER_PRIVATE_KEY`

The contract list to walk during rotation: every contract in `deployments/avalanche-fuji.json` + `deployments/arc-testnet.json` + `deployments/perp-stack-{43113,5042002}.json` + `deployments/perp-oracle-{43113,5042002}.json` + `deployments/privacy-hook-{fuji,arc}.json`.

## Recap of recent main commits

```
c0ff0d3 (#42) Wave N6 — FxV4RouterHarnessGateway + Demo B
1dfdee6 (#32) Wave L1 — Hyperlane MXNB bridge Fuji → Arc
a50f5c1 (#33) Wave L2 — Gateway intra-hook liquidity in TGH.beforeSwap
3bdf16d (#22) Record MXNB Fuji M3/M4 broadcast addresses
615dd2f (#38) Sprint-1 perp broadcast + Arc tokens + Morpho V2 wiring + tCHFC removal
8d1a7b9 (#24) Privacy hook — 0xbow shielded USDC/EURC + cross-currency relay
e6c16d1 (#25) Sprint-1 perp safety — verified oracle + rescindFlag + hard caps
```
