// SPDX-License-Identifier: AGPL-3.0-only
//
// Regression self-test for the official Arc deployment input checker.
// It proves that populated official inputs cannot reuse the self-deployed
// Arc testnet PoolManagers that are only valid rehearsal infrastructure.

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const TEMP_PENDING_INPUT = "deployments/.tmp-official-arc-input-pending.self-test.json";
const TEMP_GOOD_INPUT = "deployments/.tmp-official-arc-input-good.self-test.json";
const TEMP_BAD_POOL_MANAGER_INPUT = "deployments/.tmp-official-arc-input-bad-pm.self-test.json";
const DEPLOYMENTS_URL = "https://developers.uniswap.org/docs/protocols/v4/deployments";
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const SELF_TEST_CHAIN_ID = 999999;

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

function writeJson(relativePath: string, value: AnyRecord): void {
  writeFileSync(join(ROOT, relativePath), `${JSON.stringify(value, null, 2)}\n`);
}

function cleanup(): void {
  for (const relativePath of [TEMP_PENDING_INPUT, TEMP_GOOD_INPUT, TEMP_BAD_POOL_MANAGER_INPUT]) {
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

function pendingInput(): AnyRecord {
  return {
    schemaVersion: 1,
    network: "arc-mainnet",
    source: DEPLOYMENTS_URL,
    status: "pending-official-uniswap-v4-addresses",
    chainId: null,
    retrievedAt: null,
    contracts: {
      PoolManager: null,
      PositionManager: null,
      UniversalRouter: null,
      Quoter: null,
      StateView: null,
      Permit2: null,
    },
  };
}

function populatedInput(poolManager: string): AnyRecord {
  return {
    schemaVersion: 1,
    network: "arc-mainnet",
    source: DEPLOYMENTS_URL,
    status: "ready",
    chainId: SELF_TEST_CHAIN_ID,
    retrievedAt: "2026-06-08T00:00:00.000Z",
    contracts: {
      PoolManager: poolManager,
      PositionManager: "0x2222222222222222222222222222222222222222",
      UniversalRouter: "0x3333333333333333333333333333333333333333",
      Quoter: "0x4444444444444444444444444444444444444444",
      StateView: "0x5555555555555555555555555555555555555555",
      Permit2: PERMIT2,
    },
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
  console.log("Official Arc deployment input checker self-test");
  console.log("mode read-only/no-broadcast; temporary fixtures are cleaned up");
  console.log("");

  cleanup();

  try {
    const manifest = readJson(MANIFEST);
    const selfDeployedPoolManager = firstSelfDeployedPoolManager(manifest);

    writeJson(TEMP_PENDING_INPUT, pendingInput());
    writeJson(TEMP_GOOD_INPUT, populatedInput("0x1111111111111111111111111111111111111111"));
    writeJson(TEMP_BAD_POOL_MANAGER_INPUT, populatedInput(selfDeployedPoolManager));

    const pending = runDeploymentInputCheck(TEMP_PENDING_INPUT);
    expect(pending.status === 0, "pending fixture passes with official addresses intentionally unset", pending.stdout || pending.stderr);
    expect(/summary PASS=\d+ WARN=1 FAIL=0/.test(pending.stdout), "pending fixture has expected warning-only summary", pending.stdout);

    const good = runDeploymentInputCheck(TEMP_GOOD_INPUT);
    expect(good.status === 0, "populated non-self-deployed PoolManager fixture passes offline preflight", good.stdout || good.stderr);
    expect(good.stdout.includes("official PoolManager does not reuse self-deployed"), "populated fixture checks self-deployed PoolManager reuse", good.stdout);
    expect(/summary PASS=\d+ WARN=1 FAIL=0/.test(good.stdout), "populated fixture has FAIL=0 without RPC", good.stdout);

    const bad = runDeploymentInputCheck(TEMP_BAD_POOL_MANAGER_INPUT);
    expect(bad.status !== 0, "self-deployed PoolManager fixture fails", bad.stdout || bad.stderr);
    expect(
      bad.stdout.includes("official PoolManager reuses self-deployed Arc testnet PoolManager"),
      "self-deployed PoolManager fixture fails for the explicit reuse reason",
      bad.stdout,
    );
    expect(/summary PASS=\d+ WARN=1 FAIL=1/.test(bad.stdout), "self-deployed PoolManager fixture has exactly one expected failure", bad.stdout);
  } finally {
    cleanup();
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
