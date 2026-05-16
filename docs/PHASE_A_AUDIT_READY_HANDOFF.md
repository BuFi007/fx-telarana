# Phase A — Audit-Ready Testnet Handoff

Self-contained brief for the next session to take Phase A (spot-FX layer)
from "v0.1 live + 3 Codex blockers closed" to **100% audit-ready testnet
state**, including the Phase A v1 wrap-as-Uniswap-v4-hook.

The previous session merged BUFX PR #3 + Telarana PR #14 (Codex CRITICAL
+ 2 HIGH closed). This brief picks up there.

## Non-negotiable rules (carried over)

1. **No novel math in production.** Every formula, accumulator, curve,
   solver — vendor from an audited reference (Perennial v2, GMX
   Synthetics, Synthetix v3, Curve, Morpho, Bunni v2, OZ Math, OZ
   `BaseCustomCurve`). Acceptable: thin wrappers + plumbing. Not
   acceptable: rederiving an inverse, hand-rolling a Newton solver,
   "temporary" math placeholders.
2. **OZ standard primitives only**: AccessControl over hand-rolled
   owners, ReentrancyGuard over manual locks, SafeERC20 over raw
   transfer, Pausable for incident response, `Math.mulDiv` for any
   `a*b/c`, OZ EIP712 for typed data. Custom errors, not require strings.
   CEI ordering.
3. **Path A preserved**: BUFX request layer stays passive. Keeper EOA
   (`0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`) drives all protocol
   mutations off-chain.
4. **Don't deploy without explicit go-ahead from the user.** Each
   contract change ships with unit + invariant + fuzz tests + a deploy
   script + runbook before broadcasting on testnet.
5. **Receipt-canonical** — never re-introduce keeper-supplied context
   to any execution surface. The TGH receipt is the single source of
   truth for spot-fx flows. Same pattern applies to perp engine when
   built.

## Live testnet state — as of 2026-05-16

### Telarana — Arc (chainId 5042002) — TRADING-EXECUTION HUB

| Contract | Address | Role | Status |
|---|---|---|---|
| `FxHubMessageReceiver` V2 | `0x44B50E93eCC7775aF99bcd04c30e1A00da80F63C` | Cross-hub relay surface | LIVE |
| `FxGatewayHook` V2 | `0x2931C50745334d6DFf9eC4E3106fE05b49717DF1` | Circle Gateway adapter (mint-to-hub) | LIVE |
| `TelaranaGatewayHubHook` (TGH) | `0x74E894aFf25c89d707873347cd2554d30E0541fa` | Spot-FX-aware destination wrapper | LIVE |
| **`FxSpotExecutor` v0.1** | **`0x37ccDa89628Fd3Cc1f8ef5e45D8725c4e3a59542`** | **Oracle-anchored spot swap pool (current)** | **LIVE** |
| `FxSpotExecutor` v0 | `0x23AB8992585Ff2E40833198f661374a070398876` | Deprecated; EXECUTOR_ROLE revoked from TGH | DEPRECATED |
| `FxOracle` | `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865` | Pyth + optional RedStone | LIVE |
| `FxMarketRegistry` | `0x813232259c9b922e7571F15220617C80581f1464` | Morpho-Blue lend/borrow surface | LIVE |
| `FxLiquidator` | `0xa50f7D4D4a1A0D3CF418515973545b80E037B379` | Morpho liquidator (NOT perps) | LIVE |
| `FxReceiptUSDC` (ERC-4626) | `0xdd22365Bba7330BE537c9BC26da9b1b4Db9aC431` | USDC vault | LIVE |
| `FxReceiptEURC` (ERC-4626) | `0xF829f57Db8530fa93FCD6e13b00193cbe8cE1493` | EURC vault | LIVE |
| `MorphoBlue` | `0x3c9b95C6E7B23f094f066733E7797C8680760830` | Self-deployed Morpho on Arc | LIVE |
| `USDC` (native gas) | `0x3600000000000000000000000000000000000000` | 6-dec ERC20 | LIVE (Circle issuer) |
| `EURC` | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | 6-dec ERC20 | LIVE (Circle issuer) |
| `TestnetFiatToken` tJPYC | `0xB176f6E0c8ecc2be208F72Ad34c54e5F10F1882a` | 6-dec, MINTER_ROLE-gated | LIVE |
| `TestnetFiatToken` tMXNB | `0xe8F76f90553F50E76731afbeF1ac83a9152fFBEb` | 6-dec, MINTER_ROLE-gated | LIVE |
| `TestnetFiatToken` tCHFC | `0x249DBFd4ac17247Cf10098F6C3937F90570b5750` | 6-dec, MINTER_ROLE-gated | LIVE |
| Old `MockERC20` JPYC | `0x499347b5448660Ab17Cd4E32fA61c35D2ada7A5b` | Public-mint mock — SUPERSEDED by tJPYC | DEPRECATED |
| Old `MockERC20` MXNB | `0x80e65233d83547dE3d78396f1Fb0338728C5e42b` | Public-mint mock — SUPERSEDED by tMXNB | DEPRECATED |
| Old `MockERC20` CHFC | `0x2EacaCDAEf6a7ec82C168aFbdDd1B0E7D7993E69` | Public-mint mock — SUPERSEDED by tCHFC | DEPRECATED |

### Telarana — Fuji (chainId 43113) — PRIMARY USER-DEPOSIT HUB

| Contract | Address | Role | Status |
|---|---|---|---|
| `FxHubMessageReceiver` V2 | `0x7eAdfD0c08dd6544f763285bBD31be14179d594B` | Primary user-deposit hub | LIVE |
| `FxGatewayHook` V2 | `0x7dA191bfB85D9F14069228cf618519BFb41f371E` | Gateway adapter | LIVE |
| `FxMarketRegistry` | `0x7ba745b979e027992ECFa51207666e3F5B46cF0a` | | LIVE |
| `FxOracle` | `0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b` | | LIVE |
| `USDC` | `0x5425890298aed601595a70AB815c96711a31Bc65` | Circle USDC on Fuji | LIVE |
| (additional contracts — see `deployments/hub-config-fuji.json`) | | | |

### BUFX — Fuji + Arc

| Contract | Address | Chain |
|---|---|---|
| `BuFxTelaranaRequestRouter` | `0x46cC11feD4F497C0C091b7bE5a1A21af133c26f1` | Fuji |
| `BuFxVenueRequestRouter` | `0x84EE03C52B89B01315C9572520192274b570D2c3` | Fuji |
| `BuFxFeeConfig` | `0xa589040434735710aEF173e31e421a2d0a20Dd17` | Fuji |
| `BuFxFeeCollector` | `0x1894C8c84F3a8DD1e17B237008a197feD2E299B6` | Fuji |
| `BuFxTelaranaRequestRouter` | `0xea11AfDc70eD0489346AC9d488C17155384B459c` | Arc |
| `BuFxVenueRequestRouter` | `0xa73208b62AF9a87fb5e2b694B27f510D70e17746` | Arc |
| `BuFxFeeConfig` | `0x746e727E3aa25050c24a80E27E3bAEd9Ec6DdF6C` | Arc |
| `BuFxFeeCollector` | `0x27DbdA42aDb904115cAdE37C949bBF670E0FF09d` | Arc |

### Live routeIds (BUFX + TGH agree)

| Direction | Action | tokenOut | routeId |
|---|---|---|---|
| Fuji → Arc | MINT_TO_HUB | USDC | `0xf78147c98547731be048740d9d9089e6258e5e712e0c66f7b9d9d57d6af3a968` |
| Arc → Fuji | MINT_TO_HUB | USDC | `0x1a255f6aaa29b7ffd589c882eda0ab42f2613bfe51f271b6a677b318321a1efb` |
| Fuji → Arc | SPOT_FX | EURC | `0x4b50d101784ab33ee4adc9ca42080b10cdd2b23d71004a34a9625f3554e97f19` |
| Fuji → Arc | SPOT_FX | JPYC (live = tJPYC) | `0xda73657812ef2aa4a59ca67e8d757ac98155cf6aac04e6c0a1723b6f2799a47b` |
| Fuji → Arc | SPOT_FX | MXNB (live = tMXNB) | `0x4e26b194dd0f03e769ec58a34bcd4bbbe88f27d2aa1c502eb50dc20d4569512c` |
| Fuji → Arc | SPOT_FX | CHFC (live = tCHFC) | `0x84d69f49ece767181be6ee9d8706e5007bc8dda02fed481bb21446760d3c3e4f` |

All 4 SPOT_FX TGH routes have `destinationHub = FxSpotExecutor v0.1`.

### Circle Gateway (deterministic, same on every testnet)

| Contract | Address |
|---|---|
| `GatewayWallet` | `0x0077777d7EBA4688BDeF3E311b846F25870A19B9` |
| `GatewayMinter` | `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B` |
| BurnIntent authority | `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` (deployer EOA; rotates to hub via EIP-1271 mid-2026) |

### Live smoke proofs (Phase A v0.1)

- 1 USDC → 0.860314 EURC delivered via patched executor: tx `0x47652c77216f0f75f4dce540187f62ea37a0d6d578603b9b39594f1d0050186c`
- Receipt-canonical signature proven on-chain: `executeSpotFx(bytes32 requestId)` (no context arg).
- All TestnetFiatToken contracts seeded 500.000000 each on v0.1; v0.1 EURC reserve 3.000000.

## What's already done — do NOT redo

- Stage 12 cross-hub USDC rail (Fuji ↔ Arc via Circle Gateway, BUFX request layer) — production-ready on testnet.
- Phase A v0 → v0.1 audit-fix patches (Codex CRITICAL + 2 HIGH closed). Live smoke proven.
- BUFX SDK: spot-fx routeIds, ABIs, smoke + trace scripts. Single-arg `executeSpotFx(bytes32)`.
- Codex handoff brief for phases B–E: `docs/CODEX_BRIEF_PHASES_B_TO_E.md` in Telarana main.

## Open items to reach 100% audit-ready testnet (this session's scope)

### Tier 1 — close before any v4 wrap or audit handoff

| # | Item | Rationale | Reference |
|---|---|---|---|
| T1 | Vendor reference repos as git submodules in `contracts/lib/` (perennial-v2, gmx-synthetics, synthetix-v3, morpho-blue, openzeppelin-uniswap-hooks, bunni-v2) | Codex MEDIUM finding: project rule "no novel math" can't be verified if references aren't present in-repo. The reference brief depends on them. | Codex audit memo, 2026-05-16 |
| T2 | Add foundry invariant + fuzz tests for FxSpotExecutor v0.1 | Audit firms expect ≥256-run fuzz on every math-heavy entry. Currently 24 unit tests + 0 fuzz/invariant. | OZ best-practice |
| T3 | Run `/codex-adversarial-tenderly-auditor` on the Fuji-side (TGH + relay) once Tenderly MCP reconnects | Tenderly indexes Fuji; the cross-hub rail is auditable today. Run after Tenderly auth restored. | `/codex-adversarial-tenderly-auditor` skill prereqs |
| T4 | Decimal-aware payout math in FxSpotExecutor v0.2 | Today's decimals guard rejects non-USDC-decimal tokens at allowlist. Audit-ready means: support 18-dec, 8-dec etc. via per-token decimals stored on enable + decimal-scaled mulDiv. Reference: Synthetix v3 `Decimal.scale` pattern. | Codex HIGH#2 v0.2 follow-up |
| T5 | Add receipt-parity for `sourceDepositor`, `sourceSigner`, `spotRouteId`, `metadataRef` either via TGH change or BUFX cross-message proof | Today the executor reads recipient/minAmountOut canonically. The other receipt fields are keeper-set at TGH.receiveGatewayMint time; an audit firm will ask "what binds these to the BUFX request?". Architecturally this needs a Hyperlane message proof from BUFX→TGH or a signed-intent flow. | Codex CRITICAL extended |

### Tier 2 — Phase A v1 v4-hook wrap

| # | Item | Reference |
|---|---|---|
| T6 | Build `FxSpotV4Hook` inheriting `BaseCustomCurve` (OZ) wrapping the v0.1 logic | `references/openzeppelin-uniswap-hooks/src/base/BaseCustomCurve.sol` |
| T7 | Permission bits + HookMiner deploy on Arc once Uniswap v4 PoolManager ships there | Skill: `/v4-hook-generator` |
| T8 | Pool initialization with USDC↔EURC, USDC↔tJPYC etc. — one pool per pair | Skill: `/v4-hook-generator` |
| T9 | `/adversarial-uniswap-hooks` audit pass on the v4 wrap | Skill: `/adversarial-uniswap-hooks` |
| T10 | `/v4-security-foundations` theory pass — categorize attacks against this hook category (oracle-anchored spot-FX) | Skill: `/v4-security-foundations` |
| T11 | `/v4-sdk-integration` for the off-chain side once contracts settle | Skill: `/v4-sdk-integration` |
| T12 | `/viem-integration` for the BUFX SDK + keeper script tightening | Skill: `/viem-integration` |

### Tier 3 — deferred to pre-mainnet audit (user-explicit, do NOT fix this session)

- Role split (admin / operations / executor across multiple EOAs / multisig)
- `withdrawLiquidity` timelock
- `requireVerifiedOracle` default flip to `true`
- External audit (Spearbit / Cantina / OZ) — book before mainnet money

## Skill toolbox for this session

| Skill | When |
|---|---|
| `/gateman-analysis` | After every patch lands — post-impl audit with the four laws + AI verification checklist. Run on every diff before merge. |
| `/codex-adversarial-tenderly-auditor` | After any new contract deployment on Fuji. Probes live Tenderly vnet + Codex adversarial review. Requires Tenderly MCP reauthed first. |
| `/adversarial-uniswap-hooks` | After T6 lands (FxSpotV4Hook). v4-specific red-team audit walking Sections A–K. |
| `/v4-hook-generator` | For T6–T8 build pass. Uniswap-official skill for `BaseCustomCurve` inheritance + HookMiner deploy. |
| `/v4-security-foundations` | T10 theory pass before T9 adversarial run. |
| `/v4-sdk-integration` | T11 off-chain integration. |
| `/viem-integration` | T12 — tighten BUFX-side smoke + indexer code. |

Skill paths (in case any are missing locally):
- `~/.claude/skills/<name>/SKILL.md`
- `~/.codex/skills/<name>/SKILL.md`
- `~/.agents/skills/<name>/SKILL.md`

## How to start this session

1. Read this doc. Confirm it matches what's on `main` HEAD of both repos.
2. Run the verification suite:
   ```bash
   # Telarana
   forge test --root contracts
   bun run live:verify:foundry  # if exists, otherwise forge test fork

   # BUFX (in BUFX repo)
   bun run test
   bun run live:verify:foundry
   bun run security:check
   ```
3. Sample T1 to the user as a yes/no: vendor the reference repos as submodules now, or defer to pre-mainnet?
4. After T1 lands (or is deferred), pick the highest-leverage Tier 1 item and execute end-to-end (patch → test → deploy if needed → /gateman-analysis pass → commit). Same shape as the v0.1 patches.
5. After all Tier 1 items close, move to Tier 2 (v4 hook wrap). Don't skip ahead.

## Decisions to surface to the user — do NOT invent

1. Vendor reference repos as submodules (T1) — yes/no this session
2. Should decimal-aware math (T4) land as v0.2 or wait until v4 wrap (Tier 2)?
3. Sourcing for tier-2 receipt-parity (T5) — Hyperlane message proof vs signed-intent vs leave-as-trust-assumption + document?
4. Per-token spread / OI cap defaults for each spot pair (currently 5 bps default; per-pair overrides recommended for volatile pairs)
5. Production seed quantities once you fund EURC + USDC on mainnet

Ask all of these in one tight message before writing code on any of them.

## What this session is NOT

- Not Phase B/C/D/E (perp engine). That's `docs/CODEX_BRIEF_PHASES_B_TO_E.md` in a separate worktree.
- Not frontend wiring (separate session, no contract changes).
- Not mainnet deployment.
- Not the role split or timelock (user-explicit defer).

## Stop-the-world ship checklist (every patch this session)

- [ ] OZ AccessControl + ReentrancyGuard + Pausable + SafeERC20 + Math.mulDiv where applicable
- [ ] Every formula NatSpec-cites a vendored reference
- [ ] Foundry unit + invariant + ≥256 fuzz runs per math-heavy entry
- [ ] `forge build --root contracts --sizes` shows no contract over 24KB
- [ ] No `require` strings; all custom errors
- [ ] Pause path tested
- [ ] /gateman-analysis pass run + recorded
- [ ] Live deploy script written + dry-run before broadcast
- [ ] Live smoke executed if testnet state changes
- [ ] Commit message documents the change + cites the reference + names the test added

## Reading list

In order:
1. This doc.
2. `docs/PHASE_A_SPOT_EXECUTOR.md` — v0 architecture + 6-step wiring runbook.
3. `contracts/src/spot/FxSpotExecutor.sol` — v0.1 (read the NatSpec changelog at the top).
4. `contracts/test/FxSpotExecutor.t.sol` — 24 tests, model the same coverage for new contracts.
5. `contracts/src/testnet/TestnetFiatToken.sol` — pattern for non-public mock tokens.
6. `docs/CODEX_BRIEF_PHASES_B_TO_E.md` — for context on what's coming after Phase A.
7. `reports/AUDIT_REPORT.md` if it lands during this session.
8. `memory: feedback_no_novel_math` (project rule).

## Contact

User: `tomas.cordero.esp@gmail.com`, GitHub `criptopoeta`. Prefers concise messages. Ask one tight question at a time at decision points. Don't pick defaults silently.

---

**Session start trigger:** Read this doc + confirm verification suite green. Then ask the user the 5 decisions above.
