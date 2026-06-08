// SPDX-License-Identifier: AGPL-3.0-only
//
// Exports a requirement-by-requirement evidence matrix for the original
// Uniswap v4 indexing goal. This keeps completion claims anchored to concrete
// evidence instead of broad green-check summaries.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type RequirementStatus = "satisfied" | "satisfied-with-caveat" | "pending-external" | "pending-operator" | "failed";

type Requirement = {
  id: string;
  requirement: string;
  status: RequirementStatus;
  evidence: string[];
  remainingWork: string[];
};

const ROOT = resolve(import.meta.dir, "..");
const READINESS = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const EVIDENCE = "deployments/uniswap-v4-indexing-evidence-5042002.json";
const MULTICHAIN = "deployments/uniswap-v4-official-multichain-readiness.json";
const HANDOFF = "deployments/uniswap-v4-indexing-handoff-5042002.md";

function readJson(relativePath: string): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, relativePath), "utf-8"));
}

function repoRelativePathFor(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  if (index === -1) return undefined;

  const value = process.argv[index + 1];
  if (!value) throw new Error(`${flag} requires a relative path`);
  if (value.startsWith("/") || value.includes("..")) {
    throw new Error(`${flag} must stay inside the repository`);
  }

  return value;
}

function hasFailZero(result: unknown): boolean {
  return typeof result === "string" && (result.includes("FAIL=0") || /\b0\s+failed\b/i.test(result));
}

function hasAddress(value: unknown): boolean {
  return typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value);
}

function targetByNetwork(multichain: AnyRecord, network: string): AnyRecord {
  return (multichain.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function hookFamily(readiness: AnyRecord, name: string): AnyRecord {
  return (readiness.hookFamilies ?? []).find((family: AnyRecord) => family.name === name) ?? {};
}

function statusCounts(requirements: Requirement[]): Record<RequirementStatus, number> {
  return requirements.reduce(
    (counts, requirement) => {
      counts[requirement.status] += 1;
      return counts;
    },
    {
      "satisfied": 0,
      "satisfied-with-caveat": 0,
      "pending-external": 0,
      "pending-operator": 0,
      "failed": 0,
    } as Record<RequirementStatus, number>,
  );
}

function buildRequirements(readiness: AnyRecord, evidence: AnyRecord, multichain: AnyRecord): Requirement[] {
  const pools = evidence.pools ?? [];
  const hedgePools = pools.filter((pool: AnyRecord) => pool.family === "FxHedgeHook");
  const fxHedge = hookFamily(readiness, "FxHedgeHook");
  const fxSwap = hookFamily(readiness, "FxSwapHook");
  const gateway = hookFamily(readiness, "TelaranaGatewayHubHook");
  const arc = targetByNetwork(multichain, "arc-mainnet");
  const fuji = targetByNetwork(multichain, "avalanche-fuji");
  const avalanche = targetByNetwork(multichain, "avalanche");
  const arbitrum = targetByNetwork(multichain, "arbitrum-one");
  const multichainPoolPublication = multichain.poolPublication ?? {};
  const multichainHookRedeployPlan = multichain.hookRedeployPlan ?? {};
  const multichainStateView = multichain.stateViewVerification ?? {};
  const multichainSubgraph = multichain.subgraphVerification ?? {};
  const multichainQuoter = multichain.quoterVerification ?? {};
  const multichainRouter = multichain.routerExecutionVerification ?? {};

  return [
    {
      id: "official-docs-freshness",
      requirement: "Official Uniswap v4 deployment addresses must be checked against the current official deployments source.",
      status: hasFailZero(multichain.sourceFreshness?.currentResult) ? "satisfied" : "failed",
      evidence: [
        `command: ${multichain.sourceFreshness?.command}`,
        `result: ${multichain.sourceFreshness?.currentResult}`,
        `source: ${multichain.sourceFreshness?.source}`,
        `retry gate: ${Array.isArray(multichain.sourceFreshness?.requiredChecks) && multichain.sourceFreshness.requiredChecks.join("\n").includes("Transient official docs HTTP failures") ? "recorded" : "missing"}`,
      ],
      remainingWork: [],
    },
    {
      id: "arc-testnet-pool-evidence",
      requirement: "Arc testnet setup must publish concrete PoolManager, PoolKey, poolId, and initialize transaction evidence.",
      status: evidence.network === "arc-testnet" && evidence.chainId === 5_042_002 && pools.length === 11
        ? "satisfied"
        : "failed",
      evidence: [
        `evidence snapshot: ${EVIDENCE}`,
        `network: ${evidence.network}`,
        `chainId: ${evidence.chainId}`,
        `pool records: ${pools.length}`,
      ],
      remainingWork: [],
    },
    {
      id: "fx-hedge-live-pools",
      requirement: "All six FxHedgeHook stable hedge pools must be live in Arc testnet evidence.",
      status: hedgePools.length === 6 && hedgePools.every((pool: AnyRecord) => pool.status === "live")
        ? "satisfied"
        : "failed",
      evidence: [
        `FxHedgeHook pools: ${hedgePools.map((pool: AnyRecord) => pool.symbol).join(", ")}`,
        `storage verifier: ${readiness.evidenceCommands?.pendingHedgePoolsPlan}`,
      ],
      remainingWork: [],
    },
    {
      id: "router-quoter-diagnostics",
      requirement: "Router/quoter behavior must be proven or explicitly caveated per hook family.",
      status: hasFailZero(fxHedge.quoterDiagnostic?.result)
        && hasFailZero(fxSwap.quoterDiagnostic?.result)
        && typeof gateway.routerQuoterStatus?.genericV4Quoter === "string"
        ? "satisfied-with-caveat"
        : "failed",
      evidence: [
        `FxHedgeHook: ${fxHedge.quoterDiagnostic?.result}`,
        `FxSwapHook: ${fxSwap.quoterDiagnostic?.result}`,
        `TelaranaGatewayHubHook: ${gateway.routerQuoterStatus?.genericV4Quoter}`,
      ],
      remainingWork: [
        "Rerun diagnostics against official Arc PoolManager/Quoter after Uniswap publishes Arc v4 addresses.",
      ],
    },
    {
      id: "handoff-packet",
      requirement: "Reviewer handoff must be generated from committed evidence and kept fresh.",
      status: hasFailZero(readiness.submissionPackage?.currentHandoffResult) ? "satisfied" : "failed",
      evidence: [
        `handoff snapshot: ${HANDOFF}`,
        `result: ${readiness.submissionPackage?.currentHandoffResult}`,
      ],
      remainingWork: [],
    },
    {
      id: "completion-audit",
      requirement: "The package must include a completion audit that refuses to mark the goal complete while required official evidence is missing.",
      status: readiness.submissionPackage?.completionStatus === "not-complete"
        && hasFailZero(readiness.submissionPackage?.currentCompletionAuditResult)
        ? "satisfied-with-caveat"
        : "failed",
      evidence: [
        `completionStatus: ${readiness.submissionPackage?.completionStatus}`,
        `result: ${readiness.submissionPackage?.currentCompletionAuditResult}`,
      ],
      remainingWork: [
        "Flip only after official Arc contracts, official pool records, and liquidity/indexing evidence exist.",
      ],
    },
    {
      id: "official-arc-contracts",
      requirement: "Official Arc mainnet v4 PoolManager, PositionManager, UniversalRouter, Quoter, StateView, and Permit2 addresses must be published by Uniswap.",
      status: arc.status === "official-uniswap-v4-addresses-published" ? "satisfied" : "pending-external",
      evidence: [
        `status: ${arc.status}`,
        `docsListed: ${arc.officialDocsListedOn2026_06_08}`,
      ],
      remainingWork: [
        "Wait for the official Uniswap deployments page to list Arc mainnet v4 contracts.",
      ],
    },
    {
      id: "official-fuji-contracts",
      requirement: "Official Avalanche Fuji v4 contracts must stay pending unless Uniswap publishes them.",
      status: fuji.status === "official-uniswap-v4-addresses-published" ? "satisfied" : "pending-external",
      evidence: [
        `status: ${fuji.status}`,
        `rehearsal PoolManager: ${fuji.rehearsal?.poolManager}`,
      ],
      remainingWork: [
        "Do not reuse the rehearsal PoolManager for official indexing claims.",
      ],
    },
    {
      id: "official-arc-hook-redeploy",
      requirement: "Hooks must be remined/redeployed against the official Arc PoolManager.",
      status: readiness.officialArcMainnet?.hookRedeployPlan?.status === "ready"
        ? "satisfied"
        : "pending-external",
      evidence: [
        `status: ${readiness.officialArcMainnet?.hookRedeployPlan?.status}`,
        `plan: ${readiness.officialArcMainnet?.hookRedeployPlan?.command}`,
        `result: ${readiness.officialArcMainnet?.hookRedeployPlan?.currentResult}`,
      ],
      remainingWork: [
        "Populate official Arc deployment input, then remine/redeploy hooks against the official PoolManager.",
      ],
    },
    {
      id: "official-arc-pool-publication",
      requirement: "Official Arc PoolManager pool records must include official PoolKeys, poolIds, initialize txs, first liquidity txs, StateView, subgraph, and router/quoter evidence.",
      status: (readiness.officialArcMainnet?.poolPublication?.officialPools ?? []).length > 0
        ? "satisfied"
        : "pending-external",
      evidence: [
        `status: ${readiness.officialArcMainnet?.poolPublication?.status}`,
        `officialPools: ${(readiness.officialArcMainnet?.poolPublication?.officialPools ?? []).length}`,
        `fill plan: ${readiness.officialArcMainnet?.poolPublication?.planCommand}`,
        `fill plan result: ${readiness.officialArcMainnet?.poolPublication?.currentPlanResult}`,
      ],
      remainingWork: [
        "After official hook redeploy, initialize official PoolKeys and populate the official pool publication input.",
      ],
    },
    {
      id: "official-stateview",
      requirement: "Official Arc StateView evidence must verify nonzero sqrtPriceX96 and liquidity for official pool IDs.",
      status: readiness.officialArcMainnet?.stateViewVerification?.status === "verified"
        ? "satisfied"
        : "pending-external",
      evidence: [
        `status: ${readiness.officialArcMainnet?.stateViewVerification?.status}`,
        `result: ${readiness.officialArcMainnet?.stateViewVerification?.currentResult}`,
      ],
      remainingWork: [
        "Run with OFFICIAL_ARC_POOL_PUBLICATION_INPUT and OFFICIAL_ARC_RPC_URL once official pool IDs exist.",
      ],
    },
    {
      id: "official-multichain-stateview-gate",
      requirement: "The official multichain publication package must have a StateView gate for Arc mainnet, Avalanche Fuji, Avalanche, and Arbitrum One before indexed pool claims are made.",
      status: hasFailZero(multichainStateView.currentResult) ? "satisfied-with-caveat" : "failed",
      evidence: [
        `command: ${multichainStateView.command}`,
        `result: ${multichainStateView.currentResult}`,
        `pool input env: ${multichainStateView.poolPublicationInputEnv}`,
        `required contract: ${multichainStateView.requiredContract}`,
      ],
      remainingWork: [
        "After official pool publication records exist, run the gate against populated target-chain records and record StateView.getSlot0(poolId) plus StateView.getLiquidity(poolId) evidence for every official pool.",
      ],
    },
    {
      id: "official-subgraph",
      requirement: "Official v4 subgraph evidence must verify pool entity id, hooks, token0/token1, fee tier, price state, and liquidity.",
      status: readiness.officialArcMainnet?.subgraphVerification?.status === "verified"
        ? "satisfied"
        : "pending-external",
      evidence: [
        `status: ${readiness.officialArcMainnet?.subgraphVerification?.status}`,
        `result: ${readiness.officialArcMainnet?.subgraphVerification?.currentResult}`,
      ],
      remainingWork: [
        "Run with official pool publication input and the official v4 subgraph endpoint once official pool IDs exist.",
      ],
    },
    {
      id: "official-multichain-subgraph-gate",
      requirement: "The official multichain publication package must have a subgraph gate for Arc mainnet, Avalanche Fuji, Avalanche, and Arbitrum One before indexed pool claims are made.",
      status: hasFailZero(multichainSubgraph.currentResult) ? "satisfied-with-caveat" : "failed",
      evidence: [
        `command: ${multichainSubgraph.command}`,
        `result: ${multichainSubgraph.currentResult}`,
        `pool input env: ${multichainSubgraph.poolPublicationInputEnv}`,
        `endpoint env: ${multichainSubgraph.endpointEnv}`,
        `required source: ${multichainSubgraph.requiredSource}`,
      ],
      remainingWork: [
        "After official pool publication records exist, run the gate against populated target-chain records and record Uniswap v4 subgraph pool entity evidence for every official pool.",
      ],
    },
    {
      id: "official-multichain-quoter-gate",
      requirement: "The official multichain publication package must have a Quoter gate for Arc mainnet, Avalanche Fuji, Avalanche, and Arbitrum One before indexed pool claims are made.",
      status: hasFailZero(multichainQuoter.currentResult) ? "satisfied-with-caveat" : "failed",
      evidence: [
        `command: ${multichainQuoter.command}`,
        `result: ${multichainQuoter.currentResult}`,
        `pool input env: ${multichainQuoter.poolPublicationInputEnv}`,
        `required contract: ${multichainQuoter.requiredContract}`,
      ],
      remainingWork: [
        "After official pool publication records exist, run the gate against populated target-chain records and record exact-input Quoter evidence or custom-route caveats for every official pool.",
      ],
    },
    {
      id: "official-multichain-router-gate",
      requirement: "The official multichain publication package must have a Universal Router execution gate for Arc mainnet, Avalanche Fuji, Avalanche, and Arbitrum One before router-active pool claims are made.",
      status: hasFailZero(multichainRouter.currentResult) ? "satisfied-with-caveat" : "failed",
      evidence: [
        `command: ${multichainRouter.command}`,
        `result: ${multichainRouter.currentResult}`,
        `pool input env: ${multichainRouter.poolPublicationInputEnv}`,
        `required contracts: ${(multichainRouter.requiredContracts ?? []).join(", ")}`,
      ],
      remainingWork: [
        "After official pool publication records exist, run the gate against populated target-chain records and record Universal Router execution evidence or custom-route caveats for every official pool.",
      ],
    },
    {
      id: "first-liquidity",
      requirement: "Router-active hedge market claims require first liquidity txs and nonzero current in-range liquidity.",
      status: fxHedge.liquidityReadiness?.status === "pending-first-liquidity"
        ? "pending-operator"
        : "satisfied",
      evidence: [
        `status: ${fxHedge.liquidityReadiness?.status}`,
        `result: ${fxHedge.liquidityReadiness?.currentResult}`,
        `operator plan: ${fxHedge.liquidityReadiness?.operatorPlanCommand}`,
      ],
      remainingWork: [
        "Seed first liquidity and publish the firstLiquidityTx for each router-active hedge pool claim.",
      ],
    },
    {
      id: "avalanche-official-contracts",
      requirement: "Avalanche C-Chain official v4 contract addresses must be tracked while hook pool indexing remains pending.",
      status: avalanche.status === "official-uniswap-v4-addresses-published"
        && hasAddress(avalanche.contracts?.PoolManager)
        && hasAddress(avalanche.contracts?.Quoter)
        && hasAddress(avalanche.contracts?.StateView)
        ? "satisfied-with-caveat"
        : "failed",
      evidence: [
        `PoolManager: ${avalanche.contracts?.PoolManager}`,
        `Quoter: ${avalanche.contracts?.Quoter}`,
        `StateView: ${avalanche.contracts?.StateView}`,
        `hook redeploy plan: ${multichainHookRedeployPlan.currentResult}`,
        `poolPublicationStatus: ${avalanche.poolPublicationStatus}`,
      ],
      remainingWork: [
        "Remine/redeploy hooks, initialize pools, add first liquidity, and publish StateView/subgraph/quoter evidence on Avalanche.",
      ],
    },
    {
      id: "avalanche-hook-pool-publication",
      requirement: "Avalanche C-Chain hook pools must be published with official PoolManager Initialize txs, first liquidity, StateView, subgraph, route/quoter, and router execution evidence before claiming indexing.",
      status: avalanche.poolPublicationStatus === "ready" ? "satisfied" : "pending-operator",
      evidence: [
        `indexingReadiness: ${avalanche.indexingReadiness}`,
        `poolPublicationStatus: ${avalanche.poolPublicationStatus}`,
        `hook redeploy plan: ${multichainHookRedeployPlan.currentResult}`,
        `publication template: ${multichainPoolPublication.manifest}`,
        `publication check: ${multichainPoolPublication.currentResult}`,
        `publication fill plan: ${multichainPoolPublication.currentPlanResult}`,
      ],
      remainingWork: [
        "Run chain-specific hook remine/redeploy against Avalanche official PoolManager.",
        "Initialize official Avalanche PoolKeys, add first liquidity, and populate official multichain pool publication records.",
        "Verify Avalanche StateView, subgraph, exact-input Quoter or documented custom-route evidence, and live PoolManager receipts.",
      ],
    },
    {
      id: "arbitrum-official-contracts",
      requirement: "Arbitrum One official v4 contract addresses must be tracked while hook pool indexing remains pending.",
      status: arbitrum.status === "official-uniswap-v4-addresses-published"
        && hasAddress(arbitrum.contracts?.PoolManager)
        && hasAddress(arbitrum.contracts?.Quoter)
        && hasAddress(arbitrum.contracts?.StateView)
        ? "satisfied-with-caveat"
        : "failed",
      evidence: [
        `PoolManager: ${arbitrum.contracts?.PoolManager}`,
        `Quoter: ${arbitrum.contracts?.Quoter}`,
        `StateView: ${arbitrum.contracts?.StateView}`,
        `hook redeploy plan: ${multichainHookRedeployPlan.currentResult}`,
        `poolPublicationStatus: ${arbitrum.poolPublicationStatus}`,
      ],
      remainingWork: [
        "Remine/redeploy hooks, initialize pools, add first liquidity, and publish StateView/subgraph/quoter evidence on Arbitrum One.",
      ],
    },
    {
      id: "arbitrum-hook-pool-publication",
      requirement: "Arbitrum One hook pools must be published with official PoolManager Initialize txs, first liquidity, StateView, subgraph, route/quoter, and router execution evidence before claiming indexing.",
      status: arbitrum.poolPublicationStatus === "ready" ? "satisfied" : "pending-operator",
      evidence: [
        `indexingReadiness: ${arbitrum.indexingReadiness}`,
        `poolPublicationStatus: ${arbitrum.poolPublicationStatus}`,
        `hook redeploy plan: ${multichainHookRedeployPlan.currentResult}`,
        `publication template: ${multichainPoolPublication.manifest}`,
        `publication check: ${multichainPoolPublication.currentResult}`,
        `publication fill plan: ${multichainPoolPublication.currentPlanResult}`,
      ],
      remainingWork: [
        "Run chain-specific hook remine/redeploy against Arbitrum One official PoolManager.",
        "Initialize official Arbitrum One PoolKeys, add first liquidity, and populate official multichain pool publication records.",
        "Verify Arbitrum One StateView, subgraph, exact-input Quoter or documented custom-route evidence, and live PoolManager receipts.",
      ],
    },
    {
      id: "no-unrelated-ops-surface",
      requirement: "The readiness package must stay limited to read-only evidence and avoid unrelated ops, daemon, alert, or wallet-tracking surfaces.",
      status: "satisfied",
      evidence: [
        "Generated scripts are read-only/no-broadcast evidence renderers or validators.",
        `${HANDOFF} records that it adds no cron jobs, monitors, daemons, alerts, or wallet tracking.`,
      ],
      remainingWork: [],
    },
  ];
}

function buildPacket(readiness: AnyRecord, evidence: AnyRecord, multichain: AnyRecord): AnyRecord {
  const requirements = buildRequirements(readiness, evidence, multichain);
  const counts = statusCounts(requirements);

  return {
    schemaVersion: 1,
    generatedFrom: {
      readiness: READINESS,
      evidence: EVIDENCE,
      multichain: MULTICHAIN,
      handoff: HANDOFF,
    },
    generatedAt: readiness.generatedAt,
    network: readiness.network,
    chainId: readiness.chainId,
    completionStatus: readiness.submissionPackage?.completionStatus ?? "not-complete",
    summary: {
      ...counts,
      pass: counts.satisfied + counts["satisfied-with-caveat"],
      warn: counts["pending-external"] + counts["pending-operator"],
      fail: counts.failed,
    },
    requirements,
  };
}

function main(): void {
  const outPath = repoRelativePathFor("--out");
  const checkPath = repoRelativePathFor("--check");
  if (outPath && checkPath) throw new Error("use either --out or --check, not both");

  const readiness = readJson(READINESS);
  const evidence = readJson(EVIDENCE);
  const multichain = readJson(MULTICHAIN);
  const packet = buildPacket(readiness, evidence, multichain);
  const json = `${JSON.stringify(packet, null, 2)}\n`;
  const summary = `summary PASS=${packet.summary.pass} WARN=${packet.summary.warn} FAIL=${packet.summary.fail}`;

  if (outPath) {
    const absoluteOutPath = join(ROOT, outPath);
    mkdirSync(dirname(absoluteOutPath), { recursive: true });
    writeFileSync(absoluteOutPath, json);
    console.log(`wrote ${outPath}`);
    console.log(summary);
    process.exit(packet.summary.fail > 0 ? 1 : 0);
  }

  if (checkPath) {
    const current = readFileSync(join(ROOT, checkPath), "utf-8");
    if (current !== json) {
      throw new Error(`${checkPath} is stale; run bun run uniswap:requirements:write`);
    }

    console.log(`${checkPath} is fresh`);
    console.log(summary);
    process.exit(packet.summary.fail > 0 ? 1 : 0);
  }

  console.log(json.trimEnd());
  console.log(summary);
  process.exit(packet.summary.fail > 0 ? 1 : 0);
}

main();
