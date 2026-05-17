# Gateman Verification Report

**Feature:** Phase B-E perps PR delta: core contracts, deploy/config scripts, Arc config manifest exporter, SDK manifest loader  
**Branch / PR:** `codex/phase-b-e-perps-addresses` / PR #19  
**Date:** 2026-05-17  
**Verifier:** Codex using `/gateman-analysis`

## Score

| Category | Score | Notes |
|---|---:|---|
| Error handling | 8/10 | Solidity uses custom errors and fail-loud deploy/config verifiers. Operator smoke still has a network timeout gap. |
| Logging / observability | 7/10 | Contracts emit useful lifecycle events; scripts and reports capture live state. Smoke logging is operator-readable, not structured. |
| Type safety | 8/10 | SDK manifest loader performs runtime validation after `JSON.parse`; Solidity uses typed interfaces. Pyth response parsing has a cast with limited shape checks. |
| Testability | 7/10 | Unit, fuzz, and invariant coverage exist and pass. Invariants do not yet cover shorts, funding lifecycle, liquidation, or signed-order replay/fill surfaces. |
| Performance | 8/10 | No unbounded production loops in core paths reviewed; all Phase B-E contracts build below 24KB. |
| Security | 7/10 | OZ primitives, EIP-712, roles, pause paths, SafeERC20, and `Math.mulDiv` are present. Funding lifecycle and signed-order fee binding need work before audit-ready production claims. |
| AI verification | 8/10 | Claims were checked by reading the diff, grepping red flags, running tests/builds, and live Arc readiness verification. No code change was made during this analysis beyond this report. |

## Findings

### HIGH - Funding can be avoided by closing before explicit settlement

`FxFundingEngine.settleFunding()` is permissionless but optional, and it computes funding from the current clearinghouse position. If a trader closes first, the funding engine sees `p.sizeE18 == 0`, updates the trader index to latest, and returns zero. The clearinghouse open/decrease/liquidation flows do not call or require funding settlement before mutating the position, and margin withdrawals only check free margin, not pending funding debt.

Evidence:

- `contracts/src/perp/FxFundingEngine.sol:106` calls `pokeFundingRate()` and then reads `CLEARINGHOUSE.position(marketId, trader)`.
- `contracts/src/perp/FxFundingEngine.sol:111` updates `traderFundingIndex` before returning zero at `contracts/src/perp/FxFundingEngine.sol:112` when the position is already closed.
- `contracts/src/perp/FxPerpClearinghouse.sol:201` to `contracts/src/perp/FxPerpClearinghouse.sol:237` applies increases without funding settlement.
- `contracts/src/perp/FxPerpClearinghouse.sol:264` to `contracts/src/perp/FxPerpClearinghouse.sol:306` applies decreases without funding settlement.
- `contracts/src/perp/FxMarginAccount.sol:76` to `contracts/src/perp/FxMarginAccount.sol:87` allows withdrawal against free margin without checking unsettled funding.

Impact:

If funding is intended to be economically binding, a trader can avoid paying accrued funding by closing before `settleFunding()` is called. This is acceptable only if Phase B-E testnet treats funding as a manually-poked telemetry/prototype feature. It is not audit-ready as production funding.

Recommended next step:

Couple funding settlement into every position lifecycle path before size changes and before margin withdrawals, or store funding debt independently so closing cannot erase it. Add tests proving a long-heavy trader cannot evade funding by close-then-withdraw.

### MEDIUM - Signed orders do not bind a trader-side max fee or config version

`FxOrderSettlement.settleMatch()` validates signatures, nonce use, deadline, reduce-only, and limit price, then calls the clearinghouse with `type(uint256).max` for `maxFee`. The actual fee comes from the current market config at execution time.

Evidence:

- `contracts/src/perp/FxOrderSettlement.sol:70` to `contracts/src/perp/FxOrderSettlement.sol:108` settles a matched signed order.
- `contracts/src/perp/FxOrderSettlement.sol:104` and `contracts/src/perp/FxOrderSettlement.sol:105` pass `type(uint256).max` into clearinghouse fills.
- `contracts/src/perp/FxPerpClearinghouse.sol:213` to `contracts/src/perp/FxPerpClearinghouse.sol:217` computes fees from the current market config and only checks the supplied `maxFee`.

Impact:

Admin-controlled market config is capped by validation, but the trader's signed intent does not include a maximum fee, fee bps, or config digest. This leaves order execution dependent on mutable config rather than strictly on signed trader constraints.

Recommended next step:

Add `maxFee` or `maxFeeBps` to the signed order type, or bind orders to a config digest/version that includes fee parameters. Add a test that a signed order reverts if execution would exceed the trader-bound fee.

### MEDIUM - Invariant coverage is too narrow for an audit-ready perp stack

The invariant handler exercises long opens, long closes, and oracle price movement. It does not fuzz short-side lifecycle, funding settlement, liquidations, signed order settlement, nonce replay, partial fills, or withdraw interactions.

Evidence:

- `contracts/test/perp/FxPerpStackInvariant.t.sol:50` to `contracts/test/perp/FxPerpStackInvariant.t.sol:69` defines only `openLong`, `closeLong`, and `movePrice`.
- `contracts/test/perp/FxPerpStackInvariant.t.sol:132` to `contracts/test/perp/FxPerpStackInvariant.t.sol:139` checks cash backing and OI caps only.

Impact:

The current invariants are useful but do not yet defend the highest-risk Phase B-E surfaces: shorts, funding, liquidation, signed-order replay/fill, and margin withdrawal interactions. This is a coverage blocker for "audit-ready" labeling, though not a blocker for the current testnet smoke.

Recommended next step:

Expand the invariant handler to include short opens/closes, random funding pokes/settlements, liquidation attempts, signed order fills with nonce tracking, and margin withdrawals. Add invariants for no funding debt evasion, no nonce replay, cash backing, OI caps, and liquidation cleanup.

### LOW - Operator smoke fetches Pyth without timeout and validates response shape lightly

The live trading smoke fetches Hermes update data with bare `fetch()` and casts the JSON response to the expected shape before only checking that `binary.data` has at least one item.

Evidence:

- `packages/sdk/scripts/perp-arc-trading-smoke.ts:307` to `packages/sdk/scripts/perp-arc-trading-smoke.ts:315`

Impact:

This is an operator-script robustness issue, not a production contract issue. A hung or malformed Hermes response can stall the smoke or push an invalid update string toward the transaction path.

Recommended next step:

Use `AbortController` with a short timeout and validate every returned update as `0x`-prefixed hex before using it.

## Checks Passed

- OZ primitives are present on the reviewed perps contracts: `AccessControl`, `Pausable`, `ReentrancyGuard`, `SafeERC20`, OZ `EIP712`, `SignatureChecker`, and `Math.mulDiv`.
- Production perps contracts use custom errors rather than `require` strings in the reviewed delta.
- No production raw ERC20 `transfer` / `transferFrom`, `delegatecall`, or `tx.origin` usage was found in the reviewed perps delta.
- `FxPerpMath` NatSpec cites Synthetix v3 and GMX Synthetics references and routes multiply/divide through OZ `Math.mulDiv`.
- The Arc config verifier checks chain ID, code presence, contract pointers, admin/keeper roles, market config, funding config, liquidation config, and minimum protocol liquidity.
- The manifest exporter emits deployed addresses, balances, role booleans, market parameters, OI readbacks, funding parameters, and liquidation parameters.
- The SDK manifest loader validates chain ID, addresses, hex market IDs, booleans, safe integers, bigint fields, role readiness, market/funding readiness, protocol liquidity, and cash backing.
- Contract sizes are below 24KB:
  - `FxFundingEngine`: 5,677 bytes
  - `FxHealthChecker`: 3,144 bytes
  - `FxLiquidationEngine`: 3,569 bytes
  - `FxMarginAccount`: 4,646 bytes
  - `FxOrderSettlement`: 6,897 bytes
  - `FxPerpClearinghouse`: 9,163 bytes
- No deployment or broadcast was performed during this Gateman pass.

## Verification Commands Run

```bash
forge test --root contracts --offline --match-path 'test/perp/*.t.sol' -vv
cd packages/sdk && bun run typecheck && bun test
forge build --root contracts --offline --sizes
bun run perps:arc:config:verify
cd packages/sdk && bun run build
cd packages/sdk && bun build scripts/perp-arc-trading-smoke.ts --target bun --outdir /tmp/fx-perp-smoke-build
```

Observed results:

- `forge test --root contracts --offline --match-path 'test/perp/*.t.sol' -vv`: passed, 12 tests.
- Perp fuzz/invariant runs executed at Foundry's configured 256-run depth for the fuzz and invariant tests in the perps suite.
- `packages/sdk` typecheck and tests passed: 38 tests, 0 failures.
- `forge build --root contracts --offline --sizes`: passed with existing warnings; Phase B-E contracts are below 24KB.
- `bun run perps:arc:config:verify`: passed against Arc testnet. Readbacks included chain ID `5042002`, `protocolLiquidity = 101200327`, and margin USDC balance `102400000`.
- SDK build passed.
- Smoke script bundled successfully without executing transactions.

## Checks Failed

- Funding lifecycle is not yet settlement-coupled to clearinghouse mutations or margin withdrawals.
- Signed orders do not yet bind max fee or config version.
- Invariants do not yet cover shorts, funding, liquidation, signed-order replay/fill paths, or margin withdrawal interactions.
- Operator smoke does not yet enforce a Hermes fetch timeout or full runtime validation of returned update hex strings.

## Recommended Next Steps

1. Patch funding lifecycle coupling before claiming Phase B-E production funding is audit-ready.
2. Add trader-bound fee protection to the EIP-712 signed order type before relying on order settlement for user-facing matching.
3. Expand invariants around funding, liquidation, shorts, signed orders, replay, partial fills, and withdrawals.
4. Harden the Hermes fetch path in the live trading smoke.
5. Re-run `/gateman-analysis` after those fixes and record a follow-up report.

## Risk Level

**MEDIUM for the current testnet PR. HIGH if this is described as audit-ready production funding/order settlement.**

The stack is coherent enough for continued Arc testnet iteration, manifest-driven keeper/SDK integration, and live smoke work. It is not yet ready to be represented as complete audit-ready production perps because funding settlement is economically bypassable and signed orders do not bind all user-cost parameters.

## Sign-off

**Safe to ship:** `YES_WITH_FOLLOWUPS` for testnet continuation.  
**Safe to call audit-ready production perps:** `NO` until the HIGH funding lifecycle finding and MEDIUM signed-order fee-binding finding are resolved and covered by tests/invariants.
