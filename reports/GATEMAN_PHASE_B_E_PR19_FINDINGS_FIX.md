# Gateman Verification Report

**Feature:** Phase B-E Gateman findings fix: funding lifecycle, signed-order fee binding, invariant breadth, smoke fetch validation  
**Branch / PR:** `codex/phase-b-e-perps-addresses` / PR #19  
**Date:** 2026-05-17  
**Verifier:** Codex using `/gateman-analysis`

## Score

| Category | Score | Notes |
|---|---:|---|
| Error handling | 9/10 | Funding links and settlement hooks fail loud with custom errors; Hermes response validation now rejects malformed payloads. |
| Logging / observability | 8/10 | Deploy/config verifier now exports funding link readbacks; smoke still emits operator logs rather than structured logs. |
| Type safety | 9/10 | EIP-712 order type now includes `maxFee`; SDK manifest loader validates optional funding links; smoke validates Pyth update hex at runtime. |
| Testability | 9/10 | Added unit coverage for funding-before-close, funding-before-withdraw, signed max fee, and expanded 256-run invariants across shorts/funding/liquidation/withdrawals. |
| Performance | 8/10 | Funding settlement loops configured markets only. Current Arc target is four markets; keep this bounded in future market listings. |
| Security | 9/10 | Previous HIGH funding evasion path is closed in code; signed orders now bind execution fee ceiling. |
| AI verification | 9/10 | Re-read touched surfaces, grepped red flags, ran focused/full Foundry, SDK typecheck/tests, smoke bundle, ABI sync, format check, and size build. |

## Checks Passed

- Funding settlement is coupled before all clearinghouse position mutations:
  - `openOrIncrease`
  - `decreaseOrClose`
  - `applyOrderFill`
  - `liquidatePosition`
- `FxMarginAccount.withdrawMargin` now calls a configured funding settlement hook before computing free margin.
- Deploy/config scripts wire `FxPerpClearinghouse.setFundingEngine` and `FxMarginAccount.setFundingSettlementHook`.
- Arc readiness verifier checks:
  - `clearinghouse.fundingEngine == FxFundingEngine`
  - `margin.fundingSettlementHook == FxPerpClearinghouse`
- Signed orders now include `maxFee` in the EIP-712 type hash, signature digest, Solidity struct, SDK smoke typed data, and `settleMatch` execution path.
- The live smoke script uses `AbortController` for Hermes timeout and validates every returned Pyth update as non-empty hex.
- Expanded invariants now exercise long opens/closes, short opens/closes, funding settlement, liquidations, margin withdrawals, and oracle movement.
- No production `require` strings, raw ERC20 transfers, `delegatecall`, `tx.origin`, `as any`, or `@ts-ignore` were found in the reviewed perps production delta.

## Findings Closed

### HIGH - Funding can be avoided by closing before explicit settlement

**Status:** Closed in code.

The clearinghouse now settles market funding before any position size mutation, including close and liquidation. Margin withdrawal also settles all configured markets where the trader has an open position before checking free margin. Tests prove funding is charged before close and before withdrawal.

### MEDIUM - Signed orders do not bind max fee or config version

**Status:** Closed for max-fee binding.

The signed order now includes `maxFee`; settlement passes each trader's signed value to the clearinghouse instead of `type(uint256).max`. A unit test proves execution reverts when the signed fee ceiling is too low.

### MEDIUM - Invariant coverage is too narrow

**Status:** Closed for the reported gap.

The invariant handler now covers shorts, funding settlement, liquidation attempts, and withdrawals in addition to the prior long/price paths. Signed-order replay remains covered by unit test rather than invariant because the current matcher consumes one nonce per order fill.

### LOW - Operator smoke fetches Pyth without timeout and validates response shape lightly

**Status:** Closed.

Hermes fetch now has a 10-second abort path and validates response object shape, update array presence, and each update's hex encoding.

## Verification Commands Run

```bash
forge test --root contracts --offline --match-path 'test/perp/*.t.sol' -vv
bun run sdk:abis:sync
cd packages/sdk && bun run typecheck && bun test
cd packages/sdk && bun build scripts/perp-arc-trading-smoke.ts --target bun --outdir /tmp/fx-perp-smoke-build
forge build --root contracts --offline --sizes
forge test --root contracts --offline
git diff --check
forge fmt --root contracts --check <touched-solidity-files>
```

Observed results:

- Perps focused suite: 15 tests passed, including 256-run fuzz and two 256-run invariants.
- Full Foundry suite: 315 passed, 0 failed, 1 skipped.
- SDK typecheck and tests: passed, 38 tests.
- Smoke script bundle: passed.
- Contract sizes remain below 24KB:
  - `FxFundingEngine`: 5,677 bytes
  - `FxHealthChecker`: 3,144 bytes
  - `FxLiquidationEngine`: 3,569 bytes
  - `FxMarginAccount`: 5,106 bytes
  - `FxOrderSettlement`: 6,913 bytes
  - `FxPerpClearinghouse`: 10,356 bytes
- `git diff --check`: passed.
- Scoped Solidity format check on touched files: passed.

## Checks Failed

- Live Arc config verification and trading smoke were not rerun because these are ABI-affecting contract changes. The current live deployment does not expose the new funding hook and signed-order shape. A redeploy/configure pass is required before live smoke can be validly rerun.

## Recommended Next Steps

1. Redeploy the Phase B-E stack on Arc only after explicit user go-ahead.
2. Run `ConfigureArcPerpMarkets` to wire funding engine, margin funding hook, market params, funding params, liquidation params, and protocol liquidity.
3. Export a fresh `deployments/perps-config-5042002.json`.
4. Rerun Arc readiness verification and the live trading smoke against the new addresses.

## Risk Level

**LOW for code merge into the PR. MEDIUM until the new stack is deployed and live-smoked on Arc.**

## Sign-off

**Safe to ship:** `YES_WITH_FOLLOWUPS`

The original Gateman findings are fixed in the code delta and covered by tests. The remaining follow-up is operational: redeploy/configure the ABI-breaking contract update and run the live Arc smoke after explicit deployment approval.
