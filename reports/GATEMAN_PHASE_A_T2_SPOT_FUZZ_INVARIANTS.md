# Gateman Analysis - Phase A T2 Spot Executor Fuzz and Invariants

Date: 2026-05-17
Branch: `codex/phase-a-audit-ready-tier1`

## Scope

T2 adds Foundry fuzz and invariant coverage for `FxSpotExecutor` v0.1 without
changing production behavior. The only production touch is a comment update
that points the existing `mulDiv` formula note at the vendored GMX/Synthetix
reference paths.

## Checks

- Assume nothing: fuzzed amount, oracle mid, spread, and token decimals rather
  than relying on the existing fixed 1 USDC happy path.
- Question everything: tested both acceptance and rejection paths: exact quote
  delivery, canonical slippage rejection, and mismatched decimal allowlist
  rejection.
- Worship no one: invariant handler models TGH-delivered USDC and canonical
  receipts directly, then asserts conservation instead of trusting event logs.
- Applaud humility: invariants are intentionally scoped to v0.1 behavior:
  USDC stays in the executor, tokenOut payouts conserve seeded reserves, and
  every successful execution settles the mocked TGH receipt.

## Evidence

- `forge test --root contracts --match-path test/FxSpotExecutor.t.sol -vv`:
  30 passed, including 3 fuzz tests at 256 runs each and 3 invariants at
  256 runs / 128,000 calls each.
- `forge test --root contracts`: 246 passed, 0 failed, 1 existing skip.
- `forge build --root contracts --sizes`: compiled successfully.
  `FxSpotExecutor` remains 8,536 bytes runtime; all contracts remain under
  the 24KB runtime limit.
- `git diff --check`: clean.

## Result

PASS. T2 closes the missing fuzz/invariant coverage gap for v0.1. No deploy or
live smoke is required because production bytecode did not change.

