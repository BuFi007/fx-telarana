// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only preflight for remine/redeploying the hook package against official
// Uniswap v4 PoolManagers on every tracked target chain. It never broadcasts.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const READINESS_MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const LOW_14_MASK = 0x3fffn;

const expectedHookBits: Record<string, number> = {
  FxHedgeHook: 1344,
  FxSwapHook: 2760,
  TelaranaGatewayHubHook: 136,
};

const targetOrder = ["arc-mainnet", "avalanche-fuji", "avalanche", "arbitrum-one"] as const;

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

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value) && !ZERO_ADDRESS_RE.test(value);
}

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function low14Bits(address: string): number {
  return Number(BigInt(address) & LOW_14_MASK);
}

function findFamily(readiness: AnyRecord, name: string): AnyRecord | undefined {
  return (readiness.hookFamilies ?? []).find((family: AnyRecord) => family.name === name);
}

function checkFile(relativePath: string, label: string): string {
  const absolutePath = join(ROOT, relativePath);
  if (existsSync(absolutePath)) {
    pass(`${label} exists at ${relativePath}`);
    return readText(relativePath);
  }

  fail(`${label} is missing at ${relativePath}`);
  return "";
}

function checkFamilyBits(readiness: AnyRecord, name: string): void {
  const family = findFamily(readiness, name);
  const expected = expectedHookBits[name];

  if (!family) {
    fail(`${name} source family is missing from readiness manifest`);
    return;
  }

  if (Number(family.permissionFlagsLow14Bits) === expected) {
    pass(`${name} source permission bits match ${expected}`);
  } else {
    fail(`${name} source permission bits must match ${expected}`);
  }

  const addresses = new Set<string>();
  if (isAddress(family.hookAddress)) addresses.add(family.hookAddress);
  for (const pool of family.pools ?? []) {
    if (isAddress(pool.hookAddress)) addresses.add(pool.hookAddress);
  }

  if (addresses.size > 0) pass(`${name} source hook addresses are recorded`);
  else fail(`${name} source hook addresses are missing`);

  for (const address of addresses) {
    if (low14Bits(address) === expected) {
      pass(`${name} source hook ${address} low-14 bits match ${expected}`);
    } else {
      fail(`${name} source hook ${address} low-14 bits do not match ${expected}`);
    }
  }
}

function checkHookDeployScripts(readiness: AnyRecord): void {
  checkFamilyBits(readiness, "FxHedgeHook");
  checkFamilyBits(readiness, "FxSwapHook");
  checkFamilyBits(readiness, "TelaranaGatewayHubHook");

  const hedgeDeploy = checkFile("contracts/script/DeployFxHedgeHookAndPools.s.sol", "FxHedgeHook deploy script");
  checkFile("contracts/script/ConfigureFxHedgeStablePools.s.sol", "FxHedgeHook configure script");
  checkFile("contracts/script/SeedFxHedgeHookLiquidity.s.sol", "FxHedgeHook liquidity script");
  if (hedgeDeploy.includes("POOL_MANAGER") && hedgeDeploy.includes("HookMiner.find")) {
    pass("FxHedgeHook deploy script mines against env-provided POOL_MANAGER");
  } else {
    fail("FxHedgeHook deploy script must mine against env-provided POOL_MANAGER");
  }

  const swapDeploy = checkFile("contracts/script/DeployFxSwapHook.s.sol", "FxSwapHook deploy script");
  const swapBatch = checkFile("contracts/script/DeployVaultBackedAll.s.sol", "FxSwapHook batch deploy script");
  const saltMiner = checkFile("contracts/script/MineHookSalt.s.sol", "shared hook salt miner");
  for (const [label, text] of [
    ["FxSwapHook deploy script", swapDeploy],
    ["shared hook salt miner", saltMiner],
  ] as const) {
    if (text.includes("FX_VAULT") && text.includes("morpho, vault")) {
      pass(`${label} includes the vault-backed constructor shape`);
    } else {
      fail(`${label} must include FX_VAULT and the vault-backed constructor shape`);
    }
  }

  if (swapBatch.includes("MORPHO, VAULT")) {
    pass("FxSwapHook Arc-testnet batch deploy script is vault-backed");
  } else {
    fail("FxSwapHook Arc-testnet batch deploy script must stay vault-backed");
  }

  const gatewayDeploy = checkFile("contracts/script/DeployTelaranaGatewayHubHook.s.sol", "TelaranaGatewayHubHook deploy script");
  if (
    gatewayDeploy.includes("runCreate2")
    && gatewayDeploy.includes("BEFORE_SWAP_FLAG")
    && gatewayDeploy.includes("BEFORE_SWAP_RETURNS_DELTA_FLAG")
  ) {
    pass("TelaranaGatewayHubHook deploy script exposes the CREATE2 permission-bit path");
  } else {
    fail("TelaranaGatewayHubHook deploy script must expose the CREATE2 permission-bit path");
  }

  const gateway = findFamily(readiness, "TelaranaGatewayHubHook");
  if (gateway?.routerQuoterStatus?.genericV4Quoter === "not-generic-hookdata-required") {
    pass("TelaranaGatewayHubHook keeps the hookData-required route caveat");
  } else {
    fail("TelaranaGatewayHubHook hookData-required route caveat is missing");
  }
}

function collectSelfDeployedPoolManagers(multichain: AnyRecord, readiness: AnyRecord): string[] {
  const managers = new Set<string>();

  for (const value of multichain.selfDeployedPoolManagers?.arcTestnet ?? []) {
    if (isAddress(value)) managers.add(value.toLowerCase());
  }

  const rehearsal = multichain.selfDeployedPoolManagers?.avalancheFujiRehearsalPoolManager;
  if (isAddress(rehearsal)) managers.add(rehearsal.toLowerCase());

  for (const manager of Object.values(readiness.arcTestnet?.poolManagers ?? {}) as AnyRecord[]) {
    if (isAddress(manager.address)) managers.add(manager.address.toLowerCase());
  }

  return [...managers];
}

function checkTarget(target: AnyRecord, selfPoolManagers: string[]): void {
  if (targetOrder.includes(target.network)) pass(`${target.network} is a tracked redeploy target`);
  else fail(`${target.network} is not a tracked redeploy target`);

  if (target.status === "pending-official-uniswap-v4-addresses") {
    if (target.contracts && Object.values(target.contracts).every((value) => value == null)) {
      pass(`${target.network} official contracts stay unset while pending`);
    } else {
      fail(`${target.network} pending target must not carry official contracts`);
    }

    warn(`${target.network} hook redeploy cannot proceed until official Uniswap v4 addresses are published`);
    return;
  }

  if (target.status === "official-uniswap-v4-addresses-published") {
    pass(`${target.network} official v4 addresses are published`);
  } else {
    fail(`${target.network} has unexpected official status`);
  }

  if (isAddress(target.contracts?.PoolManager)) {
    pass(`${target.network} official PoolManager address is valid`);
  } else {
    fail(`${target.network} official PoolManager address is missing`);
  }

  if (typeof target.rpcEnv === "string" && target.rpcEnv.length > 0) {
    pass(`${target.network} RPC env var is recorded as ${target.rpcEnv}`);
  } else {
    fail(`${target.network} RPC env var is missing`);
  }

  if (typeof target.publicRpcFallback === "string" && target.publicRpcFallback.startsWith("https://")) {
    pass(`${target.network} public RPC fallback is recorded`);
  } else {
    fail(`${target.network} public RPC fallback is missing`);
  }

  for (const manager of selfPoolManagers) {
    if (sameAddress(target.contracts?.PoolManager, manager)) {
      fail(`${target.network} official PoolManager reuses self-deployed PoolManager ${manager}`);
    } else {
      pass(`${target.network} official PoolManager does not reuse ${manager}`);
    }
  }

  if (target.hookRedeployStatus === "pending-official-hook-redeploy") {
    warn(`${target.network} hook redeploy is pending operator execution`);
  } else {
    fail(`${target.network} hook redeploy status must remain pending until broadcast evidence exists`);
  }

  if (target.poolPublicationStatus === "pending-poolmanager-initialize-and-first-liquidity") {
    pass(`${target.network} pool publication waits for Initialize and first-liquidity evidence`);
  } else {
    fail(`${target.network} pool publication status is not strict enough`);
  }
}

function printTargetCommands(targets: AnyRecord[]): void {
  console.log("");
  console.log("official target-chain hook redeploy command templates");

  for (const target of targets) {
    if (target.status !== "official-uniswap-v4-addresses-published") continue;

    const rpc = `\${${target.rpcEnv}}`;
    const poolManager = target.contracts.PoolManager;
    console.log("");
    console.log(`${target.displayName} (${target.network})`);
    console.log(`1. FxHedgeHook`);
    console.log(`   POOL_MANAGER=${poolManager} forge script contracts/script/DeployFxHedgeHookAndPools.s.sol:DeployFxHedgeHookAndPools --root contracts --rpc-url ${rpc} -vv`);
    console.log(`2. FxSwapHook, run once per vault-backed pair`);
    console.log(`   POOL_MANAGER=${poolManager} FX_VAULT=<target-chain SharedFxVault> forge script contracts/script/DeployFxSwapHook.s.sol:DeployFxSwapHook --root contracts --rpc-url ${rpc} -vv`);
    console.log(`3. TelaranaGatewayHubHook`);
    console.log(`   POOL_MANAGER=${poolManager} forge script contracts/script/DeployTelaranaGatewayHubHook.s.sol:DeployTelaranaGatewayHubHook --sig 'runCreate2()' --root contracts --rpc-url ${rpc} -vv`);
  }

  console.log("");
  console.log("All commands above simulate unless the operator explicitly adds --broadcast.");
}

function commandTemplatesFor(target: AnyRecord): AnyRecord[] {
  if (target.status !== "official-uniswap-v4-addresses-published") return [];

  const rpc = `\${${target.rpcEnv}}`;
  const poolManager = target.contracts.PoolManager;
  return [
    {
      family: "FxHedgeHook",
      command: `POOL_MANAGER=${poolManager} forge script contracts/script/DeployFxHedgeHookAndPools.s.sol:DeployFxHedgeHookAndPools --root contracts --rpc-url ${rpc} -vv`,
      broadcastMode: "simulate-unless-operator-adds---broadcast",
    },
    {
      family: "FxSwapHook",
      command: `POOL_MANAGER=${poolManager} FX_VAULT=<target-chain SharedFxVault> forge script contracts/script/DeployFxSwapHook.s.sol:DeployFxSwapHook --root contracts --rpc-url ${rpc} -vv`,
      broadcastMode: "simulate-unless-operator-adds---broadcast",
      note: "run once per vault-backed pair",
    },
    {
      family: "TelaranaGatewayHubHook",
      command: `POOL_MANAGER=${poolManager} forge script contracts/script/DeployTelaranaGatewayHubHook.s.sol:DeployTelaranaGatewayHubHook --sig 'runCreate2()' --root contracts --rpc-url ${rpc} -vv`,
      broadcastMode: "simulate-unless-operator-adds---broadcast",
    },
  ];
}

function buildRedeployPacket(targets: AnyRecord[]): AnyRecord {
  return {
    schemaVersion: 1,
    status: "redeploy-plan-not-a-readiness-claim",
    sourceManifest: READINESS_MANIFEST,
    sourceMultichainManifest: MULTICHAIN_MANIFEST,
    expectedHookFamilies: Object.keys(expectedHookBits),
    validationSummary: {
      pass: counts.PASS,
      warn: counts.WARN,
      fail: counts.FAIL,
    },
    targets: targets.map((target) => ({
      network: target.network,
      displayName: target.displayName ?? null,
      chainId: target.chainId ?? null,
      status: target.status ?? null,
      poolManager: target.contracts?.PoolManager ?? null,
      rpcEnv: target.rpcEnv ?? null,
      publicRpcFallback: target.publicRpcFallback ?? null,
      hookRedeployStatus: target.hookRedeployStatus ?? null,
      poolPublicationStatus: target.poolPublicationStatus ?? null,
      commandTemplates: commandTemplatesFor(target),
      requiredPostRedeployEvidence: [
        "officialHookAddressWithMatchingLow14Bits",
        "poolManagerInitializeTx",
        "firstLiquidityTx",
        "stateViewSlot0AndLiquidity",
        "subgraphPoolEntity",
        "v4QuoterExactInputDiagnosticOrCustomRouteCaveat",
      ],
    })),
  };
}

function main(): void {
  const outPath = repoRelativePathFor("--out");
  const checkPath = repoRelativePathFor("--check");
  if (outPath && checkPath) throw new Error("use either --out or --check, not both");

  console.log("Official Uniswap v4 multichain hook remine/redeploy plan");
  console.log(`source ${READINESS_MANIFEST}`);
  console.log(`multichain ${MULTICHAIN_MANIFEST}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const readiness = readJson(READINESS_MANIFEST);
  const multichain = readJson(MULTICHAIN_MANIFEST);
  const selfPoolManagers = collectSelfDeployedPoolManagers(multichain, readiness);

  if (readiness.network === "arc-testnet" && readiness.chainId === 5042002) {
    pass("source readiness manifest is Arc testnet");
  } else {
    fail("source readiness manifest must remain Arc testnet");
  }

  if (multichain.schemaVersion === 1) pass("multichain readiness manifest schemaVersion is 1");
  else fail("multichain readiness manifest schemaVersion must be 1");

  if (selfPoolManagers.length >= 3) {
    pass("self-deployed/rehearsal PoolManagers are available for reuse rejection");
  } else {
    fail("self-deployed/rehearsal PoolManagers are missing");
  }

  checkHookDeployScripts(readiness);

  const targets = targetOrder.map((network) => {
    const target = (multichain.targets ?? []).find((entry: AnyRecord) => entry.network === network);
    if (!target) fail(`${network} is missing from multichain readiness manifest`);
    return target ?? { network };
  });

  for (const target of targets) checkTarget(target, selfPoolManagers);

  const packet = buildRedeployPacket(targets);
  const json = `${JSON.stringify(packet, null, 2)}\n`;
  const summary = `summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`;

  if (outPath) {
    const absoluteOutPath = join(ROOT, outPath);
    mkdirSync(dirname(absoluteOutPath), { recursive: true });
    writeFileSync(absoluteOutPath, json);
    console.log("");
    console.log(`wrote ${outPath}`);
    console.log(summary);
    process.exit(counts.FAIL > 0 ? 1 : 0);
  }

  if (checkPath) {
    const current = readFileSync(join(ROOT, checkPath), "utf-8");
    if (current !== json) {
      throw new Error(`${checkPath} is stale; run bun run uniswap:official-multichain:hooks:plan:write`);
    }

    console.log("");
    console.log(`${checkPath} is fresh`);
    console.log(summary);
    process.exit(counts.FAIL > 0 ? 1 : 0);
  }

  printTargetCommands(targets);

  console.log("");
  console.log(summary);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
