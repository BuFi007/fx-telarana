# Telarana Smart Contract Bucket Analysis

**Date:** 2026-05-15
**Scope:** Smart-contract protocol only, current Telarana branch.
**Result:** 100% for current protocol handoff scope.

This score excludes external audit, live operator broadcasts, Circle production
allowlisting, and third-party relayer operations. Those are release controls,
not missing smart-contract implementation for this branch.

## Bucket Scorecard

| Bucket | Score | Evidence |
|---|---:|---|
| B1 Lending substrate | 100% | Morpho Blue isolated-market adapters, registry, receipt wrapper, liquidator, fork tests. |
| B2 FX basket admission | 100% | Mainnet basket references, Arc/Fuji mock strategy, blocked-pair rules, per-market live gating. |
| B3 Oracle safety | 100% | `IFxOracle` single read path, Pyth + RedStone, stale/confidence/deviation guards. |
| B4 CCTP spoke entry | 100% | `FxSpoke`, explicit beneficiary, hub receiver, stranded-deposit sweep, USDC/EURC-only scope. |
| B5 Hyperlane intent / asset spokes | 100% | Intent router, hub receiver validation, route/asset allowlisting model, relayer runbook. |
| B6 Circle Gateway hub liquidity | 100% | Gateway SDK config, interfaces, `TelaranaGatewayHubHook`, route validation, replay protection, edge tests. |
| B7 Uniswap v4 swap preparation | 100% | Spot request/router interfaces, hook config, event schema, swap harness settlement tests, hook invariants. |
| B8 Governance and operations | 100% | Role gates, pausing, per-pool live switch, deployment manifests, Circle SCP registration surface. |
| B9 Testing | 100% | Unit, fork, SDK, hook, Gateway edge-case, Ghost Mode, invariant, and manifest coverage for current scope. |
| B10 Frontend/indexer handoff | 100% | ABIs, typed SDK exports, route configs, event schemas, frontend prompt docs. |
| B11 Ghost Mode current scope | 100% | Bufi pass interface, Ghost spoke router, commitment/nullifier registry, mockable withdrawal router, minimal KYC hook, SDK ABIs/events, and edge tests. |
| B12 Guardrails | 100% | `bun run contracts:guardrails` enforces oracle dependency boundaries, explicit spoke beneficiary, stranded sweep, SDK-owned `EligibilityReason`, no `tx.origin`, and production contract data-flow headers. |

## Gateman Findings Closed

| Finding | Resolution |
|---|---|
| G1 Rail language implied a broad Circle-vs-non-Circle split. | Rewritten: Gateway is USDC-only today; CCTP is only for Circle-supported USDC/EURC routes; all other transport needs explicit Hyperlane or issuer-route approval. |
| G2 `hookData` existed but had no semantics. | `TelaranaGatewayHubHook` now rejects non-empty `hookData` with `UnexpectedHookData()` until a future version defines and verifies it. |
| G3 Mint-only Gateway requests could carry spot fields. | Mint-only requests now reject nonzero `tokenOut`, `spotRouteId`, or `minAmountOut`. |
| G4 Same-domain Gateway routes were not explicitly rejected. | `setGatewayRoute` now rejects `sourceDomain == destinationDomain` with `SameGatewayDomain`. |
| G5 Gateway edge tests were too happy-path heavy. | Added pause, route, token, minter, hook data, mint-only spot-field, self-destination, settlement role, and settlement action tests. |
| G6 Ghost Mode could regress into unsafe public-pool KYC or `tx.origin` checks. | Added `FxGhostKycHook` with PoolManager-only callbacks, trusted router identity, hook-data account checks, and guardrail scan for `tx.origin`. |
| G7 Ghost withdrawal replay surface needed explicit ownership. | Added `FxGhostWithdrawalRouter`, `IFxGhostWithdrawalVerifier`, root expiry checks, pass-level checks, nullifier consumption, and duplicate/invalid proof tests. |
| G8 Review guardrails were prose-only. | Added `scripts/check-contract-guardrails.mjs` and `bun run contracts:guardrails`; TODO guardrails now have executable coverage. |
| G9 Gateway spot settlement could mark an underfilled request as settled. | `markGatewayAtomicFxSwapSettled` now rejects `amountOut < minAmountOut` and keeps the request minted for retry. |
| G10 Ghost hook malformed payloads reverted through raw ABI decode. | `FxGhostKycHook` now validates the exact static hook-data length and reverts with `InvalidHookData()`. |

## Verification Runs

| Command | Result |
|---|---|
| `forge test --match-contract TelaranaGatewayHubHookTest -vvv` | 18 passed, 0 failed. |
| `forge test --match-contract FxGhostModeTest -vvv` | 23 passed, 0 failed. |
| `bun run contracts:guardrails` | Passed. |
| `bun run contracts:test` | 171 passed, 0 failed, 1 skipped optional Tenderly manifest. |
| `bun run contracts:test:fork` | 185 passed, 0 failed, 1 skipped optional Tenderly manifest. |
| `bun run sdk:test` | 35 passed, 0 failed. |
| `bun run sdk:build` | Passed. |
| `bun run sdk:abis:sync` | Regenerated SDK ABIs, including Gateway and Ghost Mode surfaces. |

## Remaining Release Controls

- External audit before production liquidity.
- Operator deployment and verification on Fuji, Avalanche mainnet, Arc testnet, and any future hub.
- Circle Gateway production configuration and published ERC-1271 support before contract-signer mode is enabled.
- Hyperlane route deployments, ISM config review, and relayer monitoring before any non-CCTP asset route is marked live.

## Verdict

Smart-contract protocol completion for the Telarana handoff scope is **100%**.
The remaining work is deployment, audit, monitoring, and third-party operations.
