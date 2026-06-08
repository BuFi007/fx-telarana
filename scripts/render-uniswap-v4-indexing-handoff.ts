// SPDX-License-Identifier: AGPL-3.0-only
//
// Renders the machine-readable Uniswap v4 indexing evidence into a deterministic
// Markdown packet for reviewer/indexer handoff. This is deliberately read-only:
// it does not deploy, schedule, monitor, or broadcast anything.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

type AnyRecord = Record<string, any>;

const ROOT = resolve(import.meta.dir, "..");
const EVIDENCE = "deployments/uniswap-v4-indexing-evidence-5042002.json";
const MULTICHAIN = "deployments/uniswap-v4-official-multichain-readiness.json";

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

function tableCell(value: unknown): string {
  if (value == null || value === "") return "pending";
  return String(value).replaceAll("|", "\\|").replaceAll("\n", " ");
}

function poolStatus(pool: AnyRecord): string {
  return pool.status ?? pool.liquidityReadiness?.status ?? "published-testnet-pool";
}

function routerStatus(pool: AnyRecord): string {
  const status = pool.routerQuoterStatus ?? {};
  if (typeof status.genericV4Quoter === "string") return status.genericV4Quoter;
  if (typeof status.exactInput === "string") return status.exactInput;
  return "documented-custom-route";
}

function contractSummary(contracts: AnyRecord | undefined): string {
  if (!contracts) return "pending";
  const poolManager = contracts.PoolManager ?? "pending";
  const quoter = contracts.Quoter ?? "pending";
  const stateView = contracts.StateView ?? "pending";
  return `PoolManager ${poolManager}; Quoter ${quoter}; StateView ${stateView}`;
}

function renderTargetRows(targets: AnyRecord[]): string[] {
  return [
    "| Network | Chain | Official status | Indexing readiness | Contracts |",
    "| --- | ---: | --- | --- | --- |",
    ...targets.map((target) => [
      target.displayName ?? target.network,
      target.chainId ?? "pending",
      target.status,
      target.indexingReadiness,
      contractSummary(target.contracts),
    ].map(tableCell).join(" | ")).map((row) => `| ${row} |`),
  ];
}

function renderPoolRows(pools: AnyRecord[]): string[] {
  return [
    "| Family | Pair | Status | PoolManager | Hook | PoolId | Initialize tx | Router/Quoter evidence |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ...pools.map((pool) => [
      pool.family,
      pool.symbol,
      poolStatus(pool),
      pool.poolManager,
      pool.poolKey?.hooks,
      pool.poolId,
      pool.initializeTx,
      routerStatus(pool),
    ].map(tableCell).join(" | ")).map((row) => `| ${row} |`),
  ];
}

function renderCommands(commands: AnyRecord, submission: AnyRecord): string[] {
  const ordered = [
    ["Official docs freshness", commands.officialMultichainDocsFreshness],
    ["Readiness aggregate", commands.offlineReadiness],
    ["Arc official deployment input", commands.officialArcDeploymentInputCheck],
    ["Arc pool publication fill plan", commands.officialArcPoolPublicationPlan],
    ["StateView gate", commands.officialArcStateViewReadiness],
    ["Subgraph gate", commands.subgraphReadiness],
    ["Multichain StateView gate", commands.officialMultichainStateViewReadiness],
    ["Multichain subgraph gate", commands.officialMultichainSubgraphReadiness],
    ["Multichain indexed-state self-test", commands.officialMultichainIndexingReadinessSelfTest],
    ["Multichain Quoter gate", commands.officialMultichainQuoterReadiness],
    ["Multichain router gate", commands.officialMultichainRouterReadiness],
    ["Multichain route self-test", commands.officialMultichainRouteReadinessSelfTest],
    ["Evidence snapshot freshness", commands.submissionEvidenceFreshness],
    ["Requirements matrix", submission.requirementsMatrixCheckCommand ?? commands.requirementsFreshness],
    ["Submission audit", submission.indexingSubmissionAuditCommand ?? commands.submissionAudit],
    ["Completion audit", submission.completionAuditCommand ?? commands.completionAudit],
  ];

  return [
    "| Purpose | Command |",
    "| --- | --- |",
    ...ordered.map(([label, command]) => `| ${tableCell(label)} | \`${tableCell(command)}\` |`),
  ];
}

function renderList(values: unknown[]): string[] {
  return values.map((value) => `- ${tableCell(value)}`);
}

function buildMarkdown(evidence: AnyRecord, multichain: AnyRecord): string {
  const pools = evidence.pools ?? [];
  const targets = multichain.targets ?? [];
  const commands = evidence.evidenceCommands ?? {};
  const submission = evidence.submissionPackage ?? {};
  const doNotClaim = submission.doNotClaimYet ?? [];

  const lines = [
    "# Uniswap v4 Indexing Handoff",
    "",
    `Generated from: \`${EVIDENCE}\``,
    `Generated at: \`${evidence.generatedAt ?? "unknown"}\``,
    `Network: \`${evidence.network}\``,
    `Chain ID: \`${evidence.chainId}\``,
    `Completion status: \`${submission.completionStatus ?? "not-complete"}\``,
    `Official Uniswap deployments source: ${evidence.officialUniswapReferences?.deployments ?? multichain.source}`,
    "",
    "## Current Conclusion",
    "",
    "Arc testnet is demoable on self-deployed Uniswap v4 infrastructure, with 11 published pool records across FxHedgeHook, FxSwapHook, and TelaranaGatewayHubHook. Official Arc mainnet indexing remains externally pending until Uniswap publishes Arc v4 contracts. Avalanche C-Chain and Arbitrum One official v4 contracts are tracked, but chain-specific hook redeploy, PoolManager initialization, first liquidity, StateView, subgraph, and Quoter/custom-route evidence are still required before claiming indexed hook pools there.",
    "",
    "## Official Multichain Status",
    "",
    ...renderTargetRows(targets),
    "",
    "## Arc Testnet Pool Evidence",
    "",
    ...renderPoolRows(pools),
    "",
    "## Reviewer Commands",
    "",
    ...renderCommands(commands, submission),
    "",
    "## Do Not Claim Yet",
    "",
    ...renderList(doNotClaim),
    "",
    "## No Ops Or Surveillance Additions",
    "",
    "This packet is a static generated reviewer artifact. It does not add cron jobs, monitors, daemons, alerts, wallet surveillance, or unrelated operational surfaces.",
    "",
  ];

  return `${lines.join("\n")}`;
}

function validate(evidence: AnyRecord, multichain: AnyRecord): { pass: number; warn: number; fail: number } {
  let pass = 0;
  let warn = 0;
  let fail = 0;

  function check(condition: boolean, warning = false): void {
    if (condition) {
      if (warning) warn += 1;
      else pass += 1;
      return;
    }
    fail += 1;
  }

  const pools = evidence.pools ?? [];
  const targets = multichain.targets ?? [];
  const targetByNetwork = new Map(targets.map((target: AnyRecord) => [target.network, target]));

  check(evidence.schemaVersion === 1);
  check(evidence.network === "arc-testnet");
  check(evidence.chainId === 5_042_002);
  check(pools.length === 11);
  check(evidence.officialArcMainnet?.status === "pending-official-uniswap-v4-addresses", true);
  check(targets.length === 4);
  check(targetByNetwork.get("arc-mainnet")?.status === "pending-official-uniswap-v4-addresses", true);
  check(targetByNetwork.get("avalanche-fuji")?.status === "pending-official-uniswap-v4-addresses", true);
  check(targetByNetwork.get("avalanche")?.status === "official-uniswap-v4-addresses-published");
  check(targetByNetwork.get("arbitrum-one")?.status === "official-uniswap-v4-addresses-published");
  check(typeof evidence.evidenceCommands?.submissionAudit === "string");
  check(typeof evidence.submissionPackage?.currentSubmissionAuditResult === "string");
  check(
    pools.some((pool: AnyRecord) => pool.liquidityReadiness?.status === "pending-first-liquidity"),
    true,
  );

  return { pass, warn, fail };
}

function main(): void {
  const outPath = repoRelativePathFor("--out");
  const checkPath = repoRelativePathFor("--check");
  if (outPath && checkPath) throw new Error("use either --out or --check, not both");

  const evidence = readJson(EVIDENCE);
  const multichain = readJson(MULTICHAIN);
  const markdown = buildMarkdown(evidence, multichain);
  const result = validate(evidence, multichain);
  const summary = `summary PASS=${result.pass} WARN=${result.warn} FAIL=${result.fail}`;

  if (outPath) {
    const absoluteOutPath = join(ROOT, outPath);
    mkdirSync(dirname(absoluteOutPath), { recursive: true });
    writeFileSync(absoluteOutPath, markdown);
    console.log(`wrote ${outPath}`);
    console.log(summary);
    process.exit(result.fail > 0 ? 1 : 0);
  }

  if (checkPath) {
    const current = readFileSync(join(ROOT, checkPath), "utf-8");
    if (current !== markdown) {
      throw new Error(`${checkPath} is stale; run bun run uniswap:handoff:write`);
    }

    console.log(`${checkPath} is fresh`);
    console.log(summary);
    process.exit(result.fail > 0 ? 1 : 0);
  }

  console.log(markdown.trimEnd());
  console.log("");
  console.log(summary);
  process.exit(result.fail > 0 ? 1 : 0);
}

main();
