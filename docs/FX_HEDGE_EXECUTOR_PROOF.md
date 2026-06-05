# FxHedgeHook -> Perps Execution Proof

Status: proven locally, no live broadcast.

## Verdict

`FxHedgeHook` is not self-executing on the swap/liquidity callback path. It automatically computes the target hedge size on-chain (`poolHedgeSizeE18`) and emits `HedgeRebalanced`, but no perp position is opened by the hook itself.

Actual perp execution is keeper-triggered through `FxHedgeExecutor.executeHedge(poolId)`. The executor is permissionless, reads the hook target, then calls the real `FxPerpClearinghouse.openOrIncrease` / `decreaseOrClose` path as the hedge trader.

## Proof Added

`contracts/test/hub/FxHedgeExecutor.t.sol` now includes `FxHedgeHookExecutorIntegrationTest`:

- deploys a mined `FxHedgeHook`
- configures a JPYC/USDC pool and real perp market
- seeds pool exposure via `afterAddLiquidity`
- asserts the hook target is set while the clearinghouse position remains zero
- calls `FxHedgeExecutor.executeHedge(poolId)` from an unprivileged keeper
- asserts the real clearinghouse short matches the target and `executor.isHedged(poolId)` is true

Run from `contracts/`:

```bash
forge test --match-path test/hub/FxHedgeExecutor.t.sol -vvv
```

Result: 11 pass.

## Operational Implication

The auto-hedge loop is automatic only up to target calculation. Production still needs a keeper, bot, or on-chain automation job to poke `executeHedge(poolId)` after hook exposure changes. This is intentionally off the swap hot path.
