// SPDX-License-Identifier: AGPL-3.0-only
//
// Network-dependent Arc testnet verifier for the Uniswap v4 indexing manifest.
// It reads published initialize/configure transaction receipts and confirms the
// expected PoolManager/Hook events are present. It never broadcasts transactions.

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createPublicClient, decodeEventLog, http, parseAbiItem } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEFAULT_ARC_RPC = "https://rpc.drpc.testnet.arc.network";
const counts: Record<Severity, number> = { PASS: 0, WARN: 0, FAIL: 0 };

const initializeEvent = parseAbiItem(
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)",
);
const poolConfiguredEvent = parseAbiItem(
  "event PoolConfigured(bytes32 indexed poolId, bytes32 indexed marketId, address indexed hedgeToken, uint8 hedgeTokenDecimals, bytes32 pythFeedId, uint256 rebalanceThresholdE18, bool enabled)",
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

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function sameBytes32(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

async function verifyInitializeTx(
  label: string,
  poolManager: string,
  pool: AnyRecord,
  hooks: string,
): Promise<void> {
  if (!pool.initializeTx) {
    warn(`${label} has no initializeTx; skipping on-chain receipt verification`);
    return;
  }

  const receipt = await client.getTransactionReceipt({ hash: pool.initializeTx });
  if (receipt.status === "success") pass(`${label} initialize tx succeeded`);
  else fail(`${label} initialize tx status is ${receipt.status}`);

  if (typeof pool.initializeBlock === "number" && receipt.blockNumber === BigInt(pool.initializeBlock)) {
    pass(`${label} initialize block matches manifest`);
  } else if (typeof pool.initializeBlock === "number") {
    fail(`${label} initialize block mismatch`);
  }

  const initializeLogs = receipt.logs
    .filter((log) => sameAddress(log.address, poolManager))
    .flatMap((log) => {
      try {
        return [decodeEventLog({ abi: [initializeEvent], data: log.data, topics: log.topics })];
      } catch {
        return [];
      }
    });

  const match = initializeLogs.find((log) => sameBytes32(log.args.id, pool.poolId));
  if (!match) {
    fail(`${label} initialize tx did not emit Initialize for expected poolId`);
    return;
  }

  pass(`${label} initialize tx emitted expected PoolManager Initialize event`);
  if (sameAddress(match.args.hooks, hooks)) pass(`${label} Initialize.hooks matches manifest`);
  else fail(`${label} Initialize.hooks does not match manifest`);

  if (pool.currency0 && sameAddress(match.args.currency0, pool.currency0)) pass(`${label} Initialize.currency0 matches`);
  else if (pool.currency0) fail(`${label} Initialize.currency0 mismatch`);

  if (pool.currency1 && sameAddress(match.args.currency1, pool.currency1)) pass(`${label} Initialize.currency1 matches`);
  else if (pool.currency1) fail(`${label} Initialize.currency1 mismatch`);

  if (typeof pool.fee === "number" && Number(match.args.fee) === pool.fee) pass(`${label} Initialize.fee matches`);
  else if (typeof pool.fee === "number") fail(`${label} Initialize.fee mismatch`);

  if (typeof pool.tickSpacing === "number" && Number(match.args.tickSpacing) === pool.tickSpacing) {
    pass(`${label} Initialize.tickSpacing matches`);
  } else if (typeof pool.tickSpacing === "number") {
    fail(`${label} Initialize.tickSpacing mismatch`);
  }

  if (typeof pool.sqrtPriceX96 === "string" && match.args.sqrtPriceX96 === BigInt(pool.sqrtPriceX96)) {
    pass(`${label} Initialize.sqrtPriceX96 matches`);
  } else if (typeof pool.sqrtPriceX96 === "string") {
    fail(`${label} Initialize.sqrtPriceX96 mismatch`);
  }
}

async function verifyHedgeConfigureTx(label: string, hook: string, pool: AnyRecord): Promise<void> {
  if (!pool.configureTx) {
    warn(`${label} has no configureTx; skipping PoolConfigured receipt verification`);
    return;
  }

  const receipt = await client.getTransactionReceipt({ hash: pool.configureTx });
  if (receipt.status === "success") pass(`${label} configure tx succeeded`);
  else fail(`${label} configure tx status is ${receipt.status}`);

  if (typeof pool.configureBlock === "number" && receipt.blockNumber === BigInt(pool.configureBlock)) {
    pass(`${label} configure block matches manifest`);
  } else if (typeof pool.configureBlock === "number") {
    fail(`${label} configure block mismatch`);
  }

  const configuredLogs = receipt.logs
    .filter((log) => sameAddress(log.address, hook))
    .flatMap((log) => {
      try {
        return [decodeEventLog({ abi: [poolConfiguredEvent], data: log.data, topics: log.topics })];
      } catch {
        return [];
      }
    });

  const match = configuredLogs.find((log) => sameBytes32(log.args.poolId, pool.poolId));
  if (!match) {
    fail(`${label} configure tx did not emit PoolConfigured for expected poolId`);
    return;
  }

  pass(`${label} configure tx emitted expected PoolConfigured event`);
  if (sameBytes32(match.args.marketId, pool.marketId)) pass(`${label} PoolConfigured.marketId matches`);
  else fail(`${label} PoolConfigured.marketId mismatch`);

  if (pool.hedgeToken && sameAddress(match.args.hedgeToken, pool.hedgeToken)) {
    pass(`${label} PoolConfigured.hedgeToken matches`);
  } else if (pool.hedgeToken) {
    fail(`${label} PoolConfigured.hedgeToken mismatch`);
  }

  if (typeof pool.hedgeTokenDecimals === "number" && Number(match.args.hedgeTokenDecimals) === pool.hedgeTokenDecimals) {
    pass(`${label} PoolConfigured.hedgeTokenDecimals matches`);
  } else if (typeof pool.hedgeTokenDecimals === "number") {
    fail(`${label} PoolConfigured.hedgeTokenDecimals mismatch`);
  }

  if (pool.pythFeedId && sameBytes32(match.args.pythFeedId, pool.pythFeedId)) {
    pass(`${label} PoolConfigured.pythFeedId matches`);
  } else if (pool.pythFeedId) {
    fail(`${label} PoolConfigured.pythFeedId mismatch`);
  }

  if (
    typeof pool.rebalanceThresholdE18 === "string"
    && match.args.rebalanceThresholdE18 === BigInt(pool.rebalanceThresholdE18)
  ) {
    pass(`${label} PoolConfigured.rebalanceThresholdE18 matches`);
  } else if (typeof pool.rebalanceThresholdE18 === "string") {
    fail(`${label} PoolConfigured.rebalanceThresholdE18 mismatch`);
  }
}

async function main(): Promise<void> {
  console.log("Uniswap v4 on-chain indexing evidence verifier");
  console.log(`rpc ${process.env.ARC_RPC_URL || DEFAULT_ARC_RPC}`);
  console.log("");

  const manifest = readManifest();
  for (const family of manifest.hookFamilies ?? []) {
    if (family.name === "FxHedgeHook") {
      const livePools = (family.pools ?? []).filter((pool: AnyRecord) => pool.status === "live");
      for (const pool of livePools) {
        await verifyInitializeTx(`FxHedgeHook ${pool.symbol}`, family.poolManager, pool, family.hookAddress);
        await verifyHedgeConfigureTx(`FxHedgeHook ${pool.symbol}`, family.hookAddress, pool);
      }
    }

    if (family.name === "FxSwapHook") {
      for (const pool of family.pools ?? []) {
        await verifyInitializeTx(`FxSwapHook ${pool.symbol}`, family.poolManager, pool, pool.hookAddress);
      }
    }

    if (family.name === "TelaranaGatewayHubHook") {
      for (const pool of family.pools ?? []) {
        await verifyInitializeTx(`TelaranaGatewayHubHook ${pool.symbol}`, family.poolManager, pool, family.hookAddress);
      }
    }
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
