// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only verifier for target-chain Uniswap v4 StateView evidence across
// Arc, Avalanche Fuji, Avalanche, and Arbitrum. It validates the pending shape
// today and can read getSlot0/getLiquidity once official pool records exist.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createPublicClient, http, parseAbi } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const DEFAULT_POOL_PUBLICATION_INPUT = "deployments/uniswap-v4-official-multichain-pools.template.json";
const INPUT_ENV = "OFFICIAL_MULTICHAIN_POOL_PUBLICATION_INPUT";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

const requiredNetworks = [
  "arc-mainnet",
  "avalanche-fuji",
  "avalanche",
  "arbitrum-one",
] as const;

const requiredPoolFields = [
  "poolId",
  "currency0",
  "currency1",
  "fee",
  "tickSpacing",
  "hooks",
  "sqrtPriceX96",
  "liquidity",
] as const;

const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128 liquidity)",
]);

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
  return process.env[INPUT_ENV] || DEFAULT_POOL_PUBLICATION_INPUT;
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

function sameBigIntString(a: unknown, b: unknown): boolean {
  try {
    if (a == null || b == null || a === "") return false;
    return BigInt(String(a)) === BigInt(String(b));
  } catch {
    return false;
  }
}

function targetByNetwork(manifest: AnyRecord, network: string): AnyRecord {
  return (manifest.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function publicationTarget(input: AnyRecord, network: string): AnyRecord {
  return (input.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function normalizePool(pool: AnyRecord): AnyRecord {
  const key = pool.poolKey ?? {};
  const stateViewEvidence = pool.stateViewVerification ?? {};

  return {
    ...pool,
    currency0: pool.currency0 ?? key.currency0,
    currency1: pool.currency1 ?? key.currency1,
    fee: pool.fee ?? key.fee,
    tickSpacing: pool.tickSpacing ?? key.tickSpacing,
    hooks: pool.hooks ?? key.hooks ?? pool.hookAddress,
    sqrtPriceX96: pool.sqrtPriceX96 ?? stateViewEvidence.sqrtPriceX96 ?? stateViewEvidence.slot0?.sqrtPriceX96,
    tick: pool.tick ?? stateViewEvidence.tick ?? stateViewEvidence.slot0?.tick,
    liquidity: pool.liquidity ?? stateViewEvidence.liquidity,
  };
}

function rpcUrlFor(target: AnyRecord, publication: AnyRecord): string | undefined {
  const rpcEnv = publication.rpcEnv ?? target.rpcEnv;
  if (typeof rpcEnv === "string" && process.env[rpcEnv]) return process.env[rpcEnv];
  if (typeof target.publicRpcFallback === "string") return target.publicRpcFallback;
  return undefined;
}

function checkStateViewConfig(manifest: AnyRecord): void {
  const stateView = manifest.stateViewVerification ?? {};

  if (typeof stateView.command === "string" && stateView.command.includes("uniswap:official-multichain:stateview:check")) {
    pass("multichain StateView verification command is recorded");
  } else {
    fail("multichain StateView verification command is missing");
  }

  if (stateView.poolPublicationInputEnv === INPUT_ENV) {
    pass(`multichain StateView verification reads ${INPUT_ENV}`);
  } else {
    fail(`multichain StateView verification must record ${INPUT_ENV}`);
  }

  if (stateView.requiredContract === "StateView") {
    pass("multichain StateView verification requires StateView");
  } else {
    fail("multichain StateView verification requiredContract is missing");
  }

  const fields = new Set<string>(stateView.requiredPoolFields ?? []);
  for (const field of requiredPoolFields) {
    if (fields.has(field)) pass(`multichain StateView verification requires pool.${field}`);
    else fail(`multichain StateView verification is missing pool.${field}`);
  }
}

async function verifyLiveStateView(target: AnyRecord, publication: AnyRecord, pools: AnyRecord[]): Promise<void> {
  const network = target.network ?? publication.network ?? "unknown";
  const stateViewAddress = target.contracts?.StateView;
  const rpcUrl = rpcUrlFor(target, publication);

  if (!isAddress(stateViewAddress)) {
    fail(`${network} StateView address is missing or invalid`);
    return;
  }

  if (!rpcUrl) {
    fail(`${network} requires ${publication.rpcEnv ?? target.rpcEnv} or a recorded public RPC fallback for StateView reads`);
    return;
  }

  const client = createPublicClient({ transport: http(rpcUrl) });
  const chainId = await client.getChainId();
  if (target.chainId === chainId) pass(`${network} StateView RPC chainId matches ${chainId}`);
  else fail(`${network} StateView RPC chainId ${chainId} does not match manifest ${target.chainId}`);

  const bytecode = await client.getBytecode({ address: stateViewAddress as `0x${string}` });
  if (bytecode && bytecode !== "0x") pass(`${network} StateView has deployed bytecode`);
  else fail(`${network} StateView has no bytecode at ${stateViewAddress}`);

  for (const pool of pools.map(normalizePool)) {
    const label = `${network} ${pool.family ?? "unknown"} ${pool.symbol ?? pool.poolId ?? "unknown"}`;

    if (!isBytes32(pool.poolId)) {
      fail(`${label} poolId is invalid`);
      continue;
    }

    if (isAddress(pool.currency0) && isAddress(pool.currency1) && isAddress(pool.hooks)) {
      pass(`${label} has complete PoolKey addresses`);
    } else {
      fail(`${label} has incomplete PoolKey addresses`);
    }

    if (pool.fee != null && pool.tickSpacing != null) pass(`${label} has fee and tickSpacing`);
    else fail(`${label} is missing fee or tickSpacing`);

    const slot0 = await client.readContract({
      address: stateViewAddress as `0x${string}`,
      abi: stateViewAbi,
      functionName: "getSlot0",
      args: [pool.poolId as `0x${string}`],
    });
    const liquidity = await client.readContract({
      address: stateViewAddress as `0x${string}`,
      abi: stateViewAbi,
      functionName: "getLiquidity",
      args: [pool.poolId as `0x${string}`],
    });

    const [sqrtPriceX96, tick, protocolFee, lpFee] = slot0;
    if (sqrtPriceX96 > 0n) pass(`${label} StateView sqrtPriceX96 is nonzero`);
    else fail(`${label} StateView sqrtPriceX96 is zero`);

    if (pool.sqrtPriceX96 == null || sameBigIntString(sqrtPriceX96, pool.sqrtPriceX96)) {
      pass(`${label} StateView sqrtPriceX96 matches published evidence or is unconstrained`);
    } else {
      fail(`${label} StateView sqrtPriceX96 does not match published evidence`);
    }

    if (pool.tick == null || sameBigIntString(tick, pool.tick)) {
      pass(`${label} StateView tick matches published evidence or is unconstrained`);
    } else {
      fail(`${label} StateView tick does not match published evidence`);
    }

    if (protocolFee >= 0 && lpFee >= 0) pass(`${label} StateView fee fields are readable`);
    else fail(`${label} StateView fee fields are invalid`);

    if (pool.requireNonzeroLiquidity === false || pool.routerActiveClaim === false) {
      pass(`${label} StateView liquidity read is ${liquidity}`);
    } else if (liquidity > 0n) {
      pass(`${label} StateView liquidity is nonzero`);
    } else {
      fail(`${label} StateView liquidity is zero`);
    }
  }
}

async function checkTarget(multichain: AnyRecord, publicationInput: AnyRecord, network: string): Promise<void> {
  const target = targetByNetwork(multichain, network);
  const publication = publicationTarget(publicationInput, network);
  const pools = Array.isArray(publication.officialPools) ? publication.officialPools : [];

  if (target.network === network) pass(`${network} exists in multichain manifest`);
  else fail(`${network} is missing from multichain manifest`);

  if (publication.network === network) pass(`${network} exists in pool-publication input`);
  else fail(`${network} is missing from pool-publication input`);

  if (target.status === "pending-official-uniswap-v4-addresses") {
    if (target.contracts?.StateView == null && publication.officialPoolManager == null) {
      pass(`${network} StateView is intentionally unset while official addresses are pending`);
    } else {
      fail(`${network} StateView must stay unset while official addresses are pending`);
    }

    if (pools.length === 0) pass(`${network} StateView pool list is empty while official addresses are pending`);
    else fail(`${network} StateView pool list must stay empty while official addresses are pending`);

    warn(`${network} StateView verification remains pending official Uniswap v4 addresses`);
    return;
  }

  if (isAddress(target.contracts?.StateView)) pass(`${network} official StateView address is recorded`);
  else fail(`${network} official StateView address is missing`);

  if (publication.status === "pending-official-hook-pool-publication") {
    if (pools.length === 0) pass(`${network} StateView pool list is empty until hook pools are published`);
    else fail(`${network} pending hook-pool publication must not carry StateView pool records`);

    warn(`${network} StateView verification remains pending official hook-pool publication`);
    return;
  }

  if (publication.status === "draft") warn(`${network} StateView publication is draft-only and not a readiness claim`);
  if (publication.status === "ready") pass(`${network} StateView publication is marked ready`);

  if (pools.length === Number(publicationInput.expectedPoolTemplateCount)) {
    pass(`${network} StateView pool count matches expected template count`);
  } else {
    fail(`${network} StateView pool count ${pools.length} does not match ${publicationInput.expectedPoolTemplateCount}`);
  }

  if (publication.status === "ready" || rpcUrlFor(target, publication)) {
    await verifyLiveStateView(target, publication, pools);
  } else {
    warn(`${network} StateView live reads skipped until ${publication.rpcEnv ?? target.rpcEnv} is configured`);
  }
}

async function main(): Promise<void> {
  const relativeInputPath = inputPath();
  console.log("Official Uniswap v4 multichain StateView readiness check");
  console.log(`multichain ${MULTICHAIN_MANIFEST}`);
  console.log(`pool publication input ${relativeInputPath}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const multichain = readJson(MULTICHAIN_MANIFEST);
  const publicationInput = readJson(relativeInputPath);

  if (multichain.schemaVersion === 1) pass("multichain readiness manifest schemaVersion is 1");
  else fail("multichain readiness manifest schemaVersion must be 1");

  if (publicationInput.sourceMultichainManifest === MULTICHAIN_MANIFEST) {
    pass("pool-publication input points at multichain manifest");
  } else {
    fail("pool-publication input sourceMultichainManifest is wrong");
  }

  checkStateViewConfig(multichain);
  for (const network of requiredNetworks) await checkTarget(multichain, publicationInput, network);

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
