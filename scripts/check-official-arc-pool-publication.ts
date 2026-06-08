// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only validator for the official Arc pool publication input.
// The default template stays pending until official Uniswap Arc v4 addresses,
// official hook redeploys, pool initialization txs, and first-liquidity txs are
// available. A populated file can be checked with OFFICIAL_ARC_POOL_PUBLICATION_INPUT.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createPublicClient, decodeEventLog, encodeAbiParameters, http, keccak256, parseAbiItem } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEFAULT_INPUT = "deployments/uniswap-v4-official-arc-pools.template.json";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;
const ZERO_BYTES32_RE = /^0x0{64}$/i;
const LOW_14_MASK = 0x3fffn;
const OFFICIAL_ARC_RPC_ENV = "OFFICIAL_ARC_RPC_URL";

const initializeEvent = parseAbiItem(
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)",
);
const modifyLiquidityEvent = parseAbiItem(
  "event ModifyLiquidity(bytes32 indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)",
);

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
  "routerExecution",
  "stateViewVerification",
  "subgraphVerification",
  "receiptVerification",
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
  return process.env.OFFICIAL_ARC_POOL_PUBLICATION_INPUT || DEFAULT_INPUT;
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

function isFilledString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function diagnosticEvidenceIsPopulated(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;

  const evidence = value as AnyRecord;
  const status = String(evidence.status ?? evidence.result ?? "").toLowerCase();
  const hasResult = /pass|passed|supported|proven/.test(status);
  const hasContext = [
    evidence.command,
    evidence.quoter,
    evidence.poolManager,
    evidence.hookData,
    evidence.note,
  ].some(isFilledString);

  return hasResult && hasContext;
}

function executionEvidenceIsPopulated(value: unknown, pool: AnyRecord, requireVerifiedEvidence: boolean): boolean {
  if (!value || typeof value !== "object") return false;

  const evidence = value as AnyRecord;
  const status = String(evidence.status ?? evidence.result ?? "").toLowerCase();
  const hasResult = /pass|passed|supported|proven|verified|prepared/.test(status)
    && !/unsupported|not-supported|fail|failed/.test(status);
  const hasContext = [
    evidence.command,
    evidence.universalRouter,
    evidence.permit2,
    evidence.poolManager,
    evidence.planner,
    evidence.hookData,
    evidence.note,
  ].some(isFilledString);

  if (!hasResult || !hasContext) return false;

  if (requireVerifiedEvidence && isAddress(pool.poolManager) && isAddress(evidence.poolManager)) {
    if (!sameAddress(evidence.poolManager, pool.poolManager)) return false;
  }

  if (requireVerifiedEvidence && isBytes32(pool.poolId) && isBytes32(evidence.poolId)) {
    if (!sameBytes32(evidence.poolId, pool.poolId)) return false;
  }

  return true;
}

function routerStatusHasExactInputEvidence(status: AnyRecord, requireVerifiedEvidence: boolean): boolean {
  const diagnosticEvidence = [
    status.officialV4QuoterExactInputDiagnostic,
    status.targetV4QuoterExactInputDiagnostic,
    status.v4QuoterExactInputDiagnostic,
    status.v4QuoterDiagnostic,
    status.quoterDiagnostic,
  ].some(diagnosticEvidenceIsPopulated);

  if (diagnosticEvidence) return true;
  if (requireVerifiedEvidence) return false;

  const exactInput = String(status.exactInput ?? status.officialExactInput ?? "").toLowerCase();
  return /support|pass|proven|fixture/.test(exactInput) && !/unsupported|not-supported/.test(exactInput);
}

function routerStatusHasCustomRouteCaveat(status: AnyRecord): boolean {
  return [
    status.customRouteCaveat,
    status.settlementCaveat,
    status.hookData,
    status.genericV4Quoter,
  ]
    .filter(isFilledString)
    .some((value) => /not-generic|custom|required|attestation|gateway|settlement|protocol router|direct quote/i.test(value));
}

function routerExecutionHasEvidence(pool: AnyRecord, status: AnyRecord, requireVerifiedEvidence: boolean): boolean {
  const candidates = [
    pool.routerExecution,
    pool.routerExecution?.universalRouterExecution,
    pool.routerExecution?.universalRouterDiagnostic,
    pool.routerExecution?.v4PlannerExecution,
    pool.routerExecution?.routeExecutionDiagnostic,
    status.routerExecution,
    status.universalRouterExecution,
    status.universalRouterDiagnostic,
    status.v4PlannerExecution,
    status.routeExecutionDiagnostic,
  ];

  if (candidates.some((evidence) => executionEvidenceIsPopulated(evidence, pool, requireVerifiedEvidence))) {
    return true;
  }

  if (requireVerifiedEvidence) return false;

  const textEvidence = [
    pool.routerExecution,
    status.exactInput,
    status.officialExactInput,
    status.supportedInternalQuote,
  ]
    .filter(isFilledString)
    .join("\n")
    .toLowerCase();

  return /universal router|v4planner|protocol router|exact-input|supported|fixture/.test(textEvidence)
    && !/unsupported|not-supported|fail|failed/.test(textEvidence);
}

function routerExecutionHasCustomRouteCaveat(pool: AnyRecord, status: AnyRecord): boolean {
  const execution = pool.routerExecution && typeof pool.routerExecution === "object"
    ? pool.routerExecution
    : {};

  return [
    execution.customRouteCaveat,
    execution.settlementCaveat,
    execution.hookData,
    execution.targetRequirement,
    status.customRouteCaveat,
    status.settlementCaveat,
    status.hookData,
    status.genericV4Quoter,
    status.targetRequirement,
  ]
    .filter(isFilledString)
    .some((value) => /not-generic|custom|required|attestation|gateway|settlement|protocol router|direct quote/i.test(value));
}

function checkRouterQuoterStatus(pool: AnyRecord, requireVerifiedEvidence: boolean): void {
  const label = `${pool.family ?? "unknown"} ${pool.symbol ?? pool.poolId ?? "unknown"}`;
  const status = pool.routerQuoterStatus;

  if (status && typeof status === "object") {
    pass(`${label} router/quoter status is recorded`);
  } else {
    fail(`${label} router/quoter status is missing`);
    return;
  }

  const exactInputEvidence = routerStatusHasExactInputEvidence(status, requireVerifiedEvidence);
  const customRouteCaveat = routerStatusHasCustomRouteCaveat(status);

  if (String(pool.family) === "FxHedgeHook" && requireVerifiedEvidence) {
    if (exactInputEvidence) pass(`${label} official exact-input Quoter evidence is recorded`);
    else fail(`${label} ready publication requires official exact-input Quoter evidence`);
    return;
  }

  if (exactInputEvidence || customRouteCaveat) {
    pass(`${label} router/quoter evidence has exact-input proof or a custom-route caveat`);
  } else {
    fail(`${label} router/quoter evidence must include exact-input proof or a custom-route caveat`);
  }
}

function checkRouterExecutionStatus(pool: AnyRecord, requireVerifiedEvidence: boolean): void {
  const label = `${pool.family ?? "unknown"} ${pool.symbol ?? pool.poolId ?? "unknown"}`;
  const status = pool.routerQuoterStatus;

  if (!status || typeof status !== "object") {
    fail(`${label} router execution cannot be checked without routerQuoterStatus`);
    return;
  }

  if (pool.routerExecution && typeof pool.routerExecution === "object") {
    pass(`${label} routerExecution is recorded`);
  } else {
    fail(`${label} routerExecution is missing`);
    return;
  }

  const executionEvidence = routerExecutionHasEvidence(pool, status, requireVerifiedEvidence);
  const customRouteCaveat = routerExecutionHasCustomRouteCaveat(pool, status);

  if (String(pool.family) === "FxHedgeHook" && requireVerifiedEvidence) {
    if (executionEvidence) pass(`${label} official Universal Router execution evidence is recorded`);
    else fail(`${label} ready publication requires official Universal Router execution evidence`);
    return;
  }

  if (executionEvidence || customRouteCaveat) {
    pass(`${label} router execution has Universal Router proof or a custom-route caveat`);
  } else {
    fail(`${label} router execution must include Universal Router proof or a custom-route caveat`);
  }
}

function collectPoolTemplates(manifest: AnyRecord): AnyRecord[] {
  const templates: AnyRecord[] = [];
  for (const family of manifest.hookFamilies ?? []) {
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
        sourceInitializeTx: pool.initializeTx,
      });
    }
  }
  return templates;
}

function checkPoolTemplates(manifest: AnyRecord, input: AnyRecord): void {
  const templates = collectPoolTemplates(manifest);
  if (templates.length === Number(input.expectedPoolTemplateCount)) {
    pass(`official pool publication input expects ${templates.length} source pool templates`);
  } else {
    fail(`official pool publication expected ${input.expectedPoolTemplateCount} templates, manifest has ${templates.length}`);
  }

  if (input.poolTemplatesFromManifest === true) {
    pass("official pool publication input derives source pool templates from manifest");
  } else {
    fail("official pool publication input must derive source pool templates from manifest");
  }

  for (const template of templates) {
    const key = template.sourcePoolKey ?? {};
    if (
      isAddress(key.currency0)
      && isAddress(key.currency1)
      && isAddress(key.hooks)
      && Number.isInteger(Number(key.fee))
      && Number.isInteger(Number(key.tickSpacing))
      && isBytes32(template.sourcePoolId)
    ) {
      pass(`${template.family} ${template.symbol} source PoolKey template is complete`);
    } else {
      fail(`${template.family} ${template.symbol} source PoolKey template is incomplete`);
    }
  }
}

function templateKey(family: unknown, symbol: unknown): string {
  return `${String(family ?? "").toLowerCase()}::${String(symbol ?? "").toLowerCase()}`;
}

function checkOfficialPool(
  pool: AnyRecord,
  sourceTemplate: AnyRecord | undefined,
  officialPoolManager: string | undefined,
  requireVerifiedEvidence: boolean,
): void {
  const label = `${pool.family ?? "unknown"} ${pool.symbol ?? pool.poolId ?? "unknown"}`;
  const key = pool.poolKey ?? {};
  const stateViewEvidence = pool.stateViewVerification ?? {};
  const subgraphEvidence = pool.subgraphVerification ?? {};
  const receiptEvidence = pool.receiptVerification ?? {};

  if (typeof pool.family === "string" && pool.family.length > 0) pass(`${label} family is recorded`);
  else fail(`${label} family is missing`);

  if (typeof pool.symbol === "string" && pool.symbol.length > 0) pass(`${label} symbol is recorded`);
  else fail(`${label} symbol is missing`);

  if (sourceTemplate) pass(`${label} matches a source Arc-testnet pool template`);
  else fail(`${label} does not match a source Arc-testnet pool template`);

  if (isAddress(pool.poolManager)) pass(`${label} official PoolManager address is valid`);
  else fail(`${label} official PoolManager address is missing or invalid`);

  if (isAddress(pool.poolManager) && officialPoolManager) {
    if (sameAddress(pool.poolManager, officialPoolManager)) {
      pass(`${label} PoolManager matches the official deployment input`);
    } else {
      fail(`${label} PoolManager ${pool.poolManager} does not match official input ${officialPoolManager}`);
    }
  }

  if (isAddress(pool.poolManager) && isAddress(sourceTemplate?.sourcePoolManager)) {
    if (sameAddress(pool.poolManager, sourceTemplate.sourcePoolManager)) {
      fail(`${label} reuses the self-deployed Arc-testnet PoolManager`);
    } else {
      pass(`${label} does not reuse the self-deployed Arc-testnet PoolManager`);
    }
  }

  if (isAddress(pool.hookAddress)) pass(`${label} official hook address is valid`);
  else fail(`${label} official hook address is missing or invalid`);

  if (isAddress(pool.hookAddress) && Number.isInteger(Number(sourceTemplate?.expectedHookBits))) {
    const expected = Number(sourceTemplate.expectedHookBits);
    const actual = low14Bits(pool.hookAddress);
    if (actual === expected) pass(`${label} official hook permission bits match ${expected}`);
    else fail(`${label} official hook permission bits ${actual} do not match ${expected}`);
  }

  if (
    isAddress(key.currency0)
    && isAddress(key.currency1)
    && isAddress(key.hooks)
    && Number.isInteger(Number(key.fee))
    && Number.isInteger(Number(key.tickSpacing))
  ) {
    pass(`${label} official PoolKey is complete`);
  } else {
    fail(`${label} official PoolKey is incomplete`);
  }

  if (sameAddress(key.hooks, pool.hookAddress)) {
    pass(`${label} official PoolKey hooks match hookAddress`);
  } else {
    fail(`${label} official PoolKey hooks do not match hookAddress`);
  }

  if (isAddress(key.hooks) && Number.isInteger(Number(sourceTemplate?.expectedHookBits))) {
    const expected = Number(sourceTemplate.expectedHookBits);
    const actual = low14Bits(key.hooks);
    if (actual === expected) pass(`${label} official PoolKey hooks permission bits match ${expected}`);
    else fail(`${label} official PoolKey hooks permission bits ${actual} do not match ${expected}`);
  }

  if (isBytes32(pool.poolId) && isAddress(key.currency0) && isAddress(key.currency1) && isAddress(key.hooks)) {
    const computed = poolIdFromKey(
      key.currency0,
      key.currency1,
      Number(key.fee),
      Number(key.tickSpacing),
      key.hooks,
    );
    if (sameBytes32(computed, pool.poolId)) pass(`${label} official poolId matches PoolKey`);
    else fail(`${label} official poolId ${pool.poolId} does not match PoolKey-derived ${computed}`);
  } else {
    fail(`${label} official poolId cannot be verified`);
  }

  if (isNonZeroBytes32(pool.initializeTx)) pass(`${label} initialize tx is published`);
  else fail(`${label} initialize tx is missing`);

  if (pool.routerActiveClaim === false) {
    if (pool.firstLiquidityTx == null) warn(`${label} is not claiming router-active liquidity yet`);
    else if (isNonZeroBytes32(pool.firstLiquidityTx)) pass(`${label} first liquidity tx is published`);
    else fail(`${label} first liquidity tx is invalid`);
  } else if (isNonZeroBytes32(pool.firstLiquidityTx)) {
    pass(`${label} first liquidity tx is published for router-active claim`);
  } else {
    fail(`${label} first liquidity tx is required before router-active claims`);
  }

  checkRouterQuoterStatus(pool, requireVerifiedEvidence);
  checkRouterExecutionStatus(pool, requireVerifiedEvidence);

  if (pool.stateViewVerification?.status === "verified") pass(`${label} StateView verification is recorded`);
  else fail(`${label} StateView verification must be verified before official indexing readiness claims`);

  if (requireVerifiedEvidence) {
    const sqrtPriceX96 = pool.sqrtPriceX96 ?? stateViewEvidence.sqrtPriceX96 ?? stateViewEvidence.slot0?.sqrtPriceX96;
    const liquidity = pool.liquidity ?? stateViewEvidence.liquidity;

    if (isPositiveBigIntLike(sqrtPriceX96)) pass(`${label} StateView evidence has nonzero sqrtPriceX96`);
    else fail(`${label} ready publication requires nonzero StateView sqrtPriceX96 evidence`);

    if (isPositiveBigIntLike(liquidity)) pass(`${label} StateView evidence has nonzero liquidity`);
    else fail(`${label} ready publication requires nonzero StateView liquidity evidence`);
  }

  if (pool.subgraphVerification?.status === "verified") pass(`${label} subgraph verification is recorded`);
  else fail(`${label} subgraph verification must be verified before official indexing readiness claims`);

  if (requireVerifiedEvidence) {
    const subgraphId = subgraphEvidence.id ?? subgraphEvidence.poolId;
    const subgraphHooks = subgraphEvidence.hooks ?? subgraphEvidence.hookAddress;
    const token0 = evidenceTokenAddress(subgraphEvidence.token0);
    const token1 = evidenceTokenAddress(subgraphEvidence.token1);
    const feeTier = subgraphEvidence.feeTier ?? subgraphEvidence.fee;
    const tickSpacing = subgraphEvidence.tickSpacing;

    if (sameBytes32(subgraphId, pool.poolId)) pass(`${label} subgraph evidence id matches poolId`);
    else fail(`${label} ready publication requires matching subgraph pool id evidence`);

    if (sameAddress(subgraphHooks, pool.hookAddress)) pass(`${label} subgraph evidence hooks match hookAddress`);
    else fail(`${label} ready publication requires matching subgraph hooks evidence`);

    if (sameAddress(token0, key.currency0)) pass(`${label} subgraph evidence token0 matches PoolKey`);
    else fail(`${label} ready publication requires matching subgraph token0 evidence`);

    if (sameAddress(token1, key.currency1)) pass(`${label} subgraph evidence token1 matches PoolKey`);
    else fail(`${label} ready publication requires matching subgraph token1 evidence`);

    if (sameBigIntString(feeTier, key.fee)) pass(`${label} subgraph evidence feeTier matches PoolKey`);
    else fail(`${label} ready publication requires matching subgraph feeTier evidence`);

    if (sameBigIntString(tickSpacing, key.tickSpacing)) pass(`${label} subgraph evidence tickSpacing matches PoolKey`);
    else fail(`${label} ready publication requires matching subgraph tickSpacing evidence`);

    if (subgraphEvidence.sqrtPrice != null && subgraphEvidence.tick != null) {
      pass(`${label} subgraph evidence carries price state`);
    } else {
      fail(`${label} ready publication requires subgraph price state evidence`);
    }

    if (isPositiveBigIntLike(subgraphEvidence.liquidity)) pass(`${label} subgraph evidence has nonzero liquidity`);
    else fail(`${label} ready publication requires nonzero subgraph liquidity evidence`);

    if (receiptEvidence.initializeTxVerified === true) pass(`${label} initialize receipt verification flag is true`);
    else fail(`${label} ready publication requires initialize receipt verification`);

    if (receiptEvidence.firstLiquidityTxVerified === true) pass(`${label} first-liquidity receipt verification flag is true`);
    else fail(`${label} ready publication requires first-liquidity receipt verification`);
  }
}

async function verifyOfficialInitializeReceipt(client: ReturnType<typeof createPublicClient>, pool: AnyRecord): Promise<void> {
  const label = `${pool.family ?? "unknown"} ${pool.symbol ?? pool.poolId ?? "unknown"}`;
  const key = pool.poolKey ?? {};

  if (!isNonZeroBytes32(pool.initializeTx)) {
    fail(`${label} initialize receipt cannot be checked without a nonzero initializeTx`);
    return;
  }

  const receipt = await client.getTransactionReceipt({ hash: pool.initializeTx as `0x${string}` });
  if (receipt.status === "success") pass(`${label} initialize receipt succeeded`);
  else fail(`${label} initialize receipt status is ${receipt.status}`);

  const initializeLogs = receipt.logs
    .filter((log) => sameAddress(log.address, pool.poolManager))
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
  if (sameAddress(match.args.currency0, key.currency0)) pass(`${label} Initialize.currency0 matches PoolKey`);
  else fail(`${label} Initialize.currency0 mismatch`);

  if (sameAddress(match.args.currency1, key.currency1)) pass(`${label} Initialize.currency1 matches PoolKey`);
  else fail(`${label} Initialize.currency1 mismatch`);

  if (Number(match.args.fee) === Number(key.fee)) pass(`${label} Initialize.fee matches PoolKey`);
  else fail(`${label} Initialize.fee mismatch`);

  if (Number(match.args.tickSpacing) === Number(key.tickSpacing)) pass(`${label} Initialize.tickSpacing matches PoolKey`);
  else fail(`${label} Initialize.tickSpacing mismatch`);

  if (sameAddress(match.args.hooks, key.hooks)) pass(`${label} Initialize.hooks matches PoolKey`);
  else fail(`${label} Initialize.hooks mismatch`);

  const expectedSqrt = pool.sqrtPriceX96
    ?? pool.stateViewVerification?.sqrtPriceX96
    ?? pool.stateViewVerification?.slot0?.sqrtPriceX96;
  if (expectedSqrt == null || sameBigIntString(match.args.sqrtPriceX96, expectedSqrt)) {
    pass(`${label} Initialize.sqrtPriceX96 matches published evidence or is unconstrained`);
  } else {
    fail(`${label} Initialize.sqrtPriceX96 mismatch`);
  }
}

async function verifyOfficialFirstLiquidityReceipt(
  client: ReturnType<typeof createPublicClient>,
  pool: AnyRecord,
): Promise<void> {
  const label = `${pool.family ?? "unknown"} ${pool.symbol ?? pool.poolId ?? "unknown"}`;

  if (pool.routerActiveClaim === false && pool.firstLiquidityTx == null) {
    warn(`${label} skips first-liquidity receipt check because routerActiveClaim=false`);
    return;
  }

  if (!isNonZeroBytes32(pool.firstLiquidityTx)) {
    fail(`${label} first-liquidity receipt cannot be checked without a nonzero firstLiquidityTx`);
    return;
  }

  const receipt = await client.getTransactionReceipt({ hash: pool.firstLiquidityTx as `0x${string}` });
  if (receipt.status === "success") pass(`${label} first-liquidity receipt succeeded`);
  else fail(`${label} first-liquidity receipt status is ${receipt.status}`);

  const modifyLogs = receipt.logs
    .filter((log) => sameAddress(log.address, pool.poolManager))
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

  if (match) pass(`${label} first-liquidity receipt emitted positive PoolManager ModifyLiquidity`);
  else fail(`${label} first-liquidity receipt did not emit positive ModifyLiquidity for poolId`);
}

async function verifyOfficialPoolReceipts(officialPools: AnyRecord[], requireRpc: boolean): Promise<void> {
  const rpcUrl = process.env[OFFICIAL_ARC_RPC_ENV];
  if (!rpcUrl) {
    if (requireRpc) {
      fail(`${OFFICIAL_ARC_RPC_ENV} is required before a ready official pool publication can pass`);
    } else {
      warn(`${OFFICIAL_ARC_RPC_ENV} not set; skipping official PoolManager receipt checks for draft input`);
    }
    return;
  }

  pass("official Arc RPC is configured for PoolManager receipt checks");
  const client = createPublicClient({ transport: http(rpcUrl) });
  for (const pool of officialPools) {
    await verifyOfficialInitializeReceipt(client, pool);
    await verifyOfficialFirstLiquidityReceipt(client, pool);
  }
}

async function main(): Promise<void> {
  const relativePath = inputPath();
  console.log("Official Arc Uniswap v4 pool publication check");
  console.log(`input ${relativePath}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const manifest = readJson(MANIFEST);
  const input = readJson(relativePath);
  const deploymentInput = typeof input.sourceDeploymentInput === "string" ? readJson(input.sourceDeploymentInput) : {};
  const pending = input.status === "pending-official-uniswap-v4-addresses";
  const ready = input.status === "ready";
  const draft = input.status === "draft";
  const officialPoolManager = isAddress(deploymentInput.contracts?.PoolManager)
    ? deploymentInput.contracts.PoolManager
    : undefined;

  if (input.schemaVersion === 1) pass("official pool publication schemaVersion is 1");
  else fail("official pool publication schemaVersion must be 1");

  if (input.network === "arc-mainnet") pass("official pool publication targets arc-mainnet");
  else fail("official pool publication must target arc-mainnet");

  if (input.sourceManifest === MANIFEST) pass("official pool publication points at readiness manifest");
  else fail("official pool publication must point at readiness manifest");

  if (typeof input.sourceDeploymentInput === "string" && existsSync(join(ROOT, input.sourceDeploymentInput))) {
    pass("official pool publication points at an existing deployment input template");
  } else {
    fail("official pool publication deployment input reference is missing");
  }

  checkPoolTemplates(manifest, input);

  const fields = new Set<string>(input.requiredPoolFields ?? []);
  for (const field of requiredPoolFields) {
    if (fields.has(field)) pass(`official pool publication requires ${field}`);
    else fail(`official pool publication is missing required field ${field}`);
  }

  const officialPools = Array.isArray(input.officialPools) ? input.officialPools : [];
  if (pending) {
    pass("official pool publication is explicitly pending official addresses");
    if (input.chainId == null) pass("official pool publication chainId is intentionally unset while pending");
    else fail("official pool publication chainId must stay unset while pending");

    if (officialPools.length === 0) pass("official pool publication list is intentionally empty while pending");
    else fail("official pool publication list must stay empty while pending");

    warn("official pool publication remains pending until official Arc pools are deployed, initialized, liquid, and verified");
  } else {
    if (ready) pass("official pool publication is marked ready");
    else if (draft) warn("official pool publication is a populated draft and cannot be used for readiness claims");
    else fail("official pool publication status must be pending, draft, or ready");

    if (typeof input.chainId === "number") pass(`official pool publication chainId is ${input.chainId}`);
    else fail("official pool publication chainId is missing");

    if (typeof input.retrievedAt === "string" && input.retrievedAt.length > 0) {
      pass("official pool publication records retrievedAt");
    } else {
      fail("official pool publication must record retrievedAt when populated");
    }

    if (officialPoolManager) pass("official PoolManager is populated from the deployment input");
    else fail("official PoolManager must be populated in sourceDeploymentInput before pool publication");

    if (officialPools.length > 0) pass(`official pool publication has ${officialPools.length} official pool records`);
    else fail("official pool publication has no official pool records");

    if (officialPools.length === Number(input.expectedPoolTemplateCount)) {
      pass("official pool publication record count matches the source template count");
    } else {
      fail(`official pool publication has ${officialPools.length} records; expected ${input.expectedPoolTemplateCount}`);
    }

    const templates = new Map<string, AnyRecord>();
    for (const template of collectPoolTemplates(manifest)) {
      templates.set(templateKey(template.family, template.symbol), template);
    }

    const poolIds = new Set<string>();
    const labels = new Set<string>();
    for (const pool of officialPools) {
      const poolLabel = templateKey(pool.family, pool.symbol);
      if (labels.has(poolLabel)) fail(`${pool.family ?? "unknown"} ${pool.symbol ?? "unknown"} is duplicated`);
      else {
        labels.add(poolLabel);
        pass(`${pool.family ?? "unknown"} ${pool.symbol ?? "unknown"} publication label is unique`);
      }

      if (isBytes32(pool.poolId)) {
        const normalizedPoolId = pool.poolId.toLowerCase();
        if (poolIds.has(normalizedPoolId)) fail(`${pool.poolId} is duplicated in official pool publication`);
        else {
          poolIds.add(normalizedPoolId);
          pass(`${pool.poolId} official poolId is unique`);
        }
      }

      checkOfficialPool(pool, templates.get(poolLabel), officialPoolManager, ready);
    }

    await verifyOfficialPoolReceipts(officialPools, ready);
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
