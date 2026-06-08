// SPDX-License-Identifier: AGPL-3.0-only
//
// Checks whether Uniswap has published official v4 Arc deployments and whether
// the local readiness manifest is updated enough to claim official Arc readiness.

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createPublicClient, http } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEPLOYMENTS_URL = "https://developers.uniswap.org/docs/protocols/v4/deployments";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const counts: Record<Severity, number> = { PASS: 0, WARN: 0, FAIL: 0 };

const requiredContracts = [
  "PoolManager",
  "PositionManager",
  "UniversalRouter",
  "Quoter",
  "StateView",
  "Permit2",
] as const;

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

function readManifest(): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, MANIFEST), "utf-8"));
}

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value) && !ZERO_ADDRESS_RE.test(value);
}

async function officialDocsMentionArc(): Promise<boolean> {
  const response = await fetch(DEPLOYMENTS_URL);
  if (!response.ok) {
    fail(`failed to fetch Uniswap deployments page: ${response.status}`);
    return false;
  }

  const html = await response.text();
  const mentionsArcHeading = /#+\s*Arc\b/i.test(html) || />\s*Arc\s*:\s*(5042|5042002)\s*</i.test(html);
  const mentionsArcChainId = /\b5042\b|\b5042002\b/.test(html);
  return mentionsArcHeading || mentionsArcChainId;
}

async function checkCodeExists(rpcUrl: string, address: string, label: string): Promise<void> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  const code = await client.getBytecode({ address: address as `0x${string}` });
  if (code && code !== "0x") pass(`${label} has deployed bytecode`);
  else fail(`${label} has no deployed bytecode at ${address}`);
}

async function main(): Promise<void> {
  console.log("Official Uniswap v4 Arc readiness check");
  console.log(`deployments ${DEPLOYMENTS_URL}`);
  console.log("");

  const manifest = readManifest();
  const official = manifest.officialArcMainnet ?? {};
  const docsMentionArc = await officialDocsMentionArc();

  if (!docsMentionArc) {
    pass("official Uniswap v4 deployments page does not list Arc yet");
    if (official.status === "pending-official-uniswap-v4-addresses") {
      pass("manifest correctly keeps official Arc status pending");
    } else {
      fail("manifest should be pending while official Uniswap Arc v4 deployments are absent");
    }
    if (official.arcListedInUniswapDeploymentsOn2026_06_08 === false) {
      pass("manifest records Arc as absent from Uniswap deployments on 2026-06-08");
    } else {
      fail("manifest must not claim Arc was listed on 2026-06-08");
    }
    warn("official Arc mainnet deploy/index step remains externally pending on Uniswap-published addresses");
  } else {
    warn("official Uniswap v4 deployments page appears to mention Arc; update this repository from the official table");
    if (official.status === "pending-official-uniswap-v4-addresses") {
      fail("manifest is still pending despite official docs appearing to list Arc");
    }
  }

  const contracts = official.contracts ?? {};
  if (official.status === "pending-official-uniswap-v4-addresses") {
    for (const name of requiredContracts) {
      if (contracts[name] == null) pass(`official ${name} address is intentionally unset while pending`);
      else fail(`official ${name} address must not be populated while status is pending`);
    }
  } else {
    for (const name of requiredContracts) {
      if (isAddress(contracts[name])) pass(`official ${name} address is valid`);
      else fail(`official ${name} address is missing or invalid`);
    }

    if (typeof official.chainId === "number") pass(`official Arc chainId recorded as ${official.chainId}`);
    else fail("official Arc chainId is missing");

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
