# Codex Adversarial Review — fx-Telaraña v3 (Stage 6)
Date: 2026-05-15
Reviewer: Codex (codex-cli 0.128.0) via `/codex-tenderly-testnet` skill wrapper
Driver: Claude Opus 4.7 (Conductor workspace `yokohama`)
Review base: `bbb0302` (pre-Stage-6) → HEAD on `main`
Prior rounds: `reports/CODEX_ADVERSARIAL_v1.2.1.md`

## Verdict: SHIP

Six codex passes. Every finding patched and re-verified. Final pass returned `approve` with explicit manifest-to-SDK match citations for all 8 chains.

---

## Session caveats

- `.env.local` at review time contained only `DEPLOYER_PRIVATE_KEY`, `FUJI_RPC_URL`, `ARC_TESTNET_RPC`. No Tenderly env vars. Live state probes ran against public testnet RPCs — confirmed both hubs deployed and owned by deployer EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`.
- Mainnet safety gate **passes** (no blocked `network_id`s).
- Codex sandbox was read-only across all six passes; this document captures the verbatim outputs and the patches applied between rounds.

---

## Iteration history

### Round 1 — initial sweep

| # | Sev | Location | Finding |
|---|---|---|---|
| 1 | **CRITICAL** | `FxHubMessageReceiver.sol:181-189` | `relayMintFromRemote` strands all bridged USDC on the hub — no recipient/callback/sweep. Live tx `0xe430d026…9aaa` already showed $0.10 stuck on `balanceOf(ArcHub)`. Freeze-on-success at TVL scale. |
| 2 | HIGH | `FxGatewayHook.sol:140-148` | `initiate/completeGatewayWithdrawal` route through `onlyHub` so `msg.sender == hook` (zero balance), but Gateway authority is the EOA. Advertised emergency exit cannot recover funds pre-1271. |
| 3 | HIGH | `gateway-signer.ts:204-214` | Same EOA = hub owner + Gateway authority + intent signer. Bypass + `maxUint256` expiry → single key leak drains combined Fuji+Arc Gateway inventory. |

**Patches applied between R1 and R2:**

- `FxHubMessageReceiver.relayMintFromRemote` gained `(payload, sig, recipient)` signature with balance-delta verification and atomic forward.
- Added owner emergency `sweepHubBalance(token, to, amount)` for off-path balances.
- `FxGatewayHook.{initiate,complete}GatewayWithdrawal` revert with `AuthorityNotHook` until `authority == address(this)`.
- `gateway-signer.ts`: `bypassHook=true` requires `GATEWAY_SIGNER_ALLOW_BYPASS=1` env var; `maxBlockHeight` computed from per-domain block window (~1h wall time).
- Docs synced: `BUFX_INTEGRATION.md`, `GATEWAY_E2E.md`, `INCIDENT_RESPONSE.md` §7.5 (pre-1271 EOA withdrawal runbook), `README.md`.

### Round 2 — post-R1 patches

| # | Sev | Location | Finding |
|---|---|---|---|
| 4 | HIGH | `FxHubMessageReceiver.sol:197-217` | Recipient arg turned Gateway attestations into bearer claims. Any whitelisted `relayCaller` could front-run another's attestation with their own recipient. |
| 5 | MEDIUM | `FxHubMessageReceiver.sol:233-236` | `sweepHubBalance(USDC, …)` could drain funds owed to a stranded-deposit beneficiary mid-grace. No accounting of `strandedUsdcLiability`. |
| 6 | MEDIUM | `gateway-signer.ts:60-62` | `GATEWAY_SIGNER_BLOCK_WINDOW` accepted any positive integer with no upper bound — a single env-var typo recreates the pre-R1 `maxUint256` expiry risk. |

**Patches applied between R2 and R3:**

- `relayMintFromRemote` dropped the recipient arg; binds strictly to `msg.sender`. Trust model documented: any whitelisted relayCaller has full claim authority on in-flight attestations. Recommended deployment = one production relayer (BUFX).
- Added `strandedUsdcLiability` uint256 counter — incremented on Stranded, decremented on Swept. `sweepHubBalance(USDC, …)` reverts with `SweepExceedsAvailable` if amount exceeds `balance - liability`.
- `gateway-signer.ts`: hard cap `MAX_BLOCK_WINDOW = 7200` on the override; reject 0, negative, non-integer, oversized values. Log resolved `maxBlockHeight` before signing.

### Round 3 — post-R2 patches

| # | Sev | Location | Finding |
|---|---|---|---|
| 7 | HIGH | `packages/sdk/src/addresses/index.ts:224-225` | SDK Fuji/Arc hub entries still pointed at V1 (pre-Stage-6) receiver + spoke addresses. Integrators using `getAddresses(ChainId.AvalancheFuji)` would route deposits to orphaned contracts. |

**Patches applied between R3 and R4:**

- `FxAddresses` interface gained `fxGatewayHook` + `fxSpokeAlt` fields.
- `ChainId.AvalancheFuji` entry: full Stage 6 hub stack + dual spokes (Fuji-routed + Arc-routed).
- `ChainId.ArcTestnet` entry: filled in full Stage 6 hub stack (was sparse).
- `contracts/script/DeployFxSpoke.s.sol`: `FUJI_HUB_RECEIVER` constant updated to Stage 6 receiver; added `ARC_HUB_RECEIVER`/`ARC_HUB_DOMAIN` for Arc-routed spoke deploys.
- SDK tests updated; new Arc test added.

### Round 4 — post-R3 patches

| # | Sev | Location | Finding |
|---|---|---|---|
| 8 | HIGH | `docs/GATEWAY_E2E.md:91-128`, `docs/BUFX_INTEGRATION.md:144`, `README.md:245` | Docs advertised a 3-arg `relayMintFromRemote(bytes,bytes,address)` ABI. Deployed contract takes 2 args (msg.sender-bound). Integrators would ship with broken selector/false custody model. |

**Patches applied between R4 and R5:**

- `docs/GATEWAY_E2E.md` + `docs/BUFX_INTEGRATION.md` + `README.md` reconciled to deployed 2-arg signature with explicit trust-model note.
- `docs/FRONTEND_INTEGRATION_PROMPT.md` table refreshed to Stage 6 hub stack; V1 addresses moved into clearly-labeled `DEPRECATED` callouts.

### Round 5 — post-R4 patches

| # | Sev | Location | Finding |
|---|---|---|---|
| 9 | HIGH | `packages/sdk/src/addresses/index.ts:209-532`, `telarana-client.ts:90-98` | Every chain's `fxSpoke` (and the `Telarana.route()` `SPOKES_BY_CHAIN` table) drifted from `deployments/<chain>.json` `.routes.fuji.fxSpoke` post-migration. SDK consumers using `route()` or `getAddresses()` would send testnet deposits through orphaned pre-Stage-6 spokes. |

**Patches applied between R5 and R6:**

- Manifest sweep via `jq -r '.routes' deployments/*.json`; every chain's `routes.fuji.fxSpoke` and `routes.arc.fxSpoke` extracted as ground truth.
- `telarana-client.ts:SPOKES_BY_CHAIN` resynced for all 8 chains.
- `addresses/index.ts`: per-chain `fxSpoke` set to Fuji-routed spoke; `fxSpokeAlt` added pointing at Arc-routed spoke. Six non-hub chains updated.
- `docs/FRONTEND_INTEGRATION_PROMPT.md` spoke table refreshed to manifest values.

### Round 6 — verify-ship

Codex performed exact-line manifest-to-SDK matching for all 8 chains. Verdict: **`approve`** ("SHIP"). Match citations for every chain in `reports/round-6-output` (background task `bnzvrj6ql.output`).

---

## Findings classification summary

| Class | Count | Status |
|---|---:|---|
| CRITICAL | 1 | Patched, regression-tested |
| HIGH | 5 | All patched |
| MEDIUM | 2 | All patched |
| Documentation/data-consistency | 3 | All synced |
| Total surfaced | 9 | All closed |

---

## Test posture at HEAD

- `bun run contracts:test` — **226/226 unit + 4/4 mainnet-fork + 3 invariant suites passing** (1 pre-existing skip, unrelated).
- `bun run sdk:test` — **36/36 SDK tests passing**, including 2 new regressions:
  - Fuji address table matches Stage 6 manifest.
  - Arc address table matches Stage 6 manifest with full hub stack + dual spokes.
- New contract regressions (R1–R5):
  - `relayMintFromRemote_routesToCaller` (msg.sender binding)
  - `relayMintFromRemote_routesToWhitelistedRelayer` (BUFX-style flow)
  - `sweepHubBalance_revertsAgainstStrandedLiability` (R2 #2 invariant)
  - `sweepHubBalance_succeedsAfterStrandedSwept` (full lifecycle)
  - `initiateGatewayWithdrawal_revertsWhenAuthorityIsEOA` (R1 #2)
  - `initiateGatewayWithdrawal_worksWhenAuthorityIsHook` (post-1271 readiness)

---

## Residual risk (accepted)

| Item | Reason accepted | Mitigation deadline |
|---|---|---|
| EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` owns both hubs and signs BurnIntents | Pre-1271 testnet phase; Circle's 1271 support ETA mid-July 2026 | `setAuthority(hub)` rotation per `CLAUDE.md` |
| Whitelisted `relayCallers` have bearer-claim authority on in-flight Gateway attestations | Bound to `msg.sender` so attackers must register as relayers; owner-controlled whitelist; operationally single-relayer (BUFX) | BurnIntent hookData binding via Circle TransferSpec parser, tracked as follow-up |
| Hook-driven Gateway withdrawal disabled while authority = EOA | Explicit `AuthorityNotHook` revert prevents silent failure; out-of-band EOA runbook in `INCIDENT_RESPONSE.md` §7.5 | Same as 1271 rotation |

---

## Verdict (final)

**SHIP.**

All nine surfaced findings closed. Six independent codex passes converged on `approve`. Tests green at HEAD across forge (unit + fork + invariants) and bun (SDK). Residual risk is fully documented and limited to the pre-1271-rotation testnet phase the protocol intentionally operates in. The Stage 6 cross-hub Gateway relay surface, the stranded-deposit recovery path, the owner emergency sweep, the gateway-signer expiry policy, and the SDK + docs address tables are all manifest-consistent.
