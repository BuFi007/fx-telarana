// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only validator for official Uniswap v4 pool publication records across
// Arc, Avalanche Fuji, Avalanche, and Arbitrum. This makes official contract
// availability separate from target-chain hook pool indexing claims.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createPublicClient, decodeEventLog, encodeAbiParameters, http, keccak256, parseAbiItem } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const DEFAULT_INPUT = "deployments/uniswap-v4-official-multichain-pools.template.json";
const READINESS_MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const INPUT_ENV = "OFFICIAL_MULTICHAIN_POOL_PUBLICATION_INPUT";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;
const ZERO_BYTES32_RE = /^0x0{64}$/i;
const LOW_14_MASK = 0x3fffn;

const requiredNetworks = [
  "arc-mainnet",
  "avalanche-fuji",
  "avalanche",
  "arbitrum-one",
] as const;

const requiredPoolFields = [
  "family",
  "symbol",
  "poolManager",
  "hookAddress",
  "poolId",
  "poolKey",
  "initializeTx",
  "firstLiquidityTx",
  "routerActiveClaim",
  "routerQuoterStatus",
  "stateViewVerification",
  "subgraphVerification",
  "receiptVerification",
] as const;

const initializeEvent = parseAbiItem(
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)",
);
const modifyLiquidityEvent = parseAbiItem(
  "event ModifyLiquidity(bytes32 indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)",
);

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
  return process.env[INPUT_ENV] || DEFAULT_INPUT;
}

function readJson(relativePath: string): AnyRecord {
  const absolutePath = join(ROOT, relativePath);
  if (!existsSync(absolutePath)) {
    fail(`missing JSON file ${relativePath}`);
    return {};
  }

  return JSON.parse(readFileSync(absolutePath, "utf-8"));
}

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value) && !ZERO_ADDRESS_RE.test(value);
}

function isBytes32(value: unknown): value is string {
  return typeof value === "string" && BYTES32_RE.test(value);
}

function isNonZeroBytes32(value: unknown): value is string {
  return isBytes32(value) && !ZERO_BYTES32_RE.test(value);
}

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function sameBytes32(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function low14Bits(address: string): number {
  return Number(BigInt(address) & LOW_14_MASK);
}

function poolIdFromKey(currency0: string, currency1: string, fee: number, tickSpacing: number, hooks: string): string {
  return keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [currency0 as `0x${string}`, currency1 as `0x${string}`, fee, tickSpacing, hooks as `0x${string}`],
  ));
}

function sameBigIntString(a: unknown, b: unknown): boolean {
  try {
    if (a == null || b == null || a === "") return false;
    return BigInt(String(a)) === BigInt(String(b));
  } catch {
    return false;
  }
}

function isPositiveBigIntLike(value: unknown): boolean {
  try {
    if (value == null || value === "") return false;
    return BigInt(String(value)) > 0n;
  } catch {
    return false;
  }
}

function evidenceTokenAddress(value: unknown): unknown {
  if (typeof value === "string") return value;
  if (value && typeof value === "object" && "id" in value) return (value as AnyRecord).id;
  return undefined;
}

function targetKey(network: unknown, family: unknown, symbol: unknown): string {
  return `${String(network ?? "").toLowerCase()}::${String(family ?? "").toLowerCase()}::${String(symbol ?? "").toLowerCase()}`;
}

function collectSourcePoolTemplates(readiness: AnyRecord): AnyRecord[] {
  const templates: AnyRecord[] = [];
  for (const family of readiness.hookFamilies ?? []) {
    if (family.deployed === false) continue;
    for (const pool of family.pools ?? []) {
      const hooks = pool.hookAddress ?? family.hookAddress;
      if (!isBytes32(pool.poolId) || !isAddress(hooks)) continue;
      templates.push({
        family: family.name,
        symbol: pool.symbol,
        sourcePoolManager: family.poolManager,
        sourceHookAddress: hooks,
        expectedHookBits: family.permissionFlagsLow14Bits,
        sourcePoolId: pool.poolId,
        sourcePoolKey: {
          currency0: pool.currency0,
          currency1: pool.currency1,
          fee: pool.fee,
          tickSpacing: pool.tickSpacing,
          hooks,
        },
      });
    }
  }
  return templates;
}

function collectSelfPoolManagers(multichain: AnyRecord, readiness: AnyRecord): string[] {
  const managers = new Set<string>();
  for (const manager of Object.values(readiness.arcTestnet?.poolManagers ?? {}) as AnyRecord[]) {
    if (isAddress(manager.address)) managers.add(manager.address.toLowerCase());
  }
  for (const address of multichain.selfDeployedPoolManagers?.arcTestnet ?? []) {
    if (isAddress(address)) managers.add(address.toLowerCase());
  }
  const fuji = multichain.selfDeployedPoolManagers?.avalancheFujiRehearsalPoolManager;
  if (isAddress(fuji)) managers.add(fuji.toLowerCase());
  return [...managers];
}

function findMultichainTarget(multichain: AnyRecord, network: string): AnyRecord | undefined {
  return (multichain.targets ?? []).find((target: AnyRecord) => target.network === network);
}

function checkInputShape(input: AnyRecord, sourceTemplates: AnyRecord[]): void {
  if (input.schemaVersion === 1) pass("pool publication schemaVersion is 1");
  else fail("pool publication schemaVersion must be 1");

  if (input.sourceManifest === READINESS_MANIFEST) pass("pool publication points at readiness manifest");
  else fail("pool publication sourceManifest is wrong");

  if (input.sourceMultichainManifest === MULTICHAIN_MANIFEST) pass("pool publication points at multichain manifest");
  else fail("pool publication sourceMultichainManifest is wrong");

  if (input.expectedPoolTemplateCount === sourceTemplates.length) {
    pass(`pool publication expects ${sourceTemplates.length} source pool templates`);
  } else {
    fail(`pool publication expected ${input.expectedPoolTemplateCount} templates, manifest has ${sourceTemplates.length}`);
  }

  if (input.poolTemplatesFromManifest === true) pass("pool publication derives templates from manifest");
  else fail("pool publication must derive source templates from manifest");

  const fields = new Set<string>(input.requiredPoolFields ?? []);
  for (const field of requiredPoolFields) {
    if (fields.has(field)) pass(`pool publication requires ${field}`);
    else fail(`pool publication required fields missing ${field}`);
  }

  const targetNetworks = new Set((input.targets ?? []).map((target: AnyRecord) => target.network));
  for (const network of requiredNetworks) {
    if (targetNetworks.has(network)) pass(`pool publication includes target ${network}`);
    else fail(`pool publication missing target ${network}`);
  }
}

function checkSourceTemplates(sourceTemplates: AnyRecord[]): void {
  for (const template of sourceTemplates) {
    const key = template.sourcePoolKey ?? {};
    if (
      typeof template.family === "string"
      && typeof template.symbol === "string"
      && isAddress(template.sourceHookAddress)
      && isBytes32(template.sourcePoolId)
      && isAddress(key.currency0)
      && isAddress(key.currency1)
      && isAddress(key.hooks)
      && Number.isInteger(Number(key.fee))
      && Number.isInteger(Number(key.tickSpacing))
    ) {
      pass(`${template.family} ${template.symbol} source pool template is complete`);
    } else {
      fail(`${template.family ?? "unknown"} ${template.symbol ?? "unknown"} source pool template is incomplete`);
    }
  }
}

function checkTargetHeader(target: AnyRecord, sourceTarget: AnyRecord | undefined): void {
  const network = String(target.network ?? "unknown");
  if (sourceTarget) pass(`${network} has a matching multichain deployment target`);
  else {
    fail(`${network} is missing from multichain deployment manifest`);
    return;
  }

  if (target.chainId === sourceTarget.chainId) pass(`${network} chainId matches multichain manifest`);
  else fail(`${network} chainId does not match multichain manifest`);

  if (target.rpcEnv === sourceTarget.rpcEnv) pass(`${network} rpcEnv matches multichain manifest`);
  else fail(`${network} rpcEnv does not match multichain manifest`);

  const sourcePoolManager = sourceTarget.contracts?.PoolManager;
  if (sourceTarget.status === "pending-official-uniswap-v4-addresses") {
    if (target.status === "pending-official-uniswap-v4-addresses") {
      pass(`${network} pool publication stays pending while official addresses are pending`);
    } else {
      fail(`${network} pool publication must stay pending while official addresses are pending`);
    }

    if (target.officialPoolManager == null && sourcePoolManager == null) {
      pass(`${network} official PoolManager is intentionally unset`);
    } else {
      fail(`${network} official PoolManager must stay unset while pending`);
    }
    return;
  }

  if (sourceTarget.status === "official-uniswap-v4-addresses-published") {
    if (isAddress(target.officialPoolManager) && sameAddress(target.officialPoolManager, sourcePoolManager)) {
      pass(`${network} official PoolManager matches the official deployment manifest`);
    } else {
      fail(`${network} official PoolManager must match official deployment manifest`);
    }

    if (["pending-official-hook-pool-publication", "draft", "ready"].includes(String(target.status))) {
      pass(`${network} pool publication status is valid`);
    } else {
      fail(`${network} pool publication status must be pending-official-hook-pool-publication, draft, or ready`);
    }
  }
}

function checkNoSelfPoolManager(target: AnyRecord, selfPoolManagers: string[]): void {
  if (!isAddress(target.officialPoolManager)) return;
  for (const selfPoolManager of selfPoolManagers) {
    if (sameAddress(target.officialPoolManager, selfPoolManager)) {
      fail(`${target.network} official PoolManager reuses self-deployed/rehearsal ${selfPoolManager}`);
    } else {
      pass(`${target.network} official PoolManager does not reuse ${selfPoolManager}`);
    }
  }
}

function checkOfficialPool(
  target: AnyRecord,
  pool: AnyRecord,
  sourceTemplate: AnyRecord | undefined,
  ready: boolean,
  selfPoolManagers: string[],
): void {
  const label = `${target.network} ${pool.family ?? "unknown"} ${pool.symbol ?? pool.poolId ?? "unknown"}`;
  const key = pool.poolKey ?? {};
  const stateView = pool.stateViewVerification ?? {};
  const subgraph = pool.subgraphVerification ?? {};
  const receipt = pool.receiptVerification ?? {};

  if (sourceTemplate) pass(`${label} maps to a source pool template`);
  else fail(`${label} does not map to a source pool template`);

  if (isAddress(pool.poolManager)) pass(`${label} PoolManager address is valid`);
  else fail(`${label} PoolManager address is missing`);

  if (isAddress(pool.poolManager) && sameAddress(pool.poolManager, target.officialPoolManager)) {
    pass(`${label} PoolManager matches target official PoolManager`);
  } else {
    fail(`${label} PoolManager must match target official PoolManager`);
  }

  for (const selfPoolManager of selfPoolManagers) {
    if (sameAddress(pool.poolManager, selfPoolManager)) fail(`${label} reuses self-deployed/rehearsal PoolManager`);
  }

  if (isAddress(pool.hookAddress)) pass(`${label} hookAddress is valid`);
  else fail(`${label} hookAddress is missing`);

  if (isAddress(pool.hookAddress) && Number.isInteger(Number(sourceTemplate?.expectedHookBits))) {
    const expected = Number(sourceTemplate.expectedHookBits);
    const actual = low14Bits(pool.hookAddress);
    if (actual === expected) pass(`${label} hook permission bits match ${expected}`);
    else fail(`${label} hook permission bits ${actual} do not match ${expected}`);
  }

  if (
    isAddress(key.currency0)
    && isAddress(key.currency1)
    && isAddress(key.hooks)
    && Number.isInteger(Number(key.fee))
    && Number.isInteger(Number(key.tickSpacing))
  ) {
    pass(`${label} PoolKey is complete`);
  } else {
    fail(`${label} PoolKey is incomplete`);
  }

  if (sameAddress(key.hooks, pool.hookAddress)) pass(`${label} PoolKey hooks match hookAddress`);
  else fail(`${label} PoolKey hooks must match hookAddress`);

  if (isBytes32(pool.poolId) && isAddress(key.currency0) && isAddress(key.currency1) && isAddress(key.hooks)) {
    const computed = poolIdFromKey(
      key.currency0,
      key.currency1,
      Number(key.fee),
      Number(key.tickSpacing),
      key.hooks,
    );
    if (sameBytes32(computed, pool.poolId)) pass(`${label} poolId matches PoolKey`);
    else fail(`${label} poolId does not match PoolKey-derived ${computed}`);
  } else {
    fail(`${label} poolId cannot be verified`);
  }

  if (isNonZeroBytes32(pool.initializeTx)) pass(`${label} initializeTx is published`);
  else fail(`${label} initializeTx is required`);

  if (pool.routerActiveClaim === false) {
    if (pool.firstLiquidityTx == null) warn(`${label} is not claiming router-active liquidity yet`);
    else if (isNonZeroBytes32(pool.firstLiquidityTx)) pass(`${label} firstLiquidityTx is published`);
    else fail(`${label} firstLiquidityTx is invalid`);
  } else if (isNonZeroBytes32(pool.firstLiquidityTx)) {
    pass(`${label} firstLiquidityTx is published for router-active claim`);
  } else {
    fail(`${label} firstLiquidityTx is required before router-active claims`);
  }

  if (pool.routerQuoterStatus != null) pass(`${label} routerQuoterStatus is recorded`);
  else fail(`${label} routerQuoterStatus is missing`);

  if (stateView.status === "verified") pass(`${label} StateView verification is marked verified`);
  else fail(`${label} StateView verification must be verified`);

  if (subgraph.status === "verified") pass(`${label} subgraph verification is marked verified`);
  else fail(`${label} subgraph verification must be verified`);

  if (ready) {
    const sqrtPriceX96 = pool.sqrtPriceX96 ?? stateView.sqrtPriceX96 ?? stateView.slot0?.sqrtPriceX96;
    const liquidity = pool.liquidity ?? stateView.liquidity;
    if (isPositiveBigIntLike(sqrtPriceX96)) pass(`${label} StateView sqrtPriceX96 is nonzero`);
    else fail(`${label} ready mode requires nonzero StateView sqrtPriceX96`);

    if (isPositiveBigIntLike(liquidity)) pass(`${label} StateView liquidity is nonzero`);
    else fail(`${label} ready mode requires nonzero StateView liquidity`);

    const subgraphId = subgraph.id ?? subgraph.poolId;
    const subgraphHooks = subgraph.hooks ?? subgraph.hookAddress;
    const token0 = evidenceTokenAddress(subgraph.token0);
    const token1 = evidenceTokenAddress(subgraph.token1);
    const feeTier = subgraph.feeTier ?? subgraph.fee;

    if (sameBytes32(subgraphId, pool.poolId)) pass(`${label} subgraph id matches poolId`);
    else fail(`${label} ready mode requires subgraph id matching poolId`);

    if (sameAddress(subgraphHooks, pool.hookAddress)) pass(`${label} subgraph hooks match hookAddress`);
    else fail(`${label} ready mode requires subgraph hooks matching hookAddress`);

    if (sameAddress(token0, key.currency0)) pass(`${label} subgraph token0 matches PoolKey`);
    else fail(`${label} ready mode requires subgraph token0 matching PoolKey`);

    if (sameAddress(token1, key.currency1)) pass(`${label} subgraph token1 matches PoolKey`);
    else fail(`${label} ready mode requires subgraph token1 matching PoolKey`);

    if (sameBigIntString(feeTier, key.fee)) pass(`${label} subgraph feeTier matches PoolKey`);
    else fail(`${label} ready mode requires subgraph feeTier matching PoolKey`);

    if (sameBigIntString(subgraph.tickSpacing, key.tickSpacing)) pass(`${label} subgraph tickSpacing matches PoolKey`);
    else fail(`${label} ready mode requires subgraph tickSpacing matching PoolKey`);

    if (subgraph.sqrtPrice != null && subgraph.tick != null) pass(`${label} subgraph price state is present`);
    else fail(`${label} ready mode requires subgraph price state`);

    if (isPositiveBigIntLike(subgraph.liquidity)) pass(`${label} subgraph liquidity is nonzero`);
    else fail(`${label} ready mode requires nonzero subgraph liquidity`);

    if (receipt.initializeTxVerified === true) pass(`${label} initialize receipt verification flag is true`);
    else fail(`${label} ready mode requires initialize receipt verification`);

    if (receipt.firstLiquidityTxVerified === true) pass(`${label} first-liquidity receipt verification flag is true`);
    else fail(`${label} ready mode requires first-liquidity receipt verification`);
  }
}

async function verifyInitializeReceipt(
  client: ReturnType<typeof createPublicClient>,
  target: AnyRecord,
  pool: AnyRecord,
): Promise<void> {
  const label = `${target.network} ${pool.family ?? "unknown"} ${pool.symbol ?? pool.poolId ?? "unknown"}`;
  if (!isNonZeroBytes32(pool.initializeTx)) {
    fail(`${label} initialize receipt cannot be checked without initializeTx`);
    return;
  }

  const receipt = await client.getTransactionReceipt({ hash: pool.initializeTx as `0x${string}` });
  if (receipt.status === "success") pass(`${label} initialize receipt succeeded`);
  else fail(`${label} initialize receipt status is ${receipt.status}`);

  const initializeLogs = receipt.logs
    .filter((log) => sameAddress(log.address, target.officialPoolManager))
    .flatMap((log) => {
      try {
        return [decodeEventLog({ abi: [initializeEvent], data: log.data, topics: log.topics })];
      } catch {
        return [];
      }
    });

  const match = initializeLogs.find((log) => sameBytes32(log.args.id, pool.poolId));
  if (!match) {
    fail(`${label} initialize receipt did not emit PoolManager Initialize for poolId`);
    return;
  }

  pass(`${label} initialize receipt emitted PoolManager Initialize`);
}

async function verifyFirstLiquidityReceipt(
  client: ReturnType<typeof createPublicClient>,
  target: AnyRecord,
  pool: AnyRecord,
): Promise<void> {
  const label = `${target.network} ${pool.family ?? "unknown"} ${pool.symbol ?? pool.poolId ?? "unknown"}`;
  if (!isNonZeroBytes32(pool.firstLiquidityTx)) {
    fail(`${label} first-liquidity receipt cannot be checked without firstLiquidityTx`);
    return;
  }

  const receipt = await client.getTransactionReceipt({ hash: pool.firstLiquidityTx as `0x${string}` });
  if (receipt.status === "success") pass(`${label} first-liquidity receipt succeeded`);
  else fail(`${label} first-liquidity receipt status is ${receipt.status}`);

  const modifyLogs = receipt.logs
    .filter((log) => sameAddress(log.address, target.officialPoolManager))
    .flatMap((log) => {
      try {
        return [decodeEventLog({ abi: [modifyLiquidityEvent], data: log.data, topics: log.topics })];
      } catch {
        return [];
      }
    });

  const match = modifyLogs.find(
    (log) => sameBytes32(log.args.id, pool.poolId) && BigInt(log.args.liquidityDelta) > 0n,
  );
  if (match) pass(`${label} first-liquidity receipt emitted positive ModifyLiquidity`);
  else fail(`${label} first-liquidity receipt did not emit positive ModifyLiquidity for poolId`);
}

async function verifyReadyReceipts(target: AnyRecord): Promise<void> {
  if (target.status !== "ready") return;

  const rpcEnv = target.rpcEnv;
  const rpcUrl = typeof rpcEnv === "string" ? process.env[rpcEnv] : undefined;
  if (!rpcUrl) {
    fail(`${target.network} ready mode requires ${rpcEnv} for live PoolManager receipt verification`);
    return;
  }

  pass(`${target.network} ready mode has ${rpcEnv} configured`);
  const client = createPublicClient({ transport: http(rpcUrl) });
  for (const pool of target.officialPools ?? []) {
    await verifyInitializeReceipt(client, target, pool);
    await verifyFirstLiquidityReceipt(client, target, pool);
  }
}

async function checkTarget(
  target: AnyRecord,
  sourceTarget: AnyRecord | undefined,
  sourceTemplateByLabel: Map<string, AnyRecord>,
  selfPoolManagers: string[],
): Promise<void> {
  const network = String(target.network ?? "unknown");
  checkTargetHeader(target, sourceTarget);
  checkNoSelfPoolManager(target, selfPoolManagers);

  const pools = Array.isArray(target.officialPools) ? target.officialPools : [];
  if (sourceTarget?.status === "pending-official-uniswap-v4-addresses") {
    if (pools.length === 0) pass(`${network} official pool records are empty while official addresses are pending`);
    else fail(`${network} official pool records must stay empty while official addresses are pending`);
    warn(`${network} pool publication remains pending official Uniswap v4 addresses`);
    return;
  }

  if (target.status === "pending-official-hook-pool-publication") {
    if (pools.length === 0) pass(`${network} official pool records are intentionally empty while hook pools are unpublished`);
    else fail(`${network} pending hook-pool publication must not contain official pool records`);
    warn(`${network} has official v4 contracts but no fx-Telarana official hook pool publication yet`);
    return;
  }

  if (target.status === "draft") warn(`${network} populated pool publication is draft-only and not a readiness claim`);
  if (target.status === "ready") pass(`${network} populated pool publication is marked ready`);

  if (pools.length === sourceTemplateByLabel.size) {
    pass(`${network} official pool count matches source template count`);
  } else {
    fail(`${network} official pool count ${pools.length} does not match ${sourceTemplateByLabel.size}`);
  }

  const labels = new Set<string>();
  const poolIds = new Set<string>();
  for (const pool of pools) {
    const label = targetKey(network, pool.family, pool.symbol);
    if (labels.has(label)) fail(`${network} ${pool.family ?? "unknown"} ${pool.symbol ?? "unknown"} is duplicated`);
    else {
      labels.add(label);
      pass(`${network} ${pool.family ?? "unknown"} ${pool.symbol ?? "unknown"} label is unique`);
    }

    if (isBytes32(pool.poolId)) {
      const id = pool.poolId.toLowerCase();
      if (poolIds.has(id)) fail(`${network} official poolId ${pool.poolId} is duplicated`);
      else {
        poolIds.add(id);
        pass(`${network} official poolId ${pool.poolId} is unique`);
      }
    }

    const sourceTemplate = sourceTemplateByLabel.get(targetKey(network, pool.family, pool.symbol));
    checkOfficialPool(target, pool, sourceTemplate, target.status === "ready", selfPoolManagers);
  }

  await verifyReadyReceipts(target);
}

async function main(): Promise<void> {
  const relativePath = inputPath();
  console.log("Official Uniswap v4 multichain pool publication check");
  console.log(`input ${relativePath}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const input = readJson(relativePath);
  const readiness = readJson(READINESS_MANIFEST);
  const multichain = readJson(MULTICHAIN_MANIFEST);
  const sourceTemplates = collectSourcePoolTemplates(readiness);
  const sourceTemplateByLabel = new Map<string, AnyRecord>();
  for (const network of requiredNetworks) {
    for (const template of sourceTemplates) {
      sourceTemplateByLabel.set(targetKey(network, template.family, template.symbol), template);
    }
  }
  const selfPoolManagers = collectSelfPoolManagers(multichain, readiness);

  checkInputShape(input, sourceTemplates);
  checkSourceTemplates(sourceTemplates);

  const targets = Array.isArray(input.targets) ? input.targets : [];
  const seenTargets = new Set<string>();
  for (const target of targets) {
    const network = String(target.network ?? "");
    if (seenTargets.has(network)) fail(`${network} target is duplicated`);
    else {
      seenTargets.add(network);
      pass(`${network} target is unique`);
    }

    await checkTarget(
      target,
      findMultichainTarget(multichain, network),
      sourceTemplateByLabel,
      selfPoolManagers,
    );
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
