// SPDX-License-Identifier: AGPL-3.0-only
//
// Verifies liquidity readiness for the FxHedgeHook pools on Arc testnet.
// PoolManager Initialize events are enough for pool entity indexing, but
// router-active markets need first liquidity events and nonzero liquidity.

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  concatHex,
  createPublicClient,
  decodeEventLog,
  hexToBigInt,
  http,
  keccak256,
  numberToHex,
  padHex,
  parseAbi,
  parseAbiItem,
} from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEFAULT_ARC_RPC = "https://rpc.drpc.testnet.arc.network";
const POOLS_SLOT = 6;
const LIQUIDITY_OFFSET = 3;
const LOG_RANGE_SIZE = 10_000n;
const counts: Record<Severity, number> = { PASS: 0, WARN: 0, FAIL: 0 };

const poolManagerAbi = parseAbi(["function extsload(bytes32 slot) view returns (bytes32)"]);
const modifyLiquidityEvent = parseAbiItem(
  "event ModifyLiquidity(bytes32 indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)",
);

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

function sameBytes32(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function addSlot(slot: string, offset: number): `0x${string}` {
  return padHex(numberToHex(hexToBigInt(slot as `0x${string}`) + BigInt(offset)), { size: 32 });
}

function poolStateSlot(poolId: string): `0x${string}` {
  return keccak256(concatHex([
    poolId as `0x${string}`,
    padHex(numberToHex(POOLS_SLOT), { size: 32 }),
  ]));
}

async function readLiquidity(poolManager: string, poolId: string): Promise<bigint> {
  const slot = addSlot(poolStateSlot(poolId), LIQUIDITY_OFFSET);
  const value = await client.readContract({
    address: poolManager as `0x${string}`,
    abi: poolManagerAbi,
    functionName: "extsload",
    args: [slot],
  });
  return hexToBigInt(value);
}

async function findModifyLiquidityLogs(poolManager: string, pools: AnyRecord[]): Promise<Map<string, AnyRecord[]>> {
  const latest = await client.getBlockNumber();
  const minInitializeBlock = Math.min(...pools.map((pool) => Number(pool.initializeBlock ?? 0)).filter(Boolean));
  const fromBlock = BigInt(minInitializeBlock || 0);
  const poolIds = new Set(pools.map((pool) => String(pool.poolId).toLowerCase()));
  const logsByPool = new Map<string, AnyRecord[]>();

  for (let start = fromBlock; start <= latest; start += LOG_RANGE_SIZE) {
    const end = start + LOG_RANGE_SIZE - 1n > latest ? latest : start + LOG_RANGE_SIZE - 1n;
    const logs = await client.getLogs({
      address: poolManager as `0x${string}`,
      event: modifyLiquidityEvent,
      fromBlock: start,
      toBlock: end,
    });

    for (const log of logs) {
      const decoded = decodeEventLog({ abi: [modifyLiquidityEvent], data: log.data, topics: log.topics });
      const poolId = String(decoded.args.id).toLowerCase();
      if (!poolIds.has(poolId)) continue;

      const entries = logsByPool.get(poolId) ?? [];
      entries.push({
        tx: log.transactionHash,
        blockNumber: Number(log.blockNumber),
        sender: decoded.args.sender,
        tickLower: Number(decoded.args.tickLower),
        tickUpper: Number(decoded.args.tickUpper),
        liquidityDelta: decoded.args.liquidityDelta.toString(),
        salt: decoded.args.salt,
      });
      logsByPool.set(poolId, entries);
    }
  }

  return logsByPool;
}

async function main(): Promise<void> {
  console.log("FxHedgeHook liquidity readiness check");
  console.log(`rpc ${process.env.ARC_RPC_URL || DEFAULT_ARC_RPC}`);
  console.log("");

  const manifest = readManifest();
  const family = (manifest.hookFamilies ?? []).find((entry: AnyRecord) => entry.name === "FxHedgeHook");
  if (!family) {
    fail("manifest missing FxHedgeHook family");
    console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
    process.exit(1);
  }

  const livePools = (family.pools ?? []).filter((pool: AnyRecord) => pool.status === "live");
  if (livePools.length === 6) pass("manifest has six live FxHedgeHook pools");
  else fail(`expected six live FxHedgeHook pools, found ${livePools.length}`);

  const modifyLiquidityLogs = await findModifyLiquidityLogs(family.poolManager, livePools);
  let seededPools = 0;

  for (const pool of livePools) {
    const liquidity = await readLiquidity(family.poolManager, pool.poolId);
    const logs = modifyLiquidityLogs.get(String(pool.poolId).toLowerCase()) ?? [];
    const firstAdd = logs.find((entry) => BigInt(entry.liquidityDelta) > 0n);

    if (liquidity > 0n) {
      seededPools += 1;
      pass(`${pool.symbol} current in-range liquidity is ${liquidity}`);
    } else {
      warn(`${pool.symbol} current in-range liquidity is zero`);
    }

    if (firstAdd) {
      pass(`${pool.symbol} first add-liquidity tx ${firstAdd.tx} at block ${firstAdd.blockNumber}`);
      if (pool.firstLiquidityTx && sameBytes32(firstAdd.tx, pool.firstLiquidityTx)) {
        pass(`${pool.symbol} firstLiquidityTx matches manifest`);
      } else if (pool.firstLiquidityTx) {
        fail(`${pool.symbol} firstLiquidityTx does not match first add-liquidity log`);
      }
    } else {
      warn(`${pool.symbol} has no ModifyLiquidity add event after initialization`);
    }
  }

  if (seededPools === livePools.length) {
    pass("all live FxHedgeHook pools have nonzero in-range liquidity");
  } else {
    warn(`${livePools.length - seededPools} live FxHedgeHook pool(s) still need first liquidity before router-active claims`);
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
