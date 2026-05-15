#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = new URL("..", import.meta.url).pathname;
const SRC = join(ROOT, "contracts/src");

const failures = [];

function rel(path) {
  return relative(ROOT, path);
}

function read(path) {
  return readFileSync(path, "utf8");
}

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(path));
    else if (entry.isFile() && entry.name.endsWith(".sol")) out.push(path);
  }
  return out;
}

function fail(message) {
  failures.push(message);
}

function assertIncludes(path, needle, label) {
  const source = read(path);
  if (!source.includes(needle)) fail(`${label}: ${rel(path)} missing ${needle}`);
}

function productionContracts() {
  return walk(SRC).filter((path) => {
    const r = rel(path);
    if (r.includes("/interfaces/")) return false;
    if (r.includes("/libraries/")) return false;
    if (r.includes("/test-helpers/")) return false;
    return /\bcontract\s+\w+/.test(read(path));
  });
}

if (!existsSync(SRC)) fail(`missing ${rel(SRC)}`);

for (const path of walk(SRC)) {
  const r = rel(path);
  const source = read(path);
  const allowedOracleImpl = r === "contracts/src/hub/FxOracle.sol";
  const forbiddenOracleImports = [
    "@pythnetwork/",
    "@redstone-finance/",
    "PrimaryProdDataServiceConsumerBase",
    "PythStructs",
    "IPyth",
  ];
  if (!allowedOracleImpl && forbiddenOracleImports.some((needle) => source.includes(needle))) {
    fail(`IFxOracle guardrail: direct oracle dependency outside FxOracle in ${r}`);
  }

  if (source.includes("tx.origin")) fail(`Ghost/KYC guardrail: tx.origin usage in ${r}`);
}

const enterHubSignature = "function enterHub(address token, uint256 amount, address beneficiary, bytes calldata hubCalldata)";
assertIncludes(join(SRC, "interfaces/IFxSpoke.sol"), enterHubSignature, "IFxSpoke beneficiary guardrail");
assertIncludes(join(SRC, "spoke/FxSpoke.sol"), enterHubSignature, "FxSpoke beneficiary guardrail");

assertIncludes(
  join(SRC, "hub/FxHubMessageReceiver.sol"),
  "function sweepStrandedDeposit(bytes32 messageNonce)",
  "stranded deposit guardrail",
);
assertIncludes(
  join(SRC, "interfaces/IFxHubMessageReceiver.sol"),
  "function sweepStrandedDeposit(bytes32 messageNonce)",
  "stranded deposit interface guardrail",
);

for (const path of productionContracts()) {
  const header = read(path).split("\n").slice(0, 90).join("\n");
  if (!header.includes("Data flow:") && !header.includes("┌")) {
    fail(`data-flow header guardrail: ${rel(path)} lacks an ASCII data-flow diagram`);
  }
}

for (const path of walk(SRC)) {
  if (read(path).includes("EligibilityReason")) {
    fail(`EligibilityReason guardrail: enum must stay in @bu/fx-engine, found in ${rel(path)}`);
  }
}
assertIncludes(join(ROOT, "packages/sdk/src/eligibility.ts"), "export enum EligibilityReason", "EligibilityReason SDK guardrail");

if (failures.length > 0) {
  console.error("Contract guardrail check failed:");
  for (const item of failures) console.error(`- ${item}`);
  process.exit(1);
}

console.log("contract guardrails passed");
