// SPDX-License-Identifier: AGPL-3.0-only
//
// Regression self-test for the official Arc deployment input generator. It
// proves that Arc-absent docs stay pending, Arc-present docs produce a validator-
// compatible populated input, and self-deployed PoolManager reuse is rejected.

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const TEMP_NO_ARC_DOCS = "deployments/.tmp-official-arc-generator-no-arc.self-test.md";
const TEMP_ARC_DOCS = "deployments/.tmp-official-arc-generator-arc.self-test.md";
const TEMP_BAD_ARC_DOCS = "deployments/.tmp-official-arc-generator-bad-arc.self-test.md";
const TEMP_GENERATED_INPUT = "deployments/.tmp-official-arc-generated.self-test.json";
const TEMP_BAD_GENERATED_INPUT = "deployments/.tmp-official-arc-generated-bad.self-test.json";
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const GOOD_POOL_MANAGER = "0x1111111111111111111111111111111111111111";

const counts: Record<Severity, number> = { PASS: 0, FAIL: 0 };

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
    TEMP_NO_ARC_DOCS,
    TEMP_ARC_DOCS,
    TEMP_BAD_ARC_DOCS,
    TEMP_GENERATED_INPUT,
    TEMP_BAD_GENERATED_INPUT,
  ]) {
    const absolutePath = join(ROOT, relativePath);
    if (existsSync(absolutePath)) rmSync(absolutePath);
  }
}

function firstSelfDeployedPoolManager(manifest: AnyRecord): string {
  for (const manager of Object.values(manifest.arcTestnet?.poolManagers ?? {}) as AnyRecord[]) {
    if (typeof manager.address === "string") return manager.address;
  }

  throw new Error("readiness manifest has no self-deployed Arc testnet PoolManager");
}

function contractRows(poolManager: string): string {
  const rows = [
    ["PoolManager", poolManager],
    ["PositionDescriptor", "0x2222222222222222222222222222222222222222"],
    ["PositionManager", "0x3333333333333333333333333333333333333333"],
    ["Quoter", "0x4444444444444444444444444444444444444444"],
    ["StateView", "0x5555555555555555555555555555555555555555"],
    ["Universal Router", "0x6666666666666666666666666666666666666666"],
    ["Universal Router 2.1.1", "0x7777777777777777777777777777777777777777"],
    ["Permit2", PERMIT2],
  ];

  return rows
    .map(([name, address]) => `| [${name}](https://github.com/Uniswap/test) | [\`${address}\`](https://example.invalid/address/${address}) |`)
    .join("\n");
}

function docsMarkdown(includeArc: boolean, poolManager = GOOD_POOL_MANAGER): string {
  const sections = [
    "# Deployments",
    "",
    "Fixture for official Arc deployment input generation.",
    "",
    "## Arbitrum One: 42161",
    "| Contract | Address |",
    "| --- | --- |",
    contractRows("0x360e68faccca8ca495c1b759fd9eee466db9fb32"),
    "",
  ];

  if (includeArc) {
    sections.push(
      "## Arc: 5042002",
      "| Contract | Address |",
      "| --- | --- |",
      contractRows(poolManager),
      "",
    );
  }

  return sections.join("\n");
}

function runGenerator(inputPath: string, outPath?: string): { status: number; stdout: string; stderr: string } {
  const args = ["scripts/generate-official-arc-deployment-input.ts"];
  if (outPath) args.push("--out", outPath);

  const result = spawnSync("bun", args, {
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
  const env = {
    ...process.env,
    OFFICIAL_ARC_DEPLOYMENT_INPUT: inputPath,
  };
  delete env.OFFICIAL_ARC_RPC_URL;

  const result = spawnSync("bun", ["scripts/check-official-arc-deployment-input.ts"], {
    cwd: ROOT,
    env,
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

function main(): void {
  console.log("Official Arc deployment input generator self-test");
  console.log("mode read-only/no-broadcast; temporary fixtures are cleaned up");
  console.log("");

  cleanup();

  try {
    const manifest = readJson(MANIFEST);
    const selfDeployedPoolManager = firstSelfDeployedPoolManager(manifest);

    writeFile(TEMP_NO_ARC_DOCS, docsMarkdown(false));
    writeFile(TEMP_ARC_DOCS, docsMarkdown(true));
    writeFile(TEMP_BAD_ARC_DOCS, docsMarkdown(true, selfDeployedPoolManager));

    const absent = runGenerator(TEMP_NO_ARC_DOCS);
    expect(absent.status === 0, "Arc-absent fixture keeps generator warning-only", absent.stdout || absent.stderr);
    expect(
      /summary PASS=\d+ WARN=1 FAIL=0/.test(absent.stdout)
        && absent.stdout.includes("default official Arc input remains pending"),
      "Arc-absent fixture has expected pending summary",
      absent.stdout,
    );

    const generated = runGenerator(TEMP_ARC_DOCS, TEMP_GENERATED_INPUT);
    expect(generated.status === 0, "Arc-present fixture writes generated official input", generated.stdout || generated.stderr);
    expect(
      generated.stdout.includes(`wrote generated official Arc input to ${TEMP_GENERATED_INPUT}`),
      "Arc-present fixture reports generated input path",
      generated.stdout,
    );

    const generatedInput = readJson(TEMP_GENERATED_INPUT);
    expect(generatedInput.contracts?.PoolManager === GOOD_POOL_MANAGER, "generated input uses Arc PoolManager from docs fixture");
    expect(generatedInput.contracts?.Permit2 === PERMIT2, "generated input preserves canonical Permit2");

    const generatedCheck = runDeploymentInputCheck(TEMP_GENERATED_INPUT);
    expect(generatedCheck.status === 0, "generated input passes official Arc deployment input checker", generatedCheck.stdout || generatedCheck.stderr);
    expect(/summary PASS=\d+ WARN=1 FAIL=0/.test(generatedCheck.stdout), "generated input checker has expected offline warning", generatedCheck.stdout);

    const badGenerated = runGenerator(TEMP_BAD_ARC_DOCS, TEMP_BAD_GENERATED_INPUT);
    expect(badGenerated.status !== 0, "self-deployed PoolManager fixture fails generation", badGenerated.stdout || badGenerated.stderr);
    expect(
      badGenerated.stdout.includes("generated official PoolManager reuses self-deployed Arc testnet PoolManager"),
      "self-deployed PoolManager fixture fails for explicit reuse reason",
      badGenerated.stdout,
    );
  } finally {
    cleanup();
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
