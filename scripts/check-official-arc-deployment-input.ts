// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only validator for the official Arc Uniswap v4 address input file.
// The default template must stay pending until Uniswap publishes Arc v4
// addresses. When official addresses exist, point OFFICIAL_ARC_DEPLOYMENT_INPUT
// at a populated copy and optionally set OFFICIAL_ARC_RPC_URL for bytecode checks.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createPublicClient, http } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEFAULT_INPUT = "deployments/uniswap-v4-official-arc-input.template.json";
const DEPLOYMENTS_URL = "https://developers.uniswap.org/docs/protocols/v4/deployments";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

const requiredContracts = [
  "PoolManager",
  "PositionManager",
  "UniversalRouter",
  "Quoter",
  "StateView",
  "Permit2",
] as const;

const counts: Record<Severity, number> = { PASS: 0, WARN: 0, FAIL: 0 };

function record(severity: Severity, message: string): void {
  counts[severity] += 1;
  console.log(`${severity.padEnd(4)} ${message}`);
}

function pass(message: string): void {
  record("PASS", message);
}

function warn(message: string): void {
  record("WARN", message);
}

function fail(message: string): void {
  record("FAIL", message);
}

function inputPath(): string {
  return process.env.OFFICIAL_ARC_DEPLOYMENT_INPUT || DEFAULT_INPUT;
}

function readInput(relativePath: string): AnyRecord {
  const absolutePath = join(ROOT, relativePath);
  if (!existsSync(absolutePath)) {
    fail(`official Arc input file is missing at ${relativePath}`);
    return {};
  }

  return JSON.parse(readFileSync(absolutePath, "utf-8"));
}

function readManifest(): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, MANIFEST), "utf-8"));
}

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value) && !ZERO_ADDRESS_RE.test(value);
}

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function checkDoesNotReuseSelfDeployedPoolManager(manifest: AnyRecord, poolManager: unknown): void {
  if (!isAddress(poolManager)) return;

  for (const manager of Object.values(manifest.arcTestnet?.poolManagers ?? {}) as AnyRecord[]) {
    if (!isAddress(manager.address)) continue;

    if (sameAddress(poolManager, manager.address)) {
      fail(`official PoolManager reuses self-deployed Arc testnet PoolManager ${manager.address}`);
    } else {
      pass(`official PoolManager does not reuse self-deployed ${manager.address}`);
    }
  }
}

async function checkCodeExists(rpcUrl: string, address: string, label: string): Promise<void> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  const code = await client.getBytecode({ address: address as `0x${string}` });
  if (code && code !== "0x") pass(`${label} has deployed bytecode`);
  else fail(`${label} has no deployed bytecode at ${address}`);
}

async function main(): Promise<void> {
  const relativePath = inputPath();
  console.log("Official Arc Uniswap v4 deployment input check");
  console.log(`input ${relativePath}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const input = readInput(relativePath);
  const manifest = readManifest();
  const contracts = input.contracts ?? {};
  const pending = input.status === "pending-official-uniswap-v4-addresses";

  if (input.schemaVersion === 1) pass("official Arc input schemaVersion is 1");
  else fail("official Arc input schemaVersion must be 1");

  if (input.network === "arc-mainnet") pass("official Arc input targets arc-mainnet");
  else fail("official Arc input must target arc-mainnet");

  if (input.source === DEPLOYMENTS_URL) pass("official Arc input source is the Uniswap deployments page");
  else fail("official Arc input source must be the official Uniswap deployments page");

  if (pending) {
    pass("official Arc input is explicitly pending official addresses");
    if (input.chainId == null) pass("official Arc input chainId is intentionally unset while pending");
    else fail("official Arc input chainId must stay unset while pending");

    for (const name of requiredContracts) {
      if (contracts[name] == null) pass(`official ${name} is intentionally unset while pending`);
      else fail(`official ${name} must stay unset while pending`);
    }

    warn("official Arc deployment input remains pending until Uniswap publishes Arc v4 addresses");
  } else {
    if (typeof input.chainId === "number") pass(`official Arc input chainId is ${input.chainId}`);
    else fail("official Arc input chainId is missing");

    if (typeof input.retrievedAt === "string" && input.retrievedAt.length > 0) {
      pass("official Arc input records retrievedAt");
    } else {
      fail("official Arc input must record retrievedAt when populated");
    }

    for (const name of requiredContracts) {
      if (isAddress(contracts[name])) pass(`official ${name} address is valid`);
      else fail(`official ${name} address is missing or invalid`);
    }

    if (String(contracts.Permit2 ?? "").toLowerCase() === PERMIT2.toLowerCase()) {
      pass("official Permit2 address matches canonical Permit2");
    } else {
      fail("official Permit2 address must match canonical Permit2");
    }

    checkDoesNotReuseSelfDeployedPoolManager(manifest, contracts.PoolManager);

    const rpcUrl = process.env.OFFICIAL_ARC_RPC_URL;
    if (rpcUrl) {
      for (const name of requiredContracts) {
        if (isAddress(contracts[name])) await checkCodeExists(rpcUrl, contracts[name], name);
      }
    } else {
      warn("OFFICIAL_ARC_RPC_URL not set; skipping official address bytecode checks");
    }
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
