// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only verifier for the official Arc Uniswap v4 StateView gate.
// While official Arc v4 is unpublished it validates the pending manifest shape.
// Once official addresses and pool IDs exist, it reads slot0/liquidity through
// the official StateView contract and never broadcasts transactions.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createPublicClient, http, parseAbi } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const POOL_PUBLICATION_ENV = "OFFICIAL_ARC_POOL_PUBLICATION_INPUT";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

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

function readManifest(): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, MANIFEST), "utf-8"));
}

function readJson(relativePath: string): AnyRecord | null {
  const absolutePath = join(ROOT, relativePath);
  if (!existsSync(absolutePath)) {
    fail(`missing JSON file ${relativePath}`);
    return null;
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

function normalizePublicationPool(pool: AnyRecord): AnyRecord {
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

function officialPoolsForStateView(official: AnyRecord, stateView: AnyRecord): AnyRecord[] {
  const explicitInput = process.env[POOL_PUBLICATION_ENV];
  if (explicitInput) {
    const input = readJson(explicitInput);
    return Array.isArray(input?.officialPools)
      ? input.officialPools.map(normalizePublicationPool)
      : [];
  }

  if (Array.isArray(stateView.officialPools) && stateView.officialPools.length > 0) {
    return stateView.officialPools;
  }

  const publicationPools = official.poolPublication?.officialPools;
  return Array.isArray(publicationPools)
    ? publicationPools.map(normalizePublicationPool)
    : [];
}

async function checkLiveStateView(official: AnyRecord, stateView: AnyRecord): Promise<void> {
  const stateViewAddress = official.contracts?.StateView;
  const rpcUrl = process.env.OFFICIAL_ARC_RPC_URL || official.rpcUrl;
  const officialPools = officialPoolsForStateView(official, stateView);

  if (!isAddress(stateViewAddress)) {
    fail("official StateView address is missing or invalid");
    return;
  }

  if (!rpcUrl) {
    fail("OFFICIAL_ARC_RPC_URL or official rpcUrl is required when StateView verification is ready");
    return;
  }

  if (officialPools.length === 0) {
    fail("official StateView pool list is empty despite ready-to-query status");
    return;
  }

  const client = createPublicClient({ transport: http(rpcUrl) });
  const bytecode = await client.getBytecode({ address: stateViewAddress as `0x${string}` });
  if (bytecode && bytecode !== "0x") pass("official StateView has deployed bytecode");
  else fail(`official StateView has no bytecode at ${stateViewAddress}`);

  for (const pool of officialPools) {
    if (!isBytes32(pool.poolId)) {
      fail(`${pool.symbol ?? "unknown"} official poolId is invalid`);
      continue;
    }

    if (isAddress(pool.currency0) && isAddress(pool.currency1) && isAddress(pool.hooks)) {
      pass(`${pool.symbol ?? pool.poolId} has complete PoolKey addresses`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} has incomplete PoolKey addresses`);
    }

    if (pool.fee != null && pool.tickSpacing != null) {
      pass(`${pool.symbol ?? pool.poolId} has fee and tickSpacing for StateView evidence`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} is missing fee or tickSpacing`);
    }

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
    if (sqrtPriceX96 > 0n) pass(`${pool.symbol ?? pool.poolId} StateView sqrtPriceX96 is nonzero`);
    else fail(`${pool.symbol ?? pool.poolId} StateView sqrtPriceX96 is zero`);

    if (pool.sqrtPriceX96 == null || sameBigIntString(sqrtPriceX96, pool.sqrtPriceX96)) {
      pass(`${pool.symbol ?? pool.poolId} StateView sqrtPriceX96 matches published evidence or is unconstrained`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} StateView sqrtPriceX96 does not match published evidence`);
    }

    if (pool.tick == null || sameBigIntString(tick, pool.tick)) {
      pass(`${pool.symbol ?? pool.poolId} StateView tick matches published evidence or is unconstrained`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} StateView tick does not match published evidence`);
    }

    if (protocolFee >= 0 && lpFee >= 0) pass(`${pool.symbol ?? pool.poolId} StateView fee fields are readable`);
    else fail(`${pool.symbol ?? pool.poolId} StateView fee fields are invalid`);

    if (pool.requireNonzeroLiquidity === false) {
      pass(`${pool.symbol ?? pool.poolId} StateView liquidity read is ${liquidity}`);
    } else if (liquidity > 0n) {
      pass(`${pool.symbol ?? pool.poolId} StateView liquidity is nonzero`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} StateView liquidity is zero`);
    }
  }
}

async function main(): Promise<void> {
  console.log("Official Arc Uniswap v4 StateView readiness check");
  console.log(`manifest ${MANIFEST}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const manifest = readManifest();
  const official = manifest.officialArcMainnet ?? {};
  const stateView = official.stateViewVerification ?? {};
  const requiredContracts = new Set<string>(official.requiredContracts ?? []);

  if (requiredContracts.has("StateView")) pass("official migration requires StateView");
  else fail("official migration is missing StateView");

  if (official.status === "pending-official-uniswap-v4-addresses") {
    if (official.contracts?.StateView == null) pass("official StateView address is intentionally unset while pending");
    else fail("official StateView address must stay unset while pending");
  } else if (isAddress(official.contracts?.StateView)) {
    pass("official StateView address is populated");
  } else {
    fail("official StateView address is missing or invalid");
  }

  if (stateView.status === "pending-official-arc-stateview-and-official-poolids") {
    pass("official Arc StateView verification is correctly pending");
  } else if (stateView.status === "ready-to-query") {
    pass("official Arc StateView verification is marked ready to query");
  } else {
    fail("official Arc StateView verification status is missing or unknown");
  }

  if (typeof stateView.command === "string" && stateView.command.includes("uniswap:stateview:check")) {
    pass("official Arc StateView command is recorded");
  } else {
    fail("official Arc StateView command is missing");
  }

  const fields = new Set<string>(stateView.requiredPoolFields ?? []);
  for (const field of requiredPoolFields) {
    if (fields.has(field)) pass(`StateView verification requires pool.${field}`);
    else fail(`StateView verification is missing pool.${field}`);
  }

  const officialPools = officialPoolsForStateView(official, stateView);
  if (stateView.status === "pending-official-arc-stateview-and-official-poolids") {
    if (officialPools.length === 0) pass("official StateView pool list is intentionally empty while pending official redeploy");
    else fail("official StateView pool list must stay empty while official redeploy is pending");
    warn("official Arc StateView verification remains pending until official Arc pools are initialized");
  } else {
    await checkLiveStateView(official, stateView);
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
