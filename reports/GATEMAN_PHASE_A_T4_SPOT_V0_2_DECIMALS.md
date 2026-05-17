# Gateman Analysis - Phase A T4 FxSpotExecutor v0.2 Decimals

Date: 2026-05-17
Branch: `codex/phase-a-audit-ready-tier1`

## Scope

T4 updates `FxSpotExecutor` from v0.1 equal-decimal allowlisting to v0.2
decimal-aware payout math. The executor now stores tokenOut decimals at
allowlist time, scales USDC atomic units to 18-decimal oracle precision,
applies the oracle mid, scales to tokenOut decimals, and then applies spread.

## Checks

- Assume nothing: token decimals are read from `IERC20Metadata` during
  allowlisting, stored on-chain, capped by `MAX_TOKEN_DECIMALS`, and cleared
  when disabled.
- Question everything: added explicit 6->18 and 6->8 payout tests, plus fuzz
  across amount, mid, spread, and tokenOut decimals.
- Worship no one: decimal scaling cites the vendored Synthetix v3
  `Price.scale/scaleTo` pattern and uses OZ `Math.mulDiv` for scaling, price,
  and spread arithmetic.
- Applaud humility: kept the public execution surface unchanged:
  `executeSpotFx(bytes32 requestId)` remains receipt-canonical and keeper
  supplies no payout context.

## Evidence

- `forge test --root contracts`: 249 passed, 0 failed, 1 existing skip.
- `forge build --root contracts --sizes`: compiled successfully.
  `FxSpotExecutor` is 9,508 bytes runtime, below the 24KB limit.
- `forge script --root contracts contracts/script/DeployFxSpotExecutor.s.sol:DeployFxSpotExecutor --rpc-url https://rpc.testnet.arc.network` with live Arc addresses and no `--broadcast`: simulation complete.
- `git diff --check`: clean.

## Result

PASS. T4 closes the decimal-aware payout math follow-up for v0.2. No live
deploy or smoke was executed because the user has not given deployment
approval.

