// SPDX-License-Identifier: AGPL-3.0-only
//
// Regression self-test for the official multichain deployment input generator.
// It proves that current official docs shape keeps Arc/Fuji pending, future docs
// shape can populate every target, and self-deployed PoolManager reuse fails.

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const TEMP_CURRENT_DOCS = "deployments/.tmp-official-multichain-generator-current.self-test.md";
const TEMP_ALL_DOCS = "deployments/.tmp-official-multichain-generator-all.self-test.md";
const TEMP_BAD_DOCS = "deployments/.tmp-official-multichain-generator-bad.self-test.md";
const TEMP_CURRENT_OUTPUT = "deployments/.tmp-official-multichain-generated-current.self-test.json";
const TEMP_ALL_OUTPUT = "deployments/.tmp-official-multichain-generated-all.self-test.json";
const TEMP_BAD_OUTPUT = "deployments/.tmp-official-multichain-generated-bad.self-test.json";
const TEMP_BAD_CHECKER_INPUT = "deployments/.tmp-official-multichain-checker-bad.self-test.json";
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

const counts: Record<Severity, number> = { PASS: 0, FAIL: 0 };

const poolManagers = {
  arc: "0x1111111111111111111111111111111111111111",
  fuji: "0x2222222222222222222222222222222222222222",
  avalanche: "0x3333333333333333333333333333333333333333",
  arbitrum: "0x4444444444444444444444444444444444444444",
};

function record(severity: Severity, message: string): void {
  counts[severity] += 1;
  console.log(`${severity.padEnd(4)} ${message}`);
}

function pass(message: string): void {
  record("PASS", message);
}

function fail(message: string): void {
  record("FAIL", message);
}

function readJson(relativePath: string): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, relativePath), "utf-8"));
}

function writeFile(relativePath: string, value: string): void {
  writeFileSync(join(ROOT, relativePath), value);
}

function cleanup(): void {
  for (const relativePath of [
    TEMP_CURRENT_DOCS,
    TEMP_ALL_DOCS,
    TEMP_BAD_DOCS,
    TEMP_CURRENT_OUTPUT,
    TEMP_ALL_OUTPUT,
    TEMP_BAD_OUTPUT,
    TEMP_BAD_CHECKER_INPUT,
  ]) {
    const absolutePath = join(ROOT, relativePath);
    if (existsSync(absolutePath)) rmSync(absolutePath);
  }
}

function firstSelfDeployedPoolManager(manifest: AnyRecord): string {
  const arc = manifest.selfDeployedPoolManagers?.arcTestnet?.find((address: unknown) => typeof address === "string");
  if (arc) return arc;

  const fuji = manifest.selfDeployedPoolManagers?.avalancheFujiRehearsalPoolManager;
  if (typeof fuji === "string") return fuji;

  throw new Error("multichain manifest has no self-deployed/rehearsal PoolManager");
}

function contractRows(poolManager: string, contracts: AnyRecord = {}): string {
  const rows = [
    ["PoolManager", contracts.PoolManager ?? poolManager],
    ["PositionDescriptor", contracts.PositionDescriptor ?? "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
    ["PositionManager", contracts.PositionManager ?? "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
    ["Quoter", contracts.Quoter ?? "0xcccccccccccccccccccccccccccccccccccccccc"],
    ["StateView", contracts.StateView ?? "0xdddddddddddddddddddddddddddddddddddddddd"],
    ["Universal Router", contracts.UniversalRouter ?? "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"],
    ["Universal Router 2.1.1", contracts.UniversalRouter211 ?? "0xffffffffffffffffffffffffffffffffffffffff"],
    ["Permit2", contracts.Permit2 ?? PERMIT2],
  ];

  return rows
    .map(([name, address]) => `| [${name}](https://github.com/Uniswap/test) | [\`${address}\`](https://example.invalid/address/${address}) |`)
    .join("\n");
}

function section(name: string, chainId: number, poolManager: string, contracts: AnyRecord = {}): string {
  return [
    `## ${name}: ${chainId}`,
    "| Contract | Address |",
    "| --- | --- |",
    contractRows(poolManager, contracts),
    "",
  ].join("\n");
}

function docsMarkdown(
  options: { includeArc: boolean; includeFuji: boolean; badAvalanchePoolManager?: string },
  manifest: AnyRecord,
): string {
  const avalanche = targetByNetwork(manifest, "avalanche");
  const arbitrum = targetByNetwork(manifest, "arbitrum-one");
  const sections = [
    "# Deployments",
    "",
    "Fixture for official multichain deployment input generation.",
    "",
    section(
      "Avalanche C-Chain",
      43_114,
      options.badAvalanchePoolManager ?? avalanche.contracts?.PoolManager ?? poolManagers.avalanche,
      options.badAvalanchePoolManager ? {} : avalanche.contracts,
    ),
    section("Arbitrum One", 42_161, arbitrum.contracts?.PoolManager ?? poolManagers.arbitrum, arbitrum.contracts),
  ];

  if (options.includeArc) sections.push(section("Arc", 5_042_002, poolManagers.arc));
  if (options.includeFuji) sections.push(section("Avalanche Fuji", 43_113, poolManagers.fuji));

  return sections.join("\n");
}

function runGenerator(inputPath: string, outPath: string): { status: number; stdout: string; stderr: string } {
  const result = spawnSync("bun", [
    "scripts/generate-official-multichain-deployment-inputs.ts",
    "--out",
    outPath,
  ], {
    cwd: ROOT,
    env: {
      ...process.env,
      UNISWAP_V4_DEPLOYMENTS_MARKDOWN_FILE: inputPath,
    },
    encoding: "utf8",
  });

  return {
    status: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function runDeploymentInputCheck(inputPath: string): { status: number; stdout: string; stderr: string } {
  const result = spawnSync("bun", ["scripts/check-official-multichain-deployment-inputs.ts"], {
    cwd: ROOT,
    env: {
      ...process.env,
      OFFICIAL_MULTICHAIN_DEPLOYMENT_INPUT: inputPath,
    },
    encoding: "utf8",
  });

  return {
    status: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function expect(condition: boolean, message: string, details?: string): void {
  if (condition) {
    pass(message);
    return;
  }

  fail(message);
  if (details) console.log(details.trimEnd());
}

function targetByNetwork(bundle: AnyRecord, network: string): AnyRecord {
  return (bundle.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function main(): void {
  console.log("Official multichain deployment input generator self-test");
  console.log("mode read-only/no-broadcast; temporary fixtures are cleaned up");
  console.log("");

  cleanup();

  try {
    const manifest = readJson(MANIFEST);
    const selfDeployedPoolManager = firstSelfDeployedPoolManager(manifest);

    writeFile(TEMP_CURRENT_DOCS, docsMarkdown({ includeArc: false, includeFuji: false }, manifest));
    writeFile(TEMP_ALL_DOCS, docsMarkdown({ includeArc: true, includeFuji: true }, manifest));
    writeFile(TEMP_BAD_DOCS, docsMarkdown({
      includeArc: false,
      includeFuji: false,
      badAvalanchePoolManager: selfDeployedPoolManager,
    }, manifest));

    const current = runGenerator(TEMP_CURRENT_DOCS, TEMP_CURRENT_OUTPUT);
    expect(current.status === 0, "current-docs fixture generates warning-only bundle", current.stdout || current.stderr);
    expect(/summary PASS=\d+ WARN=2 FAIL=0/.test(current.stdout), "current-docs fixture has Arc/Fuji pending warnings", current.stdout);

    const currentBundle = readJson(TEMP_CURRENT_OUTPUT);
    expect(targetByNetwork(currentBundle, "arc-mainnet").status === "pending-official-uniswap-v4-addresses", "current-docs fixture keeps Arc pending");
    expect(targetByNetwork(currentBundle, "avalanche-fuji").status === "pending-official-uniswap-v4-addresses", "current-docs fixture keeps Fuji pending");
    expect(
      targetByNetwork(currentBundle, "avalanche").contracts?.PoolManager === targetByNetwork(manifest, "avalanche").contracts?.PoolManager,
      "current-docs fixture populates Avalanche from manifest-backed official docs fixture",
    );
    expect(
      targetByNetwork(currentBundle, "arbitrum-one").contracts?.PoolManager === targetByNetwork(manifest, "arbitrum-one").contracts?.PoolManager,
      "current-docs fixture populates Arbitrum from manifest-backed official docs fixture",
    );

    const currentCheck = runDeploymentInputCheck(TEMP_CURRENT_OUTPUT);
    expect(currentCheck.status === 0, "current-docs generated bundle passes standalone input checker", currentCheck.stdout || currentCheck.stderr);
    expect(/summary PASS=\d+ WARN=2 FAIL=0/.test(currentCheck.stdout), "current-docs standalone checker has Arc/Fuji pending warnings", currentCheck.stdout);

    const allTargets = runGenerator(TEMP_ALL_DOCS, TEMP_ALL_OUTPUT);
    expect(allTargets.status === 0, "all-targets fixture generates populated bundle", allTargets.stdout || allTargets.stderr);
    expect(/summary PASS=\d+ WARN=0 FAIL=0/.test(allTargets.stdout), "all-targets fixture has no pending warnings", allTargets.stdout);

    const allBundle = readJson(TEMP_ALL_OUTPUT);
    for (const network of ["arc-mainnet", "avalanche-fuji", "avalanche", "arbitrum-one"]) {
      expect(targetByNetwork(allBundle, network).status === "official-uniswap-v4-addresses-published", `all-targets fixture publishes ${network}`);
    }

    const allTargetsCheck = runDeploymentInputCheck(TEMP_ALL_OUTPUT);
    expect(allTargetsCheck.status !== 0, "all-targets generated bundle fails checker while manifest keeps Arc/Fuji pending", allTargetsCheck.stdout || allTargetsCheck.stderr);
    expect(
      allTargetsCheck.stdout.includes("must stay pending while the multichain manifest is pending"),
      "all-targets checker failure explains manifest update requirement",
      allTargetsCheck.stdout,
    );

    const bad = runGenerator(TEMP_BAD_DOCS, TEMP_BAD_OUTPUT);
    expect(bad.status !== 0, "self-deployed PoolManager fixture fails generation", bad.stdout || bad.stderr);
    expect(
      bad.stdout.includes("PoolManager reuses self-deployed/rehearsal PoolManager"),
      "self-deployed PoolManager fixture fails for explicit reuse reason",
      bad.stdout,
    );

    const badCheckerBundle = currentBundle;
    targetByNetwork(badCheckerBundle, "avalanche").contracts.PoolManager = selfDeployedPoolManager;
    writeFile(TEMP_BAD_CHECKER_INPUT, `${JSON.stringify(badCheckerBundle, null, 2)}\n`);

    const badChecker = runDeploymentInputCheck(TEMP_BAD_CHECKER_INPUT);
    expect(badChecker.status !== 0, "self-deployed PoolManager bundle fails standalone checker", badChecker.stdout || badChecker.stderr);
    expect(
      badChecker.stdout.includes("PoolManager reuses self-deployed/rehearsal PoolManager"),
      "standalone checker fails for explicit PoolManager reuse reason",
      badChecker.stdout,
    );
  } finally {
    cleanup();
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
