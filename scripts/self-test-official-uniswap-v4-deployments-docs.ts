// SPDX-License-Identifier: AGPL-3.0-only
//
// Regression self-test for the official Uniswap v4 deployments docs freshness
// checker. It uses temporary Markdown fixtures so the live network source does
// not control the regression cases.

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const TEMP_BASE = "deployments/.tmp-uniswap-v4-docs-current.self-test.md";
const TEMP_ARC = "deployments/.tmp-uniswap-v4-docs-arc.self-test.md";
const TEMP_FUJI = "deployments/.tmp-uniswap-v4-docs-fuji.self-test.md";
const TEMP_DRIFT = "deployments/.tmp-uniswap-v4-docs-drift.self-test.md";
const DRIFT_ADDRESS = "0x1111111111111111111111111111111111111111";

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
  for (const relativePath of [TEMP_BASE, TEMP_ARC, TEMP_FUJI, TEMP_DRIFT]) {
    const absolutePath = join(ROOT, relativePath);
    if (existsSync(absolutePath)) rmSync(absolutePath);
  }
}

function targetByNetwork(manifest: AnyRecord, network: string): AnyRecord {
  const target = (manifest.targets ?? []).find((entry: AnyRecord) => entry.network === network);
  if (!target) throw new Error(`missing ${network} target in ${MULTICHAIN_MANIFEST}`);
  return target;
}

function contractRows(contracts: AnyRecord): string {
  const rows = [
    ["PoolManager", contracts.PoolManager],
    ["PositionDescriptor", contracts.PositionDescriptor],
    ["PositionManager", contracts.PositionManager],
    ["Quoter", contracts.Quoter],
    ["StateView", contracts.StateView],
    ["Universal Router", contracts.UniversalRouter],
    ["Universal Router 2.1.1", contracts.UniversalRouter211],
    ["Permit2", contracts.Permit2],
  ];

  return rows
    .map(([name, address]) => `| [${name}](https://github.com/Uniswap/test) | [\`${address}\`](https://example.invalid/address/${address}) |`)
    .join("\n");
}

function section(name: string, chainId: number, contracts: AnyRecord): string {
  return [
    `## ${name}: ${chainId}`,
    "| Contract | Address |",
    "| --- | --- |",
    contractRows(contracts),
    "",
  ].join("\n");
}

function baseMarkdown(manifest: AnyRecord): string {
  const avalanche = targetByNetwork(manifest, "avalanche");
  const arbitrum = targetByNetwork(manifest, "arbitrum-one");

  return [
    "# Deployments",
    "",
    "Fixture for the official Uniswap v4 deployments docs freshness checker.",
    "",
    section("Avalanche", avalanche.chainId, avalanche.contracts),
    section("Arbitrum One", arbitrum.chainId, arbitrum.contracts),
  ].join("\n");
}

function withArcSection(markdown: string): string {
  return `${markdown}${section("Arc", 5_042_002, {
    PoolManager: "0x2222222222222222222222222222222222222222",
    PositionDescriptor: "0x3333333333333333333333333333333333333333",
    PositionManager: "0x4444444444444444444444444444444444444444",
    Quoter: "0x5555555555555555555555555555555555555555",
    StateView: "0x6666666666666666666666666666666666666666",
    UniversalRouter: "0x7777777777777777777777777777777777777777",
    UniversalRouter211: "0x8888888888888888888888888888888888888888",
    Permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  })}`;
}

function withFujiSection(markdown: string): string {
  return `${markdown}${section("Avalanche Fuji", 43_113, {
    PoolManager: "0x2222222222222222222222222222222222222222",
    PositionDescriptor: "0x3333333333333333333333333333333333333333",
    PositionManager: "0x4444444444444444444444444444444444444444",
    Quoter: "0x5555555555555555555555555555555555555555",
    StateView: "0x6666666666666666666666666666666666666666",
    UniversalRouter: "0x7777777777777777777777777777777777777777",
    UniversalRouter211: "0x8888888888888888888888888888888888888888",
    Permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  })}`;
}

function withAvalanchePoolManagerDrift(markdown: string, manifest: AnyRecord): string {
  const avalanche = targetByNetwork(manifest, "avalanche");
  return markdown.replace(String(avalanche.contracts.PoolManager), DRIFT_ADDRESS);
}

function runDocsCheck(inputPath: string): { status: number; stdout: string; stderr: string } {
  const result = spawnSync("bun", ["scripts/check-official-uniswap-v4-deployments-docs.ts"], {
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

function expect(condition: boolean, message: string, details?: string): void {
  if (condition) {
    pass(message);
    return;
  }

  fail(message);
  if (details) console.log(details.trimEnd());
}

function main(): void {
  console.log("Official Uniswap v4 deployments docs freshness checker self-test");
  console.log("mode read-only/no-broadcast; temporary fixtures are cleaned up");
  console.log("");

  cleanup();

  try {
    const manifest = readJson(MULTICHAIN_MANIFEST);
    const base = baseMarkdown(manifest);

    writeFile(TEMP_BASE, base);
    writeFile(TEMP_ARC, withArcSection(base));
    writeFile(TEMP_FUJI, withFujiSection(base));
    writeFile(TEMP_DRIFT, withAvalanchePoolManagerDrift(base, manifest));

    const baseline = runDocsCheck(TEMP_BASE);
    expect(baseline.status === 0, "current-docs fixture passes", baseline.stdout || baseline.stderr);
    expect(
      baseline.stdout.includes("loaded Uniswap deployments markdown fixture")
        && baseline.stdout.includes("summary PASS=31 WARN=2 FAIL=0"),
      "current-docs fixture has expected summary",
      baseline.stdout,
    );

    const arc = runDocsCheck(TEMP_ARC);
    expect(arc.status !== 0, "Arc-published fixture fails while manifest is pending", arc.stdout || arc.stderr);
    expect(
      arc.stdout.includes("official docs now include Arc mainnet"),
      "Arc-published fixture reports the explicit Arc update requirement",
      arc.stdout,
    );

    const fuji = runDocsCheck(TEMP_FUJI);
    expect(fuji.status !== 0, "Fuji-published fixture fails while manifest is pending", fuji.stdout || fuji.stderr);
    expect(
      fuji.stdout.includes("official docs now include Avalanche Fuji"),
      "Fuji-published fixture reports the explicit Fuji update requirement",
      fuji.stdout,
    );

    const drift = runDocsCheck(TEMP_DRIFT);
    expect(drift.status !== 0, "Avalanche address-drift fixture fails", drift.stdout || drift.stderr);
    expect(
      drift.stdout.includes(`docs=${DRIFT_ADDRESS}`),
      "Avalanche address-drift fixture reports the mismatched docs address",
      drift.stdout,
    );
  } finally {
    cleanup();
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
