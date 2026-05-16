# Handoff — fx-Telaraña to 100% Audit-Ready Testnet State

**Branch:** `tcxcx/pasted-text-task` (pushed to `origin`, **not merged to main**)
**Last commits:**
- `36afd4a feat(phase-2.7): DODO PMM curve + Bunni-style fee sleeve`
- `39f72b4 fix(codex-v3): patch 9 adversarial findings across 6 review rounds`

**Open PR target:** `https://github.com/BuFi007/fx-telarana/pull/new/tcxcx/pasted-text-task`

Do not merge this branch to `main` until P0s below are closed — `FxSwapHook` currently exceeds the EIP-170 deployed-bytecode limit and is non-deployable.

---

## Where we are

12 adversarial-review rounds against Phase 2.7 closed all curve / accounting / sandwich findings. Test posture: **261/262** (1 pre-existing unrelated skip). 3 invariants × 25k swap calls each, zero reverts.

Codex round 12 surfaced two new findings that the next session must close before testnet deploy and SDK integration:

### P0 — must close before any testnet redeploy or merge to `main`

**1. EIP-170 bytecode overflow (CRITICAL)**
- `contracts/src/hub/FxSwapHook.sol` deployed bytecode = **28,147 bytes**.
- EIP-170 limit = **24,576 bytes**.
- Affects ALL EVM chains: Base Sepolia, Arc Testnet, Avalanche Fuji, Ethereum Sepolia, etc.
- Root cause: vendored DODO PMM math (`PMMPricing`, `Math`, `DecimalMath`) inlines into the hook because all functions are `internal`.
- **Fix strategies (pick one or stack):**
  - Convert vendored libraries from `internal` to `external` and deploy them once as standalone libraries; the hook links via `using ... for ...` plus library deployment. Lops ~3-5kb.
  - Split the protocol-fee accountant (`protocolFee0/1`, `setProtocolFeeBps`, `setTreasury`, `claimProtocolFees`, `tradableAssets`) into a separate companion contract called from the hook. Lops ~2-4kb.
  - Move LP share + Morpho rehypothecation paths into a separate vault contract; FxSwapHook becomes a pure swap-quote + fee accrual contract that talks to the vault. Cleanest architectural split.
- **Required after fix:** add a CI size-check that reads `out/FxSwapHook.sol/FxSwapHook.json` and asserts `deployedBytecode.object.length / 2 <= 24576`.

**2. Stale SDK ABI (HIGH)**
- `packages/sdk/src/abis/FxSwapHook.ts` predates Phase 2.7.
- Missing: `sync(uint256,uint256,uint256)`, `tradableAssets(address)`, `setProtocolFeeBps`, `setTreasury`, `claimProtocolFees`, `protocolFee0/1`, `baseTargetE18`, `quoteTargetE18`, `treasury`, the new error selectors.
- Fix: regen from the rebuilt artifact (`bun run sdk:abis` or equivalent). Add SDK test asserting the new function fragments exist.
- Don't touch the deployed-address tables — those are correct as of Stage 6.

### P1 — required for audit-ready, do after P0

**3. Tenderly Virtual TestNet end-to-end** of the full Phase 2.7 swap flow (spoke deposit → Fuji hub → Gateway → Arc → FxSwapHook → DODO PMM swap → afterSwap rebalance → protocol fee claim). Skill: `/tenderly-testnet`. Vnet must be testnet-only (skill refuses mainnet `network_id` by design).

**4. `/codex-adversarial-tenderly-auditor` pass** against the live testnet state. This runs Codex with real chain context — vnet block height, primed snapshot, transactions-RPC dry-run — not just the diff. Catches deploy-time issues the static review can't see.

**5. `/gateman-analysis`** post-implementation audit on the hook + fee sleeve once P0 done. Encodes Robert Gateman's "Assume nothing, question everything, worship no one, applaud humility" — distinct from codex's adversarial framing.

**6. `/v4-security-foundations` checklist** — full Uniswap V4 hook permission-bit audit. `getHookPermissions()` already returns the intended bits but should be re-validated against the V4 audited reference flag set.

**7. `/adversarial-uniswap-hooks`** — the canonical V4-hook attack checklist (BeforeSwapDelta arithmetic, hook flag mining, callback reentrancy via PoolManager). Mettal's skill from the v4 hook-of-the-week thread.

### P2 — frontend / integration prep

**8. `/v4-sdk-integration`** + `/viem-integration` once SDK ABI regen is done. Plumbs the new hook surface into a frontend-callable client.

**9. SDK `FxSwapHook` client wrappers** for the new admin/fee surface — `quoteExactInput`, `tradableAssets`, `protocolFee0/1`, `sync` (with off-chain expected-target computation helper).

**10. BUFX hub-side `relayToRemoteHub` shim** — flagged in `docs/BUFX_INTEGRATION.md` as a Stage 6 plumbing gap.

**11. Circle SCP registration** for Arc/Fuji Stage 6 contracts (Base Sepolia is already done — see `bun run sdk:circle:register deployments/arc-testnet.json`).

**12. Webhook URL** for Pasillo/Trigger.dev sink — set `WEBHOOK_URL=https://...` env in the SCP register script.

---

## Contract inventory (as of this commit)

### Vendored (Apache-2.0, audited references)

| Path | Source | Purpose |
|---|---|---|
| `contracts/lib/dodo-pmm-08/PMMPricing.sol` | Abracadabra@46ad8622, DODO 2020 | PMM sellBase/sellQuote + adjustedTarget |
| `contracts/lib/dodo-pmm-08/Math.sol` | same | GeneralIntegrate + quadratic solvers |
| `contracts/lib/dodo-pmm-08/DecimalMath.sol` | same | 1e18 fixed-point helpers |

### Hub-side (live on Fuji + Arc)

| Contract | Status | Notes |
|---|---|---|
| `FxHubMessageReceiver.sol` | shipped Stage 6 | CCTP V2 inbound + cross-hub relay (`relayMintFromRemote`, `relayToRemoteHub`), strandedUsdcLiability, sweepHubBalance |
| `FxGatewayHook.sol` | shipped Stage 6 | Gateway lock/mint, `AuthorityNotHook` gate until mid-July 2026 1271 rotation |
| `FxOracle.sol` | shipped | Sole price-read surface |
| `FxMarketRegistry.sol` | shipped | Morpho market params |
| `MorphoOracleAdapter.sol` | shipped | IFxOracle → Morpho IOracle bridge |
| **`FxSwapHook.sol`** | **NEW Phase 2.7, BLOCKED by EIP-170** | DODO PMM + fee sleeve + sync |

### Spokes (8 chains, routed to Fuji)

ETH Sepolia, OP Sepolia, Arbitrum Sepolia, Polygon Amoy, Unichain Sepolia, Worldchain Sepolia, Arc Testnet, Fuji-on-Fuji. Plus Arc-routed alts. Addresses pinned in `deployments/<chain>.json`.

### Tests (after this commit)

- `contracts/test/FxSwapHook.t.sol` — 39 unit tests
- `contracts/test/FxSwapHookInvariant.t.sol` — 3 invariants + 4 fee-sleeve integration tests
- `contracts/test/DodoPMMSmoke.t.sol` — 5 vendored-library round-trips
- Existing Stage 6 / Gateway / CCTP / fork tests untouched

---

## Skills the next session should pick up

```
P0 cleanup    →  /codex (consult)          ask for size-reduction architectural advice on FxSwapHook
              →  /upgrade-solidity-contracts  if external-library refactor needs storage-layout review

After P0      →  /v4-security-foundations
              →  /adversarial-uniswap-hooks   (Mettal's hook attack list)
              →  /v4-hook-generator           sanity-check permission bits / hook flags
              →  /tenderly-testnet            spin testnet vnet for end-to-end run
              →  /codex-adversarial-tenderly-auditor    live-state codex pass
              →  /gateman-analysis            post-implementation audit

For SDK / FE  →  /v4-sdk-integration
              →  /viem-integration
              →  /codex:adversarial-review    on the SDK package once regenerated
```

`/loop` the codex+gateman+tenderly chain until SHIP across all three. Same pattern that took Phase 2.7 from drafted → 12 rounds → 261/262.

---

## How to reproduce current state

```bash
git checkout tcxcx/pasted-text-task

# Solidity unit + invariant + fee-sleeve integration
bun run contracts:test                       # 261/262 pass

# Solidity + ETH mainnet fork (Morpho live)
bun run contracts:test:fork                  # 4/4 fork pass

# SDK
bun run sdk:test                             # 36/36 pre-Phase-2.7; will need regen after P0

# Build, then check bytecode size
forge build --root contracts
jq -r '.deployedBytecode.object | length / 2' contracts/out/FxSwapHook.sol/FxSwapHook.json
# Target: ≤ 24576. Currently: ~28147. THIS IS THE SHIP BLOCKER.
```

---

## Hard rules carried forward

From `CLAUDE.md` + this session's accumulated guidance:

1. **No novel math in production.** Vendor from an audited reference; never re-derive curves, solvers, or inverses inline. If the reference doesn't have what you need, ask before writing it.
2. **No push to remote unless explicitly authorized.** Branch-level pushes are fine; main is governed.
3. **Testnet only** for Tenderly / deploy work. Skill enforces this; do not bypass.
4. **Don't touch the gateway-signer signing key** beyond demonstrating exploits — EOA holds real testnet USDC.
5. **`IFxOracle` is the only price-read surface.** No direct Pyth/RedStone SDK calls anywhere.
6. **Solidity 0.8.26**, `evm_version = "cancun"` (Arc Prague is a superset).

---

## Residual risks (documented, accepted for testnet phase)

Carried from `reports/CODEX_ADVERSARIAL_v3.md` §"Residual risk":

| Item | Reason accepted | Resolution path |
|---|---|---|
| EOA `0x0646FFe1…` owns both hubs and signs BurnIntents | Pre-1271 testnet phase; Circle ETA mid-July 2026 | `setAuthority(hub)` rotation per `CLAUDE.md` |
| Whitelisted `relayCallers` have bearer-claim authority on in-flight Gateway attestations | Bound to `msg.sender`; owner-controlled whitelist; deployed single-relayer (BUFX) | BurnIntent hookData binding via TransferSpec parser — follow-up |
| Hook-driven Gateway withdrawal disabled while authority = EOA | `AuthorityNotHook` revert prevents silent failure; runbook in `INCIDENT_RESPONSE.md` §7.5 | Same as 1271 rotation |

**New Phase 2.7 accepted trade-off:** Donations and Morpho yield are NOT auto-absorbed into PMM equilibrium. The first trade post-donation arbs the imbalance back to traders (DODO V2 reference behavior; case 2.3 in `sellBaseToken`). To capture yield into LP equity, owner calls `sync(expectedB, expectedQ, maxDriftBps)` off-cycle. Document this in the LP integrator guide.

---

## Verdict

**Almost there. P0 (EIP-170) is the only hard blocker; everything else is finishing work for audit-readiness.**
