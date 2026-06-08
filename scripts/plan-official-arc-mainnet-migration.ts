// SPDX-License-Identifier: AGPL-3.0-only
//
// Builds a no-broadcast migration plan for moving the Arc testnet hook package
// onto official Uniswap v4 Arc mainnet infrastructure once Uniswap publishes it.

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;

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

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value) && !ZERO_ADDRESS_RE.test(value);
}

function readManifest(): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, MANIFEST), "utf-8"));
}

function findFamily(manifest: AnyRecord, name: string): AnyRecord | undefined {
  return (manifest.hookFamilies ?? []).find((family: AnyRecord) => family.name === name);
}

function checkOfficialContracts(official: AnyRecord): void {
  const required = new Set<string>(official.requiredContracts ?? []);
  for (const name of requiredContracts) {
    if (required.has(name)) pass(`official migration requires ${name}`);
    else fail(`official migration is missing required contract ${name}`);
  }

  const contracts = official.contracts ?? {};
  if (official.status === "pending-official-uniswap-v4-addresses") {
    if (official.chainId == null) pass("official Arc chainId is intentionally unset while pending");
    else fail("official Arc chainId must stay unset while official addresses are pending");

    for (const name of requiredContracts) {
      if (contracts[name] == null) pass(`official ${name} is intentionally unset while pending`);
      else fail(`official ${name} must stay unset while pending`);
    }
    warn("official Uniswap Arc v4 addresses are not published yet; plan remains pre-broadcast");
  } else {
    if (typeof official.chainId === "number") pass(`official Arc chainId is recorded as ${official.chainId}`);
    else fail("official Arc chainId is missing");

    for (const name of requiredContracts) {
      if (isAddress(contracts[name])) pass(`official ${name} address is valid`);
      else fail(`official ${name} address is missing or invalid`);
    }
  }
}

function checkChecklist(official: AnyRecord): void {
  const checklist = Array.isArray(official.migrationChecklist)
    ? official.migrationChecklist.map((item: unknown) => String(item).toLowerCase())
    : [];
  const expected = [
    ["fetch official addresses", "fetch official arc poolmanager"],
    ["redeploy/remine hooks", "redeploy or remine"],
    ["initialize pools", "initialize pools"],
    ["first liquidity", "liquidity"],
    ["official pool publication input", "publication input"],
    ["publish pool evidence", "publish poolkey"],
    ["StateView verification", "stateview"],
    ["subgraph verification", "subgraph"],
  ] as const;

  for (const [label, needle] of expected) {
    if (checklist.some((item) => item.includes(needle))) pass(`official migration checklist includes ${label}`);
    else fail(`official migration checklist is missing ${label}`);
  }
}

function checkHookSurfaces(manifest: AnyRecord): void {
  const hedge = findFamily(manifest, "FxHedgeHook");
  const fxswap = findFamily(manifest, "FxSwapHook");
  const gateway = findFamily(manifest, "TelaranaGatewayHubHook");
  const ghost = findFamily(manifest, "FxGhostKycHook");

  const hedgePools = Array.isArray(hedge?.pools) ? hedge.pools : [];
  const liveHedgePools = hedgePools.filter((pool: AnyRecord) => pool.status === "live");
  if (hedge?.deployed === true && liveHedgePools.length === 6) {
    pass("FxHedgeHook official migration has six live Arc-testnet pool templates");
  } else {
    fail("FxHedgeHook official migration needs six live pool templates");
  }
  if (hedge?.routerQuoterStatus?.genericV4Quoter === "locally-proven-with-official-v4quoter-diagnostic") {
    pass("FxHedgeHook official migration will rerun the positive V4Quoter diagnostic");
  } else {
    fail("FxHedgeHook V4Quoter diagnostic status is missing");
  }
  if (hedge?.liquidityReadiness?.operatorCommand === "bun run hedge:arc:seed-liquidity") {
    pass("FxHedgeHook first-liquidity operator command is recorded");
  } else {
    fail("FxHedgeHook first-liquidity operator command is missing");
  }

  const fxswapPools = Array.isArray(fxswap?.pools) ? fxswap.pools : [];
  if (fxswap?.deployed === true && fxswapPools.length >= 4) {
    pass("FxSwapHook official migration has vault-backed pool templates");
  } else {
    fail("FxSwapHook official migration is missing pool templates");
  }
  if (fxswap?.routerQuoterStatus?.genericV4Quoter === "diagnostic-proven-not-generic-empty-hookdata") {
    pass("FxSwapHook migration preserves the direct-route/non-generic-quoter caveat");
  } else {
    fail("FxSwapHook direct-route/non-generic-quoter caveat is missing");
  }

  if (gateway?.routerQuoterStatus?.genericV4Quoter === "not-generic-hookdata-required") {
    pass("TelaranaGatewayHubHook migration preserves hookData-required routing caveat");
  } else {
    fail("TelaranaGatewayHubHook hookData-required caveat is missing");
  }

  if (ghost?.deployed === false && ghost?.routerQuoterStatus?.genericV4Quoter === "not-submission-surface") {
    pass("FxGhostKycHook is excluded from the current Uniswap indexing submission surface");
  } else {
    fail("FxGhostKycHook submission status is ambiguous");
  }
}

function printPlan(manifest: AnyRecord): void {
  const official = manifest.officialArcMainnet ?? {};
  const contracts = official.contracts ?? {};

  console.log("");
  console.log("migration phases");
  console.log("1. Pull official Arc v4 contract addresses from Uniswap deployments docs.");
  console.log(`   PoolManager:     ${contracts.PoolManager ?? "<pending>"}`);
  console.log(`   PositionManager: ${contracts.PositionManager ?? "<pending>"}`);
  console.log(`   UniversalRouter: ${contracts.UniversalRouter ?? "<pending>"}`);
  console.log(`   Quoter:          ${contracts.Quoter ?? "<pending>"}`);
  console.log(`   StateView:       ${contracts.StateView ?? "<pending>"}`);
  console.log(`   Permit2:         ${contracts.Permit2 ?? "<pending>"}`);
  console.log("2. Remine/redeploy hooks with official PoolManager constructor args; do not reuse self-deployed testnet PoolManagers.");
  console.log("3. Initialize each intended official PoolKey on the official PoolManager and publish PoolKey, poolId, hook, init tx, and permission bits.");
  console.log("4. Add first liquidity through official PositionManager/periphery when available, or a reviewed compatible route, then publish first-liquidity txs.");
  console.log("5. Rerun V4Quoter/route diagnostics against official Arc Quoter and route caveats.");
  console.log("6. Populate and verify the official Arc pool publication input.");
  console.log("7. Read official pool state through StateView by poolId and publish slot0/liquidity evidence.");
  console.log("8. Query the official v4 subgraph by poolId and verify each pool hooks field matches the intended hook address.");
}

function main(): void {
  console.log("Official Arc mainnet migration planner");
  console.log(`manifest ${MANIFEST}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const manifest = readManifest();
  const official = manifest.officialArcMainnet ?? {};

  if (manifest.network === "arc-testnet" && manifest.chainId === 5_042_002) {
    pass("manifest source is Arc testnet rehearsal state");
  } else {
    fail("manifest source must be Arc testnet rehearsal state");
  }

  checkOfficialContracts(official);
  checkChecklist(official);
  checkHookSurfaces(manifest);
  printPlan(manifest);

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
