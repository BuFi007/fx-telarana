// SPDX-License-Identifier: AGPL-3.0-only
//
// Non-broadcast Arc testnet verifier for FxHedgeHook stable pools.
// It verifies manifest PoolIds and hook configuration state without a private key.

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createPublicClient, encodeAbiParameters, http, keccak256, parseAbi } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEFAULT_ARC_RPC = "https://rpc.drpc.testnet.arc.network";
const ZERO_BYTES32 = `0x${"0".repeat(64)}`;
const counts: Record<Severity, number> = { PASS: 0, WARN: 0, FAIL: 0 };

const fxHedgeHookAbi = parseAbi([
  "function poolConfigs(bytes32 poolId) view returns (bytes32 marketId, address hedgeToken, uint8 hedgeTokenDecimals, bytes32 pythFeedId, uint256 rebalanceThresholdE18, bool enabled)",
  "function defaultRebalanceThresholdE18() view returns (uint256)",
]);

const client = createPublicClient({
  transport: http(process.env.ARC_RPC_URL || DEFAULT_ARC_RPC),
});

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

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function sameBytes32(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function poolIdFromKey(currency0: string, currency1: string, fee: number, tickSpacing: number, hooks: string): string {
  return keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [currency0 as `0x${string}`, currency1 as `0x${string}`, fee, tickSpacing, hooks as `0x${string}`],
  ));
}

function findFamily(manifest: AnyRecord, name: string): AnyRecord {
  const family = (manifest.hookFamilies ?? []).find((entry: AnyRecord) => entry.name === name);
  if (!family) {
    fail(`manifest missing ${name}`);
    return {};
  }
  return family;
}

async function readPoolConfig(hookAddress: string, poolId: string) {
  return client.readContract({
    address: hookAddress as `0x${string}`,
    abi: fxHedgeHookAbi,
    functionName: "poolConfigs",
    args: [poolId as `0x${string}`],
  });
}

async function checkLivePool(family: AnyRecord, pool: AnyRecord): Promise<void> {
  const computedPoolId = poolIdFromKey(
    pool.currency0,
    pool.currency1,
    Number(pool.fee),
    Number(pool.tickSpacing),
    family.hookAddress,
  );
  if (sameBytes32(computedPoolId, pool.poolId)) {
    pass(`${pool.symbol} PoolId matches PoolKey`);
  } else {
    fail(`${pool.symbol} PoolId mismatch: ${computedPoolId}`);
  }

  const config = await readPoolConfig(family.hookAddress, pool.poolId);
  const [marketId, hedgeToken, hedgeTokenDecimals, pythFeedId, rebalanceThresholdE18, enabled] = config;

  if (enabled) pass(`${pool.symbol} is configured on FxHedgeHook`);
  else fail(`${pool.symbol} is live in manifest but disabled on FxHedgeHook`);

  if (sameBytes32(marketId, pool.marketId)) pass(`${pool.symbol} configured marketId matches manifest`);
  else fail(`${pool.symbol} configured marketId mismatch`);

  if (sameAddress(hedgeToken, pool.hedgeToken)) {
    pass(`${pool.symbol} configured hedgeToken matches manifest`);
  } else {
    fail(`${pool.symbol} configured hedgeToken mismatch`);
  }

  if (Number(hedgeTokenDecimals) === Number(pool.hedgeTokenDecimals)) {
    pass(`${pool.symbol} configured decimals match manifest`);
  } else {
    fail(`${pool.symbol} configured decimals mismatch`);
  }

  if (sameBytes32(pythFeedId, pool.pythFeedId)) {
    pass(`${pool.symbol} configured pythFeedId matches manifest`);
  } else {
    fail(`${pool.symbol} configured pythFeedId mismatch`);
  }

  if (rebalanceThresholdE18.toString() === pool.rebalanceThresholdE18) {
    pass(`${pool.symbol} configured rebalance threshold matches manifest`);
  } else {
    fail(`${pool.symbol} configured rebalance threshold mismatch`);
  }
}

async function checkPendingPool(family: AnyRecord, pool: AnyRecord): Promise<void> {
  const computedPoolId = poolIdFromKey(
    pool.currency0,
    pool.currency1,
    Number(pool.fee),
    Number(pool.tickSpacing),
    family.hookAddress,
  );
  if (sameBytes32(computedPoolId, pool.expectedPoolId)) {
    pass(`${pool.symbol} expected PoolId matches PoolKey`);
  } else {
    fail(`${pool.symbol} expected PoolId mismatch: ${computedPoolId}`);
  }

  if (typeof pool.setupSqrtPriceX96 === "string" && BigInt(pool.setupSqrtPriceX96) > 0n) {
    pass(`${pool.symbol} setup sqrtPriceX96 is ready`);
  } else {
    fail(`${pool.symbol} setup sqrtPriceX96 is missing`);
  }

  const config = await readPoolConfig(family.hookAddress, pool.expectedPoolId);
  const [marketId, hedgeToken, , pythFeedId, , enabled] = config;
  if (!enabled && marketId === ZERO_BYTES32 && pythFeedId === ZERO_BYTES32 && sameAddress(hedgeToken, "0x0000000000000000000000000000000000000000")) {
    pass(`${pool.symbol} is still unconfigured on FxHedgeHook`);
  } else {
    fail(`${pool.symbol} is marked pending but already has on-chain hook config`);
  }
}

async function main(): Promise<void> {
  console.log("FxHedgeHook stable pool non-broadcast verifier");
  console.log(`rpc ${process.env.ARC_RPC_URL || DEFAULT_ARC_RPC}`);
  console.log("");

  const manifest = readManifest();
  if (manifest.network === "arc-testnet" && manifest.chainId === 5042002) {
    pass("manifest targets Arc testnet chainId 5042002");
  } else {
    fail("manifest must target Arc testnet chainId 5042002");
  }

  const family = findFamily(manifest, "FxHedgeHook");
  const threshold = await client.readContract({
    address: family.hookAddress as `0x${string}`,
    abi: fxHedgeHookAbi,
    functionName: "defaultRebalanceThresholdE18",
  });
  if (threshold > 0n) pass("FxHedgeHook default rebalance threshold is nonzero");
  else fail("FxHedgeHook default rebalance threshold is zero");

  const pools = Array.isArray(family.pools) ? family.pools : [];
  const livePools = pools.filter((pool: AnyRecord) => pool.status === "live");
  const pendingPools = pools.filter((pool: AnyRecord) => pool.status !== "live");

  if (livePools.length === 6) pass("manifest has all six FxHedgeHook pools live");
  else warn(`manifest has ${livePools.length} live FxHedgeHook pools`);

  if (pendingPools.length === 0) pass("manifest has no pending FxHedgeHook stable pools");
  else warn(`manifest has ${pendingPools.length} pending FxHedgeHook stable pools`);

  for (const pool of livePools) {
    await checkLivePool(family, pool);
  }

  for (const pool of pendingPools) {
    await checkPendingPool(family, pool);
  }

  console.log("");
  if (pendingPools.length > 0) {
    console.log("operator command after funding/role check:");
    console.log("  bun run hedge:arc:configure-stables");
  } else {
    console.log("no pending stable pools require the operator configure command");
  }
  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
