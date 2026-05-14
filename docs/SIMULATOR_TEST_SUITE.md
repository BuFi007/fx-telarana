# fx-Telaraña Simulator Test Suite

Goal: validate the full hub-and-spoke model end-to-end with Tenderly's
Simulator — every spoke → hub deposit path, every hub-side operation,
every wallet persona at every balance level.

## Why Tenderly Simulator (vs Foundry forge test)

| Need | Foundry | Tenderly Simulator |
|---|---|---|
| Local unit tests, deterministic | ✅ best | ❌ overkill |
| Live-chain state with overrides | ❌ stateless | ✅ exact tool |
| Cross-chain bundle (CCTP V2 burn → mint) | ❌ can't | ✅ chain per sim |
| Dashboard visibility for the team | ❌ | ✅ shareable URL per sim |
| Trace + gas profile + decoded logs | partial | ✅ best |

Foundry covers local invariants (already 65/65 passing). The Simulator
covers **the deployed system as it actually runs on each chain**, with
real Morpho, real Pyth, real CCTP V2 — pre-loaded with personas via state
overrides instead of relying on chain-side faucets.

## Test matrix

### A. Spoke → Hub deposit (8 spoke chains × 4 personas × 2 hubCalldata flavors)

Per spoke chain (ethereum-sepolia, op-sepolia, arbitrum-sepolia,
unichain-sepolia, avalanche-fuji, polygon-amoy, worldchain-sepolia, arc-testnet):

For each persona:
- **Whale**     — 1,000,000 USDC, deposit 100,000 USDC
- **Mid**       — 1,000 USDC, deposit 500 USDC
- **Small**     — 1 USDC, deposit 0.5 USDC
- **Empty**     — 0 USDC, attempt 100 USDC (must revert `transferFrom failed`)

Two hubCalldata flavors per persona:
- **Supply-USDC** — `FxMarketRegistry.supplyCollateralAndBorrow(...)` to mint fxUSDC + borrow EURC
- **Supply-and-park** — pure supply, no borrow

→ 8 × 4 × 2 = **64 simulations** for category A.

### B. Hub-side primitives (Base Sepolia, 4 personas)

- **Mint fxUSDC**     — supply USDC → ERC-4626 shares
- **Mint fxEURC**     — supply EURC → ERC-4626 shares
- **Borrow EURC**     — collateral=USDC, debt=EURC
- **Borrow USDC**     — collateral=EURC, debt=USDC
- **Swap USDC→EURC**  — via Uniswap v4 + `FxSwapHook`
- **Swap EURC→USDC**  — reverse
- **Redeem fxUSDC**   — burn shares → USDC out
- **Redeem fxEURC**   — burn shares → EURC out

→ 8 flows × 4 personas = **32 simulations** for category B.

### C. Risk + recovery (Base Sepolia)

- **Healthy borrow at 60% LTV**
- **Borrow at 85.9% LTV** (just under 86% LLTV — boundary)
- **Borrow at 86.1% LTV** (must revert)
- **Liquidate underwater position** (push oracle, call FxLiquidator.liquidate with `maxRepayAssets` cap)
- **Liquidate with insufficient allowance** (must revert `InsufficientApproval`)
- **Liquidate using `useVerified=true` on a chain without RedStone** (must revert; documents the fallback to `getMidWithUpdatePyth`)
- **Sweep stranded deposit before 24h grace** (must revert)
- **Sweep stranded deposit after 24h grace** (succeeds; uses `evm_increaseTime` override)
- **Oracle staleness** — Pyth feed > 600s old, no fresh update → reverts; then re-sim with `getMidWithUpdatePyth` payload → succeeds

→ **9 simulations** for category C.

### D. Swap-hook edge cases (Base Sepolia)

- **Quote at equilibrium** — spread-only, no size impact
- **Quote large trade** — size-impact term kicks in
- **Pool starved** — hot reserve below 20% target, JIT withdraw from Morpho fires
- **afterSwap rebalance** — fees flow back to Morpho supply
- **Pool drained** — hot reserve = 0, full borrow fallback

→ **5 simulations** for category D.

## Total

**A (64) + B (32) + C (9) + D (5) = 110 simulations.**

Run time at ~3s/sim = ~6 minutes wall-clock. Tenderly's `simulate-bundle`
endpoint can batch the related ones (e.g. deposit + supply in one bundle),
cutting wall-clock further.

## Infrastructure

`packages/sdk/scripts/simulator/` — TypeScript test harness:
- `client.ts`       — Tenderly Simulate API client (single + bundle).
- `personas.ts`     — wallet persona definitions + per-chain ERC-20
                       storage-slot maps (USDC / EURC `_balances` slots),
                       so a single helper can mint any persona at any
                       balance via `state_objects`.
- `matrix.ts`       — declarative test definitions (the 110 above).
- `run.ts`          — runs the matrix, writes JSON + Markdown reports,
                       prints failing sims with their dashboard URLs.
- `report.ts`       — turns a run's output into a publishable Markdown
                       table (one row per sim, links to Tenderly trace).

## Phasing

This document is the contract. I'll build it in three drops:

1. **Drop 1** — client + personas + one happy-path sim per spoke (8 sims),
   so the pattern is proven and the dashboard view tells the story.
2. **Drop 2** — category A complete (64 sims) + category B (32 sims).
3. **Drop 3** — categories C + D (14 sims) + property-style fuzzers
   (random persona × random op).

After Drop 3, the suite is a `bun run sim:matrix` away from re-running
itself after any contract redeploy, with a Markdown report committed
alongside the deployment manifest.
