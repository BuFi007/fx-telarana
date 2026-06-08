# Uniswap v4 indexing readiness

Date: 2026-06-08

This is the current readiness record for getting fx-Telarana hooks indexed once
Uniswap has an official Arc mainnet v4 deployment.

## What Uniswap will index

Uniswap v4 indexing is PoolManager-centered. The v4 subgraph indexes PoolManager
events, identifies pools by `poolId` derived from the full `PoolKey`, and exposes
the `hooks` address as a first-class pool field.

Pool entity indexing and router-active market readiness are separate claims.
The `Initialize` event is the pool entity source of truth. First liquidity and
nonzero current liquidity are required before claiming an active/liquid router
market.

That matters for this project because a v4 pool has one hook address. Hedge,
swap, Gateway, and Ghost behavior cannot be stacked onto the same PoolKey by
attaching multiple hooks. They must either be separate pool families or the
behavior must be composed inside one hook.

Official references:

- Uniswap v4 deployments: https://developers.uniswap.org/docs/protocols/v4/deployments
- Uniswap v4 subgraph queries: https://developers.uniswap.org/docs/ecosystem/subgraphs/concepts/v4/queries
- Uniswap v4 create-pool guide: https://developers.uniswap.org/docs/sdks/v4/guides/create-pool
- Uniswap v4 hooks concept: https://developers.uniswap.org/contracts/v4/concepts/hooks

## Arc testnet status

Arc testnet currently uses our own Uniswap v4 deployments, not an official
Uniswap Arc mainnet deployment.

Machine-readable source:

- `deployments/uniswap-v4-indexing-readiness-5042002.json`

Readiness check:

```bash
bun run uniswap:indexing:check
```

Current expected result: `PASS=609 WARN=1 FAIL=0`. The remaining warning is
`FxHedgeHook` first liquidity, which is required before claiming router-active
or liquid hedge markets.

On-chain receipt evidence check:

```bash
bun run uniswap:indexing:onchain
```

Official Arc readiness check:

```bash
bun run uniswap:official-arc:check
```

Current expected result: `PASS=9 WARN=1 FAIL=0`. The warning is expected until
Uniswap publishes Arc v4 addresses in its official deployments table. If the
official page begins listing Arc while this manifest is still pending, the
checker fails.

Official Arc migration plan:

```bash
bun run uniswap:official-arc:plan
```

Current expected result: `PASS=29 WARN=1 FAIL=0`. The planner is read-only and
prints the required official migration phases: fetch official v4 addresses,
remine/redeploy hooks against official `PoolManager`, initialize official
PoolKeys, add first liquidity, rerun route/quoter diagnostics and router
execution checks, populate the official pool publication input, read official
pool state through `StateView`, and verify pools through the official v4
subgraph.

Official Arc hook remine/redeploy plan:

```bash
bun run uniswap:official-arc:hooks:plan
```

Current expected result: `PASS=28 WARN=1 FAIL=0`. The warning is expected until
Uniswap publishes the official Arc `PoolManager`. This read-only planner checks
that each hook family still has a valid CREATE2/remine path for official Arc:
`FxHedgeHook` mines against an env-provided `POOL_MANAGER`, `FxSwapHook` deploy
and salt-mining scripts include the current vault-backed `FX_VAULT`
constructor argument, and `TelaranaGatewayHubHook` uses the `runCreate2`
permission-bit deployment path.

Official Arc deployment input template:

```bash
bun run uniswap:official-arc:input:generate
```

Current expected result: `PASS=4 WARN=1 FAIL=0`. The warning is expected while
the official Uniswap v4 deployments table does not list Arc. The generator is
read-only by default. Once Arc appears in the official deployments Markdown,
rerun it with `--out <populated-official-arc-input.json>` to produce the
validator-compatible official deployment input directly from Uniswap-published
addresses. It refuses to write output while Arc is absent and rejects reuse of
self-deployed Arc testnet `PoolManager` addresses.

Official Arc deployment input generator self-test:

```bash
bun run uniswap:official-arc:input:generate:self-test
```

Current expected result: `PASS=10 FAIL=0`. This generates temporary
Arc-absent, Arc-present, and bad-PoolManager fixtures. It proves Arc-absent
official docs keep the default template pending, Arc-present docs generate a
validator-compatible input, and self-deployed PoolManager reuse fails.

Official Arc deployment input verifier:

```bash
bun run uniswap:official-arc:input:check
```

Current expected result: `PASS=11 WARN=1 FAIL=0`. The warning is expected while
`deployments/uniswap-v4-official-arc-input.template.json` is still a pending
template. When Uniswap publishes Arc v4 addresses, copy the template to a
populated file, set `OFFICIAL_ARC_DEPLOYMENT_INPUT` to that file, and rerun this
check before changing the readiness manifest. A populated official input must
not reuse either self-deployed Arc testnet PoolManager.

Official Arc deployment input checker self-test:

```bash
bun run uniswap:official-arc:input:self-test
```

Current expected result: `PASS=8 FAIL=0`. This generates temporary pending,
good-populated, and bad-PoolManager fixtures. It proves the checker accepts a
non-self-deployed populated `PoolManager` offline, and rejects a populated input
that points at one of the self-deployed Arc testnet PoolManagers.

Official Arc pool publication input:

```bash
bun run uniswap:official-arc:pools:check
```

Current expected result: `PASS=34 WARN=1 FAIL=0`. The warning is expected while
`deployments/uniswap-v4-official-arc-pools.template.json` is still pending.
When official pools are initialized and liquid, populate an official pool file
with each `PoolKey`, `poolId`, init tx, first liquidity tx, router/quoter
status, router execution evidence, `routerActiveClaim`, `StateView` status,
subgraph status, and receipt verification flags, then rerun with
`OFFICIAL_ARC_POOL_PUBLICATION_INPUT` pointing at that file. The checker also
requires the official PoolManager from `sourceDeploymentInput`, no reuse of the
self-deployed Arc testnet PoolManagers, unique family/symbol labels, unique
poolIds, and official hook low-14 permission bits matching the source hook
family. Use `status=draft` for offline populated preflight. Use `status=ready`
only when `OFFICIAL_ARC_RPC_URL` is set; ready mode requires concrete StateView
sqrt price/liquidity evidence, concrete subgraph id/hooks/token/fee/liquidity
evidence, `receiptVerification.initializeTxVerified=true`,
`receiptVerification.firstLiquidityTxVerified=true`, and live receipt checks
proving that `initializeTx` emits the official
`PoolManager.Initialize` event and `firstLiquidityTx` emits a positive official
`PoolManager.ModifyLiquidity` event. Use the same populated file for the
StateView and subgraph checks below so official pool records are not duplicated
across manifests.

Official Arc pool publication fill plan:

```bash
bun run uniswap:official-arc:pools:plan
```

Current expected result: `PASS=58 WARN=1 FAIL=0`. The warning is expected
while the official Arc `PoolManager` is still pending. This read-only planner
derives all 11 official pool records from the Arc testnet evidence manifest and
prints the exact fields operators must populate after official hook redeploys:
official hook address, official `PoolKey`, derived `poolId`, initialize tx,
first-liquidity tx, route/quoter status, StateView evidence, subgraph evidence,
router execution evidence, and receipt verification flags. It is not a
readiness claim; the populated file must still pass
`bun run uniswap:official-arc:pools:check`.

Official Arc pool publication checker self-test:

```bash
bun run uniswap:official-arc:pools:self-test
```

Current expected result: `PASS=12 FAIL=0`. This generates temporary populated
official-pool fixtures from the readiness manifest, confirms `status=draft`
passes as offline preflight only, and confirms `status=ready` fails without
`OFFICIAL_ARC_RPC_URL` because live official `PoolManager` receipt verification
is required. It also proves records missing exact-input Quoter evidence or a
custom-route caveat fail, and records missing Universal Router execution
evidence or a custom-route caveat fail. It also proves records missing ready
receipt verification flags fail. The temporary files are removed before the
command exits.

Official v4 StateView verification gate:

```bash
bun run uniswap:stateview:check
```

Current expected result: `PASS=13 WARN=1 FAIL=0`. The warning is expected until
official Arc pool IDs and official Arc `StateView` are available. Once ready,
set `OFFICIAL_ARC_POOL_PUBLICATION_INPUT` to the populated official pool file,
set `OFFICIAL_ARC_RPC_URL` or the manifest RPC URL, and verify each official
pool by `StateView.getSlot0(poolId)` and `StateView.getLiquidity(poolId)`.

Official v4 subgraph verification gate:

```bash
bun run uniswap:subgraph:check
```

Current expected result: `PASS=15 WARN=1 FAIL=0`. The warning is expected until
official Arc pool IDs and the official v4 subgraph endpoint are available. Once
ready, set `OFFICIAL_ARC_POOL_PUBLICATION_INPUT` to the populated official pool
file, set `UNISWAP_V4_SUBGRAPH_URL` or the manifest endpoint, and verify every
official pool by `poolId`, `hooks`, token0/token1, fee tier, tick spacing, price
state, and liquidity.

Official multichain deployment/indexing gate:

```bash
bun run uniswap:official-multichain:check
```

Current expected result: `PASS=289 WARN=4 FAIL=0`. This validates the
machine-readable multichain manifest at
`deployments/uniswap-v4-official-multichain-readiness.json`. The official
Uniswap v4 deployments table lists Avalanche C-Chain (`43114`) and Arbitrum One
(`42161`) contract addresses, including `PoolManager`, `PositionManager`,
`UniversalRouter`, `Quoter`, `StateView`, and canonical `Permit2`. The check now
also verifies deployed bytecode for the published Avalanche/Arbitrum official
contracts through recorded public RPC fallbacks, while env vars
`AVALANCHE_RPC_URL` and `ARBITRUM_RPC_URL` can override those endpoints. The
same table does not list Avalanche Fuji (`43113`) or Arc mainnet as of
2026-06-08, so both remain pending official addresses.

The four warnings are intentional:

- Arc mainnet official Uniswap v4 addresses are not published yet.
- Avalanche Fuji official Uniswap v4 addresses are not published yet; the
  recorded Fuji `PoolManager` is rehearsal-only and must not be used for
  official indexing claims.
- Avalanche has official Uniswap v4 contracts, but fx-Telarana hook pools still
  need chain-specific hook remine/redeploy, `PoolManager.Initialize` txs, first
  liquidity, `StateView`, subgraph, exact-input `Quoter`, and Universal Router
  execution evidence or custom-route caveats.
- Arbitrum One has official Uniswap v4 contracts, but fx-Telarana hook pools
  still need the same chain-specific publication evidence.

Official multichain deployment input checker:

```bash
bun run uniswap:official-multichain:input:check
```

Current expected result: `PASS=75 WARN=2 FAIL=0`. This standalone checker
validates generated or hand-reviewed multichain deployment-input bundles before
hook redeploy and pool publication. By default it checks
`deployments/uniswap-v4-official-multichain-readiness.json`; set
`OFFICIAL_MULTICHAIN_DEPLOYMENT_INPUT=<generated-file>` to validate a generated
bundle. The two warnings are expected while Arc and Fuji are absent from
official Uniswap deployments.

Official multichain deployment input generator:

```bash
bun run uniswap:official-multichain:input:generate
```

Current expected result: `PASS=36 WARN=2 FAIL=0`. The generator parses the
official Uniswap v4 deployments Markdown and builds target-chain official
deployment inputs for Arc mainnet, Avalanche Fuji, Avalanche C-Chain, and
Arbitrum One. The two warnings are expected while Arc and Fuji are absent from
official Uniswap deployments. Avalanche and Arbitrum are populated directly
from the official table. Use `--out <generated-file>` to write the generated
bundle for review.

Official multichain deployment input generator self-test:

```bash
bun run uniswap:official-multichain:input:generate:self-test
```

Current expected result: `PASS=20 FAIL=0`. This generates fixture deployments
Markdown proving the current docs shape keeps Arc/Fuji pending, a future
all-target docs shape populates all four targets, current generated bundles pass
the standalone checker, future all-target bundles fail until manifests are
updated, and self-deployed/rehearsal PoolManagers are rejected.

Official multichain source freshness gate:

```bash
bun run uniswap:official-multichain:docs:check
```

Current expected result: `PASS=31 WARN=2 FAIL=0`. This fetches the official
Uniswap v4 deployments Markdown, parses network sections, confirms Avalanche
C-Chain and Arbitrum One addresses still match the local manifest, and confirms
Arc mainnet plus Avalanche Fuji are still absent from the official deployments
table. The two warnings are expected until Uniswap publishes official Arc and
Fuji v4 addresses.

Official multichain source freshness checker self-test:

```bash
bun run uniswap:official-multichain:docs:self-test
```

Current expected result: `PASS=8 FAIL=0`. This generates temporary Markdown
fixtures proving the docs freshness checker accepts the current
Avalanche/Arbitrum-only source shape, fails when Arc or Fuji appear while the
manifest is still pending, and fails when an official published address drifts.
The temporary files are removed before the command exits.

Official multichain hook remine/redeploy plan:

```bash
bun run uniswap:official-multichain:hooks:plan
```

Current expected result: `PASS=50 WARN=4 FAIL=0`. This validates source hook
low-14 permission bits, deploy script prerequisites, official Avalanche and
Arbitrum PoolManager targets, self-deployed PoolManager rejection, and prints
no-broadcast command templates for FxHedgeHook, FxSwapHook, and
TelaranaGatewayHubHook on the published official target chains. The four
warnings are expected: Arc/Fuji official addresses are pending, while Avalanche
and Arbitrum hook redeploys still need operator broadcast evidence. The
generated snapshot also requires post-redeploy Universal Router execution
evidence or an explicit custom-route caveat before official router/indexing
claims.

Checked multichain hook remine/redeploy plan snapshot:

```bash
bun run uniswap:official-multichain:hooks:plan:write
```

This writes
`deployments/uniswap-v4-official-multichain-hooks-redeploy-plan.json`.

Multichain hook remine/redeploy plan freshness check:

```bash
bun run uniswap:official-multichain:hooks:plan:check
```

This regenerates the hook redeploy plan in memory and fails if
`deployments/uniswap-v4-official-multichain-hooks-redeploy-plan.json` is stale.
Current expected result: `PASS=50 WARN=4 FAIL=0`.

Official multichain pool-publication gate:

```bash
bun run uniswap:official-multichain:pools:check
```

Current expected result: `PASS=68 WARN=4 FAIL=0`. This validates
`deployments/uniswap-v4-official-multichain-pools.template.json` and enforces
the publication shape for Arc mainnet, Avalanche Fuji, Avalanche C-Chain, and
Arbitrum One. Ready-mode pool records must use the target-chain official
`PoolManager`, reject self-deployed Arc/Fuji rehearsal PoolManagers, preserve
hook low-14 permission bits, prove pool IDs from the official `PoolKey`, and
carry initialize tx, first-liquidity tx, `StateView`, subgraph, Quoter/custom
route, Universal Router execution or custom-route evidence, and live
target-chain receipt verification evidence.

Official multichain pool-publication fill plan:

```bash
bun run uniswap:official-multichain:pools:plan
```

Current expected result: `PASS=81 WARN=4 FAIL=0`. This read-only planner
derives all 11 source pool templates from the Arc testnet evidence manifest and
prints the target-chain fields required for Arc mainnet, Avalanche Fuji,
Avalanche C-Chain, and Arbitrum One. The four warnings are expected: Arc and
Fuji official v4 addresses are still pending, while Avalanche and Arbitrum have
official contracts but still need hook redeploy, `PoolManager.Initialize`
transactions, first liquidity, `StateView`, subgraph, route/quoter evidence,
and router execution evidence before official hook-pool indexing can be claimed.

Checked multichain pool-publication fill-plan snapshot:

```bash
bun run uniswap:official-multichain:pools:plan:write
```

This writes
`deployments/uniswap-v4-official-multichain-pools-fill-plan.json`.

Multichain pool-publication fill-plan freshness check:

```bash
bun run uniswap:official-multichain:pools:plan:check
```

This regenerates the fill plan in memory and fails if
`deployments/uniswap-v4-official-multichain-pools-fill-plan.json` is stale.

Official multichain pool-publication checker self-test:

```bash
bun run uniswap:official-multichain:pools:self-test
```

Current expected result: `PASS=15 FAIL=0`. This generates temporary populated
Avalanche and Arbitrum pool-publication fixtures from the readiness manifest,
confirms `status=draft` passes as offline preflight with per-target pool
counts, confirms `status=ready` fails without live target-chain RPC receipt
verification, and confirms self-deployed/rehearsal PoolManagers are rejected.
It also proves records missing exact-input Quoter evidence, Universal Router
execution evidence, or custom-route caveats fail. The temporary files are
removed before the command exits.

Official multichain StateView verification gate:

```bash
bun run uniswap:official-multichain:stateview:check
```

Current expected result: `PASS=29 WARN=4 FAIL=0`. This validates the
target-chain `StateView` evidence shape for Arc mainnet, Avalanche Fuji,
Avalanche C-Chain, and Arbitrum One. Arc and Fuji remain warning-only because
official Uniswap v4 addresses are not published yet; Avalanche and Arbitrum
remain warning-only because fx-Telarana hook pools still need official
PoolManager pool IDs, `StateView.getSlot0(poolId)`, and
`StateView.getLiquidity(poolId)` evidence after hook redeploy and first
liquidity.

Official multichain subgraph verification gate:

```bash
bun run uniswap:official-multichain:subgraph:check
```

Current expected result: `PASS=29 WARN=4 FAIL=0`. This validates the
target-chain Uniswap v4 subgraph evidence shape for Arc mainnet, Avalanche
Fuji, Avalanche C-Chain, and Arbitrum One. Arc and Fuji remain warning-only
because official Uniswap v4 addresses are not published yet; Avalanche and
Arbitrum remain warning-only because fx-Telarana hook pools still need official
PoolManager pool IDs and subgraph pool entity evidence after hook redeploy and
first liquidity.

Official multichain indexed-state checker self-test:

```bash
bun run uniswap:official-multichain:indexing:self-test
```

Current expected result: `PASS=14 FAIL=0`. This creates temporary populated
Avalanche and Arbitrum draft fixtures for all 11 source pool templates,
validates embedded StateView and subgraph evidence as offline preflight only,
and proves malformed liquidity or hook-address evidence fails before any
official-chain readiness claim can be made.

Official multichain Quoter verification gate:

```bash
bun run uniswap:official-multichain:quoter:check
```

Current expected result: `PASS=25 WARN=4 FAIL=0`. This validates the
target-chain exact-input `Quoter` evidence shape for Arc mainnet, Avalanche
Fuji, Avalanche C-Chain, and Arbitrum One. Arc and Fuji remain warning-only
because official Uniswap v4 addresses are not published yet; Avalanche and
Arbitrum remain warning-only because fx-Telarana hook pools still need
chain-specific hook redeploy, official PoolKeys, first liquidity, and
exact-input `Quoter` evidence or explicit custom-route caveats before official
router-indexing claims.

Official multichain Universal Router execution gate:

```bash
bun run uniswap:official-multichain:router:check
```

Current expected result: `PASS=34 WARN=4 FAIL=0`. This validates the
target-chain Universal Router execution evidence shape for Arc mainnet,
Avalanche Fuji, Avalanche C-Chain, and Arbitrum One. Arc and Fuji remain
warning-only because official Uniswap v4 addresses are not published yet;
Avalanche and Arbitrum remain warning-only because fx-Telarana hook pools still
need chain-specific hook redeploy, official PoolKeys, first liquidity, and
Universal Router execution evidence or explicit custom-route caveats before
router-active claims.

Indexer evidence export:

```bash
bun run uniswap:evidence:export
```

This emits one JSON packet with the Arc testnet PoolManagers, official Arc
pending status, multichain official deployment status, every published PoolKey,
poolId, init tx, hook permission flags, route/quoter caveats, router execution
requirements, and the verification commands. The current packet has 11 pool
records across
`FxHedgeHook`, `FxSwapHook`, and `TelaranaGatewayHubHook`.

Checked evidence snapshot:

```bash
bun run uniswap:evidence:write
```

This writes `deployments/uniswap-v4-indexing-evidence-5042002.json`. The
aggregate readiness check validates that the snapshot exists, matches the
manifest network/status, includes all 11 poolIds, and has a complete PoolKey for
each pool.

Snapshot freshness check:

```bash
bun run uniswap:evidence:check
```

Hook permission diagnostic:

```bash
bun run uniswap:hook-permissions
```

Current expected result: `4 forge tests passed`. This focused Foundry gate
checks that the deployed/mined permission bits and declared hook permissions
stay aligned for `FxHedgeHook`, `FxSwapHook`, `TelaranaGatewayHubHook`, and
`FxGhostKycHook`.

This regenerates the evidence packet in memory and fails if
`deployments/uniswap-v4-indexing-evidence-5042002.json` is stale.

Requirements matrix:

```bash
bun run uniswap:requirements:export
```

Current expected result: `PASS=13 WARN=9 FAIL=0`. This exports a
requirement-by-requirement evidence matrix for the original indexing goal. The
passes cover official docs freshness, Arc testnet pool evidence, six live hedge
pools, router/quoter diagnostics, the handoff packet, completion-audit gating,
the multichain StateView gate, the multichain subgraph gate, the multichain
Quoter gate, the multichain Universal Router execution gate, Avalanche and
Arbitrum official v4 contract tracking, and the no-ops-surface caveat. The
warnings are the still-open
official or operator conditions: Arc official contracts, Fuji official
contracts, official Arc hook redeploy, official Arc pool publication, official
Arc StateView, official Arc subgraph, first liquidity, Avalanche hook-pool
publication, and Arbitrum One hook-pool publication.

Checked requirements snapshot:

```bash
bun run uniswap:requirements:write
```

This writes
`deployments/uniswap-v4-indexing-requirements-5042002.json`.

Requirements freshness check:

```bash
bun run uniswap:requirements:check
```

This regenerates the requirements matrix in memory and fails if
`deployments/uniswap-v4-indexing-requirements-5042002.json` is stale.

Hook indexer metadata packet:

```bash
bun run uniswap:hook-metadata:export
```

This emits the compact, machine-readable hook/indexer handoff derived from the
readiness manifest. It includes hook family identities, low-14 permission bits,
PoolKeys, poolIds, initialize transactions, router/quoter status, official
multichain target status, and explicit official-indexing caveats.

Checked hook metadata snapshot:

```bash
bun run uniswap:hook-metadata:write
```

This writes `deployments/uniswap-v4-hook-indexer-metadata-5042002.json`.

Hook metadata exporter self-test:

```bash
bun run uniswap:hook-metadata:self-test
```

Current expected result: `PASS=13 FAIL=0`. This proves the metadata exporter
accepts the manifest-derived fixture, rejects a valid-but-wrong `poolId` that
does not derive from its `PoolKey`, rejects bad hook low-14 permission bits,
and preserves Arc/Fuji pending plus Avalanche/Arbitrum official-contract status
in the compact handoff.

Hook metadata freshness check:

```bash
bun run uniswap:hook-metadata:check
```

This regenerates the metadata packet in memory and fails if
`deployments/uniswap-v4-hook-indexer-metadata-5042002.json` is stale.

Indexer handoff packet:

```bash
bun run uniswap:handoff:render
```

Current expected result: `PASS=9 WARN=4 FAIL=0`. This renders the committed
JSON evidence snapshot into reviewer-facing Markdown with official multichain
status, all 11 Arc testnet pool records, the exact reviewer commands, and the
current do-not-claim caveats. The warnings are intentional: official Arc
mainnet, official Fuji, Avalanche/Arbitrum official hook-pool publication
evidence, and hedge first liquidity remain pending.

Checked handoff snapshot:

```bash
bun run uniswap:handoff:write
```

This writes `deployments/uniswap-v4-indexing-handoff-5042002.md`.

Handoff freshness check:

```bash
bun run uniswap:handoff:check
```

This regenerates the handoff packet in memory and fails if
`deployments/uniswap-v4-indexing-handoff-5042002.md` is stale.

Completion audit:

```bash
bun run uniswap:completion:audit
```

Current expected result: `PASS=28 WARN=6 FAIL=0`, with
`completionStatus not-complete`. This audits the original goal directly rather
than redefining completion around local rehearsal evidence. The warnings are the
remaining completion blockers: official Arc contracts, official Fuji contracts,
official Arc PoolManager pool publication records, Avalanche hook-pool
publication, Arbitrum One hook-pool publication, and first liquidity for
router-active hedge market claims.

Submission audit:

```bash
bun run uniswap:submission:audit
```

Current expected result: `CHECKS=43 PASS=43 WARN=88 FAIL=0`. This is the
single reviewer-facing no-broadcast command for the indexing package. It
re-runs official Uniswap deployment freshness, official Arc and multichain
readiness gates, deployment-input generation/checks, the Arc pool-publication
fill plan, pool-publication self-tests, StateView/subgraph preflights,
multichain StateView/subgraph/Quoter/router preflights, the standalone
multichain indexed-state self-test, the standalone multichain route-evidence
self-test, live
`FxHedgeHook.poolConfigs` storage checks, `FxHedgeHook` liquidity checks, live
Arc PoolManager receipt verification, both local official `V4Quoter`
diagnostics, the hook permission diagnostic, hook metadata
self-test/freshness, evidence snapshot freshness, requirements matrix
freshness, handoff snapshot freshness, and the completion audit. The warnings
are the documented pending
conditions: Arc/Fuji official addresses, official-chain pool publication,
subgraph/StateView readiness before official pool records, and hedge first
liquidity.

Current PoolManagers:

| Surface | PoolManager | Manifest |
|---|---|---|
| `FxHedgeHook` | `0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E` | `deployments/fx-hedge-hook-5042002.json`, `deployments/fx-hedge-stable-pools-5042002.json` |
| `FxSwapHook` / `TelaranaGatewayHubHook` | `0x3FA22b7Aeda9ebBe34732ea394f1711887363B34` | `deployments/fxswap-vault-backed-v2-5042002.json`, `deployments/arc-testnet.json` |

These contracts are enough for testnet dogfood and local verification. They are
not enough to claim official Uniswap Arc mainnet indexing until the pools are
initialized on the official Uniswap Arc PoolManager.

## Hook surfaces

### FxHedgeHook

Address: `0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540`

Permission bits: `1344` (`afterAddLiquidity`, `afterRemoveLiquidity`,
`afterSwap`). The low 14 address bits match the permission flags.

This is the cleanest Uniswap-indexable surface because it is an observer hook
with no custom swap deltas. Once redeployed against an official PoolManager,
initialized pools should be ordinary v4 pool entities with a hook address.

Local official `V4Quoter` diagnostic:

```bash
bun run uniswap:hedge:v4quoter
```

Current expected result: `2 passed; 0 failed`. The diagnostic quotes
exact-input and exact-output swaps through `@uniswap/v4-periphery` `V4Quoter`
with empty hook data, then asserts that quote simulation does not persist
`FxHedgeHook` exposure or hedge state.

Live manifest-backed pools today:

| Pair | PoolId | Init tx | Configure tx |
|---|---|---|---|
| `JPYC/USDC` | `0xd19440c05e5c0d9549187e01162e8aeab29c196c3177cde6360db740b8aa3504` | `0xa2564c11072dddd7f56fa7150d2da815d6047f1cc6a8294782cd2ddb1687335e` | `0xc47673efe48919516cbc22772b73f7c9be0240b60e4b412c6c7a598ccac6c9d4` |
| `cirBTC/USDC` | `0x33e42e1b20e3ea50b925963b583a033a8b959f53ffe76fb18cb97a6c6a171a8d` | `0x1e662456f1979eb6362935cc0057fce66a37fdd188d941d0d3f8a631b5b7b22c` | `0xfae6941012283969cdfd0d943bb5aedb5a1fd427980afc4c642f58d30c04e99b` |
| `EURC/USDC` | `0x0a463f18e563a62ab306eb375452c3feebe9ccbdab822b3c3582ddd13443ce00` | `0x1b7a1a38a1960319a8d60a6ddf3e04a2d9d6f1ebd4931c86eaddfc4fbbcd128e` | `0xd1da69388c0228c2a265172ecd05f9164bf7e63b9239373518ceb057915721ed` |
| `AUDF/USDC` | `0x3d6aafb1d198968d10fb9d8596681979be57116efc7dda5f1e2694c6841a3e08` | `0x879b7286dc07d64ff83258769a19c6709edcda3bf0851765e6979602c4270b1d` | `0xdbf97dd4b1cc12dbd7c6fb2c2c9556c81a25de4a25462d26346ea6dc44cda8b3` |
| `MXNB/USDC` | `0x5bd11000bfaa4f274a1cbc0b7d5c20f92ffc047738ac04963fcaac3221466946` | `0x40589ff7072d44afaeb90bacfb3fa65d58a77eba255c2443db9e2e4b5fe2c554` | `0xee1492481b70db7850abaa6202b05b77c8db8ee160cda7d78378699a46628303` |
| `QCAD/USDC` | `0x1ad04bd3b9be342b2c720b5bbde60569cea51b9c343cfb4848f342a45e061fd7` | `0xd0594a7fa15d4eaa6e471a2b308739a2bf428650d70ce64d629e9e03cb82dc34` | `0xca2a4dbb6e75446fc4dfc79396662115ad8ab4aeb8abe2e914789799bc8f81f8` |

No-key hedge pool state verifier:

```bash
bun run hedge:arc:plan-stables
```

The verifier recomputes each PoolId from its PoolKey, reads
`FxHedgeHook.poolConfigs(poolId)`, and confirms all six hedge pools are enabled
with the expected market, hedge token, Pyth feed, decimals, and rebalance
threshold.

Liquidity readiness verifier:

```bash
bun run uniswap:hedge:liquidity
```

Current expected result: `PASS=1 WARN=13 FAIL=0`. All six hedge pools are
initialized and hook-configured, but current in-range liquidity is zero and no
`ModifyLiquidity` add event exists yet. Do not claim router-active/liquid hedge
markets until first liquidity txs are published and current liquidity is
nonzero.

First-liquidity no-broadcast operator plan:

```bash
bun run uniswap:hedge:liquidity:plan
```

Current expected result: `PASS=32 WARN=1 FAIL=0`. This reads only the readiness
manifest and prints the exact per-pool env matrix, PoolKeys, and full-range tick
bounds required by `SeedFxHedgeHookLiquidity.s.sol`.

First-liquidity operator script:

```bash
bun run hedge:arc:seed-liquidity
```

That command requires `KEEPER_PRIVATE_KEY` or `DEPLOYER_PRIVATE_KEY`, per-pair
`<PAIR>_LIQUIDITY_DELTA`, and token allowance caps. It simulates unless
`--broadcast` is added to the underlying Foundry command. It uses a direct
PoolManager unlock helper for Arc testnet/operator seeding; for official Arc
mainnet, prefer official `PositionManager`/periphery once Uniswap publishes
addresses unless this helper path is explicitly reviewed for that deployment.

Operator/recovery script:

```bash
bun run hedge:arc:configure-stables
```

That command requires `DEPLOYER_PRIVATE_KEY` for an account with
`POOL_CONFIGURATOR_ROLE`. It simulates unless `--broadcast` is added to the
underlying Foundry command, and it now skips `initialize` for pools that already
have PoolManager slot0 state.

### FxSwapHook

Permission bits: `2760` (`beforeAddLiquidity`, `beforeRemoveLiquidity`,
`beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`). The deployed hook
addresses in `deployments/fxswap-vault-backed-v2-5042002.json` match these low
14 bits.

The direct protocol quote and exact-input route surfaces are live for the
vault-backed pools. Generic empty-`hookData` official `V4Quoter` compatibility
is explicitly not claimed: the local diagnostic proves direct `quote()` and the
protocol exact-input router work, while official `V4Quoter` does not produce a
generic quote for this custom-accounting PMM shape. `FxSwapHook` uses custom
before-swap delta accounting and exact-output is intentionally unsupported. The
current manifest also records that canonical `PoolSwapTest` is incompatible
because it settles input after `manager.swap`.

Local official `V4Quoter` diagnostic:

```bash
bun run uniswap:fxswap:v4quoter
```

Current expected result: `3 passed; 0 failed`. The diagnostic covers direct
`FxSwapHook.quote`, the protocol `FxV4RouterHarness` exact-input path, and the
negative official `V4Quoter` empty-`hookData` cases for exact-input and
exact-output.

Self-deployed Arc testnet poolIds verified from PoolKey derivation and
PoolManager `Initialize` logs:

| Pair | PoolId | Init tx | Block |
|---|---|---|---|
| `USDC/EURC` | `0x4d268583c6cefb4fb959761f3f733c22b6a0bd622a2e7fa04dd30fe6e35e2d9c` | `0xba9982b907ade0bcb67acabeac7b8bd36628b4e321f8ab8110f9384ce38da72e` | `44517407` |
| `USDC/AUDF` | `0x7b1fbffcc973902a9cb09cb66f7322f7e750d0f54f953abdea910b2e21267de6` | `0xc3c5c4379bf5a4eca36abb822f08af18dca121b4d4de9756f117a9e17984615f` | `44517559` |
| `USDC/MXNB` | `0x964b698844ab4699762ec07031a2dc953d7cfc17f567dc43faccf6dac23c1c39` | `0x289fe08e3bb5f0d571b41a2699959cde5adeff3e318a34c0659ee34f0b7af55c` | `44517669` |
| `QCAD/USDC` | `0x5303c347ab8aa48a98f6738d4598bd3d8db7a9924143a990ad883cd54a7adb41` | `0xb2d63cb96b38d981b9605013f88837b5ae614ae2088463a2beeeea15c63eaaf5` | `44517765` |

Keep the router-compatibility claim scoped to direct quote/exact-input protocol
routes. Do not claim generic empty-`hookData` `V4Quoter` compatibility for this
hook.

### TelaranaGatewayHubHook

Address: `0xe895CB461AFF6E98167a7FA0Db252ba906714088`

Permission bits: `136` (`beforeSwap`, `beforeSwapReturnDelta`). The low 14
address bits match the permission flags.

This route is not generic empty-`hookData` quotable. It requires Gateway route
and attestation context in hook data, so it should be documented as a custom
route rather than a standard router-quote surface.

### FxGhostKycHook

Status: future scaffold, no production pool in this indexing package.

This hook is not part of the Uniswap indexing submission surface today.

## Official Arc mainnet checklist

As of 2026-06-08, the official Uniswap v4 deployment table does not list Arc.
When Arc is listed, do this before claiming official indexing:

1. Pull official `PoolManager`, `PositionManager`, `UniversalRouter`, `Quoter`,
   `StateView`, and `Permit2` addresses from Uniswap deployments.
2. Run `bun run uniswap:official-arc:input:generate -- --out <populated-file>`
   to create the official Arc deployment input directly from Uniswap's
   deployments Markdown.
3. Run `bun run uniswap:official-arc:input:generate:self-test`,
   `bun run uniswap:official-arc:input:check`, and
   `bun run uniswap:official-arc:input:self-test` against the populated input.
4. Run `bun run uniswap:official-arc:hooks:plan` and fix any deploy-script or
   constructor drift before broadcasting.
5. Redeploy or remine hooks with the official `PoolManager` constructor
   argument.
6. Initialize pools on the official `PoolManager` with the exact `PoolKey`
   intended for indexing.
7. Add first liquidity through official periphery or a reviewed compatible route.
8. Publish `PoolKey`, `poolId`, init tx, first liquidity tx, hook address,
   permission flags, and router/quoter support status.
9. Populate the official Arc pool publication input and run
   `bun run uniswap:official-arc:pools:check` against it; this must verify the
   official PoolManager, unique labels/poolIds, hook permission bits, and first
   liquidity/indexing evidence. Keep the file at `status=draft` for offline
   preflight; switch it to `status=ready` only when `OFFICIAL_ARC_RPC_URL`
   verifies the actual PoolManager `Initialize` and positive `ModifyLiquidity`
   receipts, and when each pool carries concrete StateView/subgraph evidence
   fields.
10. Run `bun run uniswap:official-multichain:docs:check` and confirm it exits
   with `FAIL=0`; the current expected summary is `PASS=31 WARN=2 FAIL=0`.
   Confirm Avalanche and Arbitrum official addresses still match the Uniswap
   docs and Arc/Fuji still remain pending unless Uniswap has published them.
11. Run `bun run uniswap:official-multichain:docs:self-test` and confirm it
   exits with `FAIL=0`; the current expected summary is `PASS=8 FAIL=0`.
   Confirm fixture cases fail when Arc/Fuji are newly listed or a published
   address drifts.
12. Run `bun run uniswap:official-multichain:input:check` and confirm it exits
   with `FAIL=0`; the current expected summary is
   `PASS=75 WARN=2 FAIL=0`.
13. Run `bun run uniswap:official-multichain:input:generate` and confirm it
   exits with `FAIL=0`; the current expected summary is
   `PASS=36 WARN=2 FAIL=0`.
14. Run `bun run uniswap:official-multichain:input:generate:self-test` and
   confirm it exits with `FAIL=0`; the current expected summary is
   `PASS=20 FAIL=0`.
15. Run `bun run uniswap:official-multichain:check` and confirm it exits with
   `FAIL=0`; the current expected summary is `PASS=289 WARN=4 FAIL=0`.
   Confirm Avalanche C-Chain and Arbitrum One have official v4 contract
   addresses with deployed bytecode on their recorded RPC fallbacks, while Arc
   mainnet and Avalanche Fuji stay pending. Also confirm Avalanche/Arbitrum
   hook-pool indexing is not claimed until chain-specific initialize,
   first-liquidity, StateView, subgraph, and Quoter evidence exists.
16. Run `bun run uniswap:official-multichain:hooks:plan` and confirm it exits
   with `FAIL=0`; the current expected summary is `PASS=50 WARN=4 FAIL=0`.
   Confirm it prints no-broadcast hook redeploy command templates for Avalanche
   and Arbitrum using official PoolManagers, while Arc/Fuji remain pending.
17. Run `bun run uniswap:official-multichain:hooks:plan:write` and confirm it
   refreshes
   `deployments/uniswap-v4-official-multichain-hooks-redeploy-plan.json`.
18. Run `bun run uniswap:official-multichain:hooks:plan:check` and confirm the
   hook redeploy plan snapshot is fresh with `PASS=50 WARN=4 FAIL=0`.
19. Run `bun run uniswap:official-multichain:pools:check` and confirm it exits
   with `FAIL=0`; the current expected summary is `PASS=68 WARN=4 FAIL=0`.
   Confirm the default template has empty official pool records for all targets
   and that ready-mode records would require official PoolManager receipt,
   StateView, subgraph, Quoter/custom-route, and Universal Router execution
   evidence.
20. Run `bun run uniswap:official-multichain:pools:plan` and confirm it exits
   with `FAIL=0`; the current expected summary is `PASS=81 WARN=4 FAIL=0`.
   Confirm it derives 11 source pool templates and prints target-chain fill
   records for Arc mainnet, Avalanche Fuji, Avalanche C-Chain, and Arbitrum One.
21. Run `bun run uniswap:official-multichain:pools:plan:write` and confirm it
   refreshes
   `deployments/uniswap-v4-official-multichain-pools-fill-plan.json`.
22. Run `bun run uniswap:official-multichain:pools:plan:check` and confirm the
   fill-plan snapshot is fresh with `PASS=81 WARN=4 FAIL=0`.
23. Run `bun run uniswap:official-multichain:pools:self-test` and confirm it
   exits with `FAIL=0`; the current expected summary is `PASS=15 FAIL=0`.
   Confirm populated draft Avalanche/Arbitrum fixtures pass offline, populated
   ready fixtures fail without `AVALANCHE_RPC_URL` and `ARBITRUM_RPC_URL`, and
   self-deployed PoolManagers plus missing router/quoter evidence are rejected.
24. Run `bun run uniswap:official-multichain:stateview:check` and confirm it
   exits with `FAIL=0`; the current expected summary is
   `PASS=29 WARN=4 FAIL=0`.
25. Run `bun run uniswap:official-multichain:subgraph:check` and confirm it
   exits with `FAIL=0`; the current expected summary is
   `PASS=29 WARN=4 FAIL=0`.
26. Run `bun run uniswap:official-multichain:quoter:check` and confirm it exits
   with `FAIL=0`; the current expected summary is `PASS=25 WARN=4 FAIL=0`.
   Confirm ready target-chain pool records include exact-input `Quoter` evidence
   or explicit custom-route caveats, and that `FxHedgeHook` ready records require
   exact-input `Quoter` evidence.
27. Run `bun run uniswap:official-multichain:router:check` and confirm it exits
   with `FAIL=0`; the current expected summary is `PASS=34 WARN=4 FAIL=0`.
   Confirm ready target-chain pool records include Universal Router execution
   evidence or explicit custom-route caveats, and that `FxHedgeHook` ready
   records require Universal Router execution evidence.
28. Run `bun run uniswap:stateview:check` with the same
   `OFFICIAL_ARC_POOL_PUBLICATION_INPUT` and the official Arc RPC, then verify
   `StateView.getSlot0(poolId)` plus `StateView.getLiquidity(poolId)`.
29. Query the official v4 subgraph by `poolId` and verify the pool `hooks`,
   token0/token1, fee tier, tick spacing, price state, and liquidity fields.
30. Run `bun run uniswap:subgraph:check` with the same
   `OFFICIAL_ARC_POOL_PUBLICATION_INPUT` and the official v4 subgraph endpoint;
   fail the submission if any official pool is missing or has the wrong `hooks`
   address.

## Claude verification prompt

Ask Claude to verify these points:

1. Run `bun run uniswap:indexing:check` from the `fx-telarana` repo.
2. Confirm the check exits with `FAIL=0`; the current expected summary is
   `PASS=609 WARN=1 FAIL=0`.
3. Run `bun run uniswap:official-arc:check` and confirm official Arc is either
   fully populated from Uniswap docs or still pending with the expected warning;
   current expected summary is `PASS=9 WARN=1 FAIL=0`.
4. Run `bun run uniswap:official-arc:plan` and confirm the read-only migration
   plan exits with `FAIL=0`; the current expected summary is
   `PASS=29 WARN=1 FAIL=0`.
5. Run `bun run uniswap:official-arc:hooks:plan` and confirm the read-only hook
   redeploy preflight exits with `FAIL=0`; the current expected summary is
   `PASS=28 WARN=1 FAIL=0`.
6. Run `bun run uniswap:official-arc:input:generate` and confirm it exits with
   `FAIL=0`; the current expected summary is `PASS=4 WARN=1 FAIL=0`.
7. Run `bun run uniswap:official-arc:input:generate:self-test` and confirm it
   exits with `FAIL=0`; the current expected summary is `PASS=10 FAIL=0`.
8. Run `bun run uniswap:official-arc:input:check` and confirm the pending input
   template exits with `FAIL=0`; the current expected summary is
   `PASS=11 WARN=1 FAIL=0`.
9. Run `bun run uniswap:official-arc:input:self-test` and confirm it exits with
   `FAIL=0`; the current expected summary is `PASS=8 FAIL=0`.
10. Run `bun run uniswap:official-arc:pools:check` and confirm the pending pool
   publication input exits with `FAIL=0`; the current expected summary is
   `PASS=34 WARN=1 FAIL=0`.
11. Run `bun run uniswap:official-arc:pools:self-test` and confirm it exits with
   `FAIL=0`; the current expected summary is `PASS=12 FAIL=0`.
12. Run `bun run uniswap:official-multichain:docs:check` and confirm it exits
   with `FAIL=0`; the current expected summary is `PASS=31 WARN=2 FAIL=0`.
   Confirm the live official docs still list Avalanche and Arbitrum contracts
   matching the manifest, and still do not list Arc/Fuji unless the manifest
   has been updated.
13. Run `bun run uniswap:official-multichain:docs:self-test` and confirm it
   exits with `FAIL=0`; the current expected summary is `PASS=8 FAIL=0`.
14. Run `bun run uniswap:official-multichain:input:check` and confirm it exits
   with `FAIL=0`; the current expected summary is
   `PASS=75 WARN=2 FAIL=0`.
15. Run `bun run uniswap:official-multichain:input:generate` and confirm it
   exits with `FAIL=0`; the current expected summary is
   `PASS=36 WARN=2 FAIL=0`.
16. Run `bun run uniswap:official-multichain:input:generate:self-test` and
   confirm it exits with `FAIL=0`; the current expected summary is
   `PASS=20 FAIL=0`.
17. Run `bun run uniswap:official-multichain:check` and confirm the
   multichain gate exits with `FAIL=0`; the current expected summary is
   `PASS=289 WARN=4 FAIL=0`.
18. Run `bun run uniswap:official-multichain:hooks:plan` and confirm the
   multichain hook redeploy plan exits with `FAIL=0`; the current expected
   summary is `PASS=50 WARN=4 FAIL=0`.
19. Run `bun run uniswap:official-multichain:hooks:plan:write` and confirm it
   refreshes
   `deployments/uniswap-v4-official-multichain-hooks-redeploy-plan.json`.
20. Run `bun run uniswap:official-multichain:hooks:plan:check` and confirm the
   hook redeploy plan snapshot is fresh with `PASS=50 WARN=4 FAIL=0`.
21. Run `bun run uniswap:official-multichain:pools:check` and confirm the
   multichain pool-publication gate exits with `FAIL=0`; the current expected
   summary is `PASS=68 WARN=4 FAIL=0`.
22. Run `bun run uniswap:official-multichain:pools:plan` and confirm the
   multichain pool-publication fill plan exits with `FAIL=0`; the current
   expected summary is `PASS=81 WARN=4 FAIL=0`.
23. Run `bun run uniswap:official-multichain:pools:plan:write` and confirm it
   refreshes
   `deployments/uniswap-v4-official-multichain-pools-fill-plan.json`.
24. Run `bun run uniswap:official-multichain:pools:plan:check` and confirm the
   fill-plan snapshot is fresh with `PASS=81 WARN=4 FAIL=0`.
25. Run `bun run uniswap:official-multichain:pools:self-test` and confirm it
   exits with `FAIL=0`; the current expected summary is `PASS=15 FAIL=0`.
26. Run `bun run uniswap:official-multichain:stateview:check` and confirm the
   target-chain StateView gate exits with `FAIL=0`; the current expected
   summary is `PASS=29 WARN=4 FAIL=0`.
27. Run `bun run uniswap:official-multichain:subgraph:check` and confirm the
   target-chain subgraph gate exits with `FAIL=0`; the current expected summary
   is `PASS=29 WARN=4 FAIL=0`.
28. Run `bun run uniswap:official-multichain:indexing:self-test` and confirm it
   exits with `FAIL=0`; the current expected summary is `PASS=14 FAIL=0`.
   Confirm draft populated StateView/subgraph evidence passes offline preflight
   only, and malformed liquidity or hook-address evidence is rejected.
29. Run `bun run uniswap:official-multichain:quoter:check` and confirm the
   target-chain Quoter gate exits with `FAIL=0`; the current expected summary is
   `PASS=25 WARN=4 FAIL=0`.
30. Run `bun run uniswap:official-multichain:router:check` and confirm the
   target-chain Universal Router gate exits with `FAIL=0`; the current expected
   summary is `PASS=34 WARN=4 FAIL=0`.
31. Run `bun run uniswap:stateview:check` and confirm the StateView gate exits
   with `FAIL=0`; the current expected summary is `PASS=13 WARN=1 FAIL=0`.
   In live official-Arc mode, rerun it with
   `OFFICIAL_ARC_POOL_PUBLICATION_INPUT=<populated-file>`.
32. Run `bun run uniswap:subgraph:check` and confirm the subgraph gate exits
   with `FAIL=0`; the current expected summary is `PASS=15 WARN=1 FAIL=0`.
   In live official-Arc mode, rerun it with
   `OFFICIAL_ARC_POOL_PUBLICATION_INPUT=<populated-file>`.
33. Run `bun run uniswap:evidence:export` and confirm it emits JSON with
   `pools.length=11`, `network=arc-testnet`, `chainId=5042002`, and
   `officialArcMainnet.status=pending-official-uniswap-v4-addresses`, plus
   `officialArcMainnet.currentDeploymentInputGenerateResult=PASS=4 WARN=1 FAIL=0`,
   `officialArcMainnet.currentDeploymentInputGenerateSelfTestResult=PASS=10 FAIL=0`,
   `officialMultichain.currentResult=PASS=289 WARN=4 FAIL=0`,
   `officialMultichain.hookRedeployPlan.currentResult=PASS=50 WARN=4 FAIL=0`,
   `officialMultichain.hookRedeployPlan.planSnapshot=deployments/uniswap-v4-official-multichain-hooks-redeploy-plan.json`,
   `officialMultichain.deploymentInputGeneration.currentCheckResult=PASS=75 WARN=2 FAIL=0`,
   `officialMultichain.deploymentInputGeneration.currentResult=PASS=36 WARN=2 FAIL=0`,
   `officialMultichain.deploymentInputGeneration.currentSelfTestResult=PASS=20 FAIL=0`,
   `officialMultichain.sourceFreshness.currentResult=PASS=31 WARN=2 FAIL=0`,
   `officialMultichain.sourceFreshness.currentSelfTestResult=PASS=8 FAIL=0`,
   `officialMultichain.poolPublication.currentResult=PASS=68 WARN=4 FAIL=0`,
   `officialMultichain.poolPublication.currentPlanResult=PASS=81 WARN=4 FAIL=0`,
   `officialMultichain.stateViewVerification.currentResult=PASS=29 WARN=4 FAIL=0`,
   `officialMultichain.stateViewVerification.currentSelfTestResult=PASS=14 FAIL=0`,
   `officialMultichain.subgraphVerification.currentResult=PASS=29 WARN=4 FAIL=0`,
   `officialMultichain.subgraphVerification.currentSelfTestResult=PASS=14 FAIL=0`,
   `officialMultichain.quoterVerification.currentResult=PASS=25 WARN=4 FAIL=0`,
   `officialMultichain.routerExecutionVerification.currentResult=PASS=34 WARN=4 FAIL=0`,
   `officialMultichain.quoterVerification.currentSelfTestResult=PASS=21 FAIL=0`,
   `officialMultichain.routerExecutionVerification.currentSelfTestResult=PASS=21 FAIL=0`,
   and
   `officialMultichain.poolPublication.planSnapshot=deployments/uniswap-v4-official-multichain-pools-fill-plan.json`.
34. Run `bun run uniswap:official-multichain:routes:self-test` and confirm it
   exits with `FAIL=0`; the current expected summary is `PASS=21 FAIL=0`.
35. Run `bun run uniswap:evidence:write` and confirm it refreshes
   `deployments/uniswap-v4-indexing-evidence-5042002.json` with the same
   11-pool snapshot.
36. Run `bun run uniswap:evidence:check` and confirm the snapshot is fresh.
37. Run `bun run uniswap:hook-metadata:export` and confirm it emits JSON with
   `summary.publishedArcTestnetPoolCount=11`,
   `summary.officialMultichainTargetCount=4`,
   `officialIndexingCaveat.selfDeployedArcTestnetIsOfficial=false`, and
   hook family metadata for `FxHedgeHook`, `FxSwapHook`,
   `TelaranaGatewayHubHook`, and `FxGhostKycHook`. Confirm
   `officialMultichainTargets` keeps Arc mainnet and Avalanche Fuji pending,
   and carries Avalanche plus Arbitrum One official `PoolManager`, `Quoter`, and
   `StateView` addresses.
38. Run `bun run uniswap:hook-metadata:write` and confirm it refreshes
   `deployments/uniswap-v4-hook-indexer-metadata-5042002.json`.
39. Run `bun run uniswap:hook-metadata:self-test` and confirm it exits with
   `FAIL=0`; the current expected summary is `PASS=13 FAIL=0`.
40. Run `bun run uniswap:hook-metadata:check` and confirm the hook metadata
   snapshot is fresh.
41. Run `bun run uniswap:requirements:export` and confirm it emits the
   requirement-by-requirement matrix with the current expected summary
   `PASS=13 WARN=9 FAIL=0`.
42. Run `bun run uniswap:requirements:write` and confirm it refreshes
   `deployments/uniswap-v4-indexing-requirements-5042002.json`.
43. Run `bun run uniswap:requirements:check` and confirm the requirements
   snapshot is fresh.
44. Run `bun run uniswap:handoff:render` and confirm it emits Markdown with
   all 11 pool records, `officialMultichain` target status, reviewer commands,
   and do-not-claim caveats; the current expected summary is
   `PASS=9 WARN=4 FAIL=0`.
45. Run `bun run uniswap:handoff:write` and confirm it refreshes
   `deployments/uniswap-v4-indexing-handoff-5042002.md`.
46. Run `bun run uniswap:handoff:check` and confirm the handoff snapshot is
   fresh.
47. Run `bun run uniswap:hook-permissions` and confirm the focused Foundry
   diagnostic reports `4 tests passed, 0 failed`.
48. Run `bun run uniswap:completion:audit` and confirm the original-goal
   completion audit exits with `FAIL=0`, reports `completionStatus
   not-complete`, and has the current expected summary
   `PASS=28 WARN=6 FAIL=0`.
49. Run `bun run uniswap:submission:audit` and confirm the executable
   submission audit exits with `FAIL=0`; the current expected summary is
   `CHECKS=43 PASS=43 WARN=88 FAIL=0`.
50. Run `bun run hedge:arc:plan-stables` and confirm all six hedge pools are
   live/configured; the current expected summary is `PASS=46 WARN=0 FAIL=0`.
51. Run `bun run uniswap:hedge:liquidity` and confirm it reports zero liquidity
   as warnings, not failures; current expected summary is
   `PASS=1 WARN=13 FAIL=0`.
52. Run `bun run uniswap:hedge:liquidity:plan` and confirm it reports
   `PASS=32 WARN=1 FAIL=0` and prints all six operator env groups.
53. Run `bun run uniswap:hedge:v4quoter` and confirm the local diagnostic passes
   `2 passed; 0 failed`.
54. Run `bun run uniswap:fxswap:v4quoter` and confirm the local diagnostic passes
   `3 passed; 0 failed`.
55. Run `bun run uniswap:indexing:onchain` and confirm live init/configure tx
   receipts verify against Arc RPC; the current expected summary is
   `PASS=142 WARN=0 FAIL=0`.
56. Confirm expected readiness warnings are limited to official Arc addresses,
   official Fuji addresses, Avalanche/Arbitrum hook pool publication evidence,
   official hook redeploy PoolManager availability, official pool publication,
   StateView/subgraph/pool IDs, and FxHedgeHook first liquidity pending.
   `FxSwapHook` generic `V4Quoter` is no longer an untested pending harness; it
   has a local negative diagnostic.
57. From the app repo, run `bun run --filter @bufi/hyper-mcp typecheck`.
58. From the app repo, run
    `bun test apps/hyper-mcp/test/app.test.ts -t "GET /api/hedge/pools surfaces deployed hedge pools"`
   and confirm `/api/hedge/pools` reports `liveCount=6`, `pendingCount=0`,
   and no zero placeholder pool IDs.
59. Confirm `apps/hyper-mcp/src/routes/hedge.ts` in the app branch treats
    FxHedgeHook and FxSwapHook as separate v4 pool surfaces.
60. Confirm no ops, surveillance, or unrelated monitoring surfaces were added.
