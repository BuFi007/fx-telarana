// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only preflight for remine/redeploying the Uniswap v4 hook package onto
// an official Arc PoolManager once Uniswap publishes Arc v4 addresses.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEFAULT_OFFICIAL_INPUT = "deployments/uniswap-v4-official-arc-input.template.json";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const LOW_14_MASK = 0x3fffn;

const expectedHookBits: Record<string, number> = {
  FxHedgeHook: 1344,
  FxSwapHook: 2760,
  TelaranaGatewayHubHook: 136,
};

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

function readJson(relativePath: string): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, relativePath), "utf-8"));
}

function readText(relativePath: string): string {
  return readFileSync(join(ROOT, relativePath), "utf-8");
}

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value) && !ZERO_ADDRESS_RE.test(value);
}

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function low14Bits(address: string): number {
  return Number(BigInt(address) & LOW_14_MASK);
}

function officialInputPath(): string {
  return process.env.OFFICIAL_ARC_DEPLOYMENT_INPUT || DEFAULT_OFFICIAL_INPUT;
}

function checkFile(relativePath: string, label: string): string {
  if (existsSync(join(ROOT, relativePath))) pass(`${label} exists at ${relativePath}`);
  else {
    fail(`${label} is missing at ${relativePath}`);
    return "";
  }

  return readText(relativePath);
}

function findFamily(manifest: AnyRecord, name: string): AnyRecord | undefined {
  return (manifest.hookFamilies ?? []).find((family: AnyRecord) => family.name === name);
}

function checkOfficialPoolManager(manifest: AnyRecord, input: AnyRecord): string | undefined {
  const officialPoolManager = input.contracts?.PoolManager;
  const pending = input.status === "pending-official-uniswap-v4-addresses";

  if (input.network === "arc-mainnet") pass("official deployment input targets arc-mainnet");
  else fail("official deployment input must target arc-mainnet");

  if (pending) {
    pass("official hook redeploy plan is pending official Uniswap Arc addresses");
    if (officialPoolManager == null) pass("official PoolManager is intentionally unset while pending");
    else fail("official PoolManager must stay unset while official addresses are pending");
    warn("official hook remine/redeploy cannot be completed until Uniswap publishes Arc PoolManager");
    return undefined;
  }

  if (isAddress(officialPoolManager)) pass("official PoolManager address is populated");
  else fail("official PoolManager address is missing or invalid");

  for (const manager of Object.values(manifest.arcTestnet?.poolManagers ?? {}) as AnyRecord[]) {
    if (isAddress(officialPoolManager) && sameAddress(officialPoolManager, manager.address)) {
      fail(`official PoolManager reuses self-deployed Arc testnet PoolManager ${manager.address}`);
    } else if (isAddress(officialPoolManager) && isAddress(manager.address)) {
      pass(`official PoolManager does not reuse self-deployed ${manager.address}`);
    }
  }

  return isAddress(officialPoolManager) ? officialPoolManager : undefined;
}

function checkFamilyBits(family: AnyRecord, name: string): void {
  const expected = expectedHookBits[name];
  if (Number(family.permissionFlagsLow14Bits) === expected) {
    pass(`${name} manifest permission bits match ${expected}`);
  } else {
    fail(`${name} manifest permission bits do not match expected ${expected}`);
  }

  const addresses = new Set<string>();
  if (isAddress(family.hookAddress)) addresses.add(family.hookAddress);
  for (const pool of family.pools ?? []) {
    if (isAddress(pool.hookAddress)) addresses.add(pool.hookAddress);
  }

  for (const address of addresses) {
    if (low14Bits(address) === expected) pass(`${name} source hook ${address} low-14 bits match ${expected}`);
    else fail(`${name} source hook ${address} low-14 bits do not match ${expected}`);
  }
}

function checkFxHedge(manifest: AnyRecord): void {
  const family = findFamily(manifest, "FxHedgeHook");
  if (!family) {
    fail("FxHedgeHook family is missing from readiness manifest");
    return;
  }

  checkFamilyBits(family, "FxHedgeHook");
  const deployScript = checkFile("contracts/script/DeployFxHedgeHookAndPools.s.sol", "FxHedgeHook deploy script");
  checkFile("contracts/script/ConfigureFxHedgeStablePools.s.sol", "FxHedgeHook stable pool configure script");
  checkFile("contracts/script/SeedFxHedgeHookLiquidity.s.sol", "FxHedgeHook first-liquidity script");

  if (deployScript.includes("POOL_MANAGER") && deployScript.includes("HookMiner.find")) {
    pass("FxHedgeHook deploy script mines against env-provided POOL_MANAGER");
  } else {
    fail("FxHedgeHook deploy script must mine against env-provided POOL_MANAGER");
  }

  const livePools = Array.isArray(family.pools) ? family.pools.filter((pool: AnyRecord) => pool.status === "live") : [];
  if (livePools.length === 6) pass("FxHedgeHook official redeploy has six source pool templates");
  else fail(`FxHedgeHook official redeploy expected six source pool templates, found ${livePools.length}`);
}

function checkFxSwap(manifest: AnyRecord): void {
  const family = findFamily(manifest, "FxSwapHook");
  if (!family) {
    fail("FxSwapHook family is missing from readiness manifest");
    return;
  }

  checkFamilyBits(family, "FxSwapHook");
  const deployScript = checkFile("contracts/script/DeployFxSwapHook.s.sol", "FxSwapHook generic CREATE2 deploy script");
  const batchScript = checkFile("contracts/script/DeployVaultBackedAll.s.sol", "FxSwapHook Arc-testnet batch deploy script");
  const mineScript = checkFile("contracts/script/MineHookSalt.s.sol", "FxSwapHook salt miner");

  for (const [label, text] of [
    ["FxSwapHook deploy script", deployScript],
    ["FxSwapHook salt miner", mineScript],
  ] as const) {
    if (text.includes("FX_VAULT") && text.includes("morpho, vault")) {
      pass(`${label} includes the current vault-backed constructor argument`);
    } else {
      fail(`${label} must include FX_VAULT and the vault-backed constructor argument`);
    }
  }

  if (batchScript.includes("VAULT") && batchScript.includes("MORPHO, VAULT")) {
    pass("FxSwapHook batch deploy script is explicitly vault-backed");
  } else {
    fail("FxSwapHook batch deploy script must stay vault-backed");
  }

  const pools = Array.isArray(family.pools) ? family.pools : [];
  if (pools.length >= 4) pass("FxSwapHook official redeploy has vault-backed pool templates");
  else fail("FxSwapHook official redeploy is missing vault-backed pool templates");
}

function checkGateway(manifest: AnyRecord): void {
  const family = findFamily(manifest, "TelaranaGatewayHubHook");
  if (!family) {
    fail("TelaranaGatewayHubHook family is missing from readiness manifest");
    return;
  }

  checkFamilyBits(family, "TelaranaGatewayHubHook");
  const deployScript = checkFile("contracts/script/DeployTelaranaGatewayHubHook.s.sol", "TelaranaGatewayHubHook deploy script");
  checkFile("contracts/script/MineHookSalt.s.sol", "TelaranaGatewayHubHook salt miner");

  if (
    deployScript.includes("runCreate2")
    && deployScript.includes("BEFORE_SWAP_FLAG")
    && deployScript.includes("BEFORE_SWAP_RETURNS_DELTA_FLAG")
  ) {
    pass("TelaranaGatewayHubHook deploy script exposes the CREATE2 permission-bit path");
  } else {
    fail("TelaranaGatewayHubHook official deployment must use runCreate2 permission-bit path");
  }

  if (family.routerQuoterStatus?.genericV4Quoter === "not-generic-hookdata-required") {
    pass("TelaranaGatewayHubHook official route keeps the hookData-required caveat");
  } else {
    fail("TelaranaGatewayHubHook hookData-required caveat is missing");
  }
}

function printCommands(officialPoolManager: string | undefined): void {
  const poolManager = officialPoolManager ?? "<official PoolManager from populated input>";

  console.log("");
  console.log("official hook redeploy command templates");
  console.log("1. FxHedgeHook:");
  console.log(`   POOL_MANAGER=${poolManager} forge script contracts/script/DeployFxHedgeHookAndPools.s.sol:DeployFxHedgeHookAndPools --root contracts --rpc-url $OFFICIAL_ARC_RPC_URL -vv`);
  console.log("2. FxSwapHook, run once per vault-backed pair:");
  console.log(`   POOL_MANAGER=${poolManager} FX_VAULT=<official SharedFxVault> forge script contracts/script/DeployFxSwapHook.s.sol:DeployFxSwapHook --root contracts --rpc-url $OFFICIAL_ARC_RPC_URL -vv`);
  console.log("3. TelaranaGatewayHubHook:");
  console.log(`   POOL_MANAGER=${poolManager} forge script contracts/script/DeployTelaranaGatewayHubHook.s.sol:DeployTelaranaGatewayHubHook --sig 'runCreate2()' --root contracts --rpc-url $OFFICIAL_ARC_RPC_URL -vv`);
  console.log("");
  console.log("All commands above simulate unless the operator explicitly adds --broadcast.");
}

function main(): void {
  const inputPath = officialInputPath();
  console.log("Official Arc hook remine/redeploy plan");
  console.log(`manifest ${MANIFEST}`);
  console.log(`official input ${inputPath}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const manifest = readJson(MANIFEST);
  const officialInput = readJson(inputPath);
  const officialPoolManager = checkOfficialPoolManager(manifest, officialInput);

  checkFxHedge(manifest);
  checkFxSwap(manifest);
  checkGateway(manifest);
  printCommands(officialPoolManager);

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
