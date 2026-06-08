// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only first-liquidity plan for the Arc testnet FxHedgeHook pools.
// It produces the operator env matrix needed by SeedFxHedgeHookLiquidity.s.sol
// without requiring a private key or broadcasting transactions.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { encodeAbiParameters, keccak256 } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const MIN_TICK = -887_272;
const MAX_TICK = 887_272;
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

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

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value);
}

function isBytes32(value: unknown): value is string {
  return typeof value === "string" && BYTES32_RE.test(value);
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

function usableTickLower(tickSpacing: number): number {
  return Math.ceil(MIN_TICK / tickSpacing) * tickSpacing;
}

function usableTickUpper(tickSpacing: number): number {
  return Math.floor(MAX_TICK / tickSpacing) * tickSpacing;
}

function envPrefixFor(pool: AnyRecord): string {
  return `${String(pool.manifestPrefix ?? "").toUpperCase()}_USDC`;
}

function formatPoolPlan(family: AnyRecord, pool: AnyRecord): AnyRecord {
  const tickSpacing = Number(pool.tickSpacing);
  const envPrefix = envPrefixFor(pool);

  return {
    symbol: pool.symbol,
    envPrefix,
    poolId: pool.poolId,
    poolKey: {
      currency0: pool.currency0,
      currency1: pool.currency1,
      fee: pool.fee,
      tickSpacing,
      hooks: family.hookAddress,
    },
    ticks: {
      tickLower: usableTickLower(tickSpacing),
      tickUpper: usableTickUpper(tickSpacing),
    },
    env: {
      liquidityDelta: `${envPrefix}_LIQUIDITY_DELTA`,
      token0Cap: `${envPrefix}_TOKEN0_CAP`,
      token1Cap: `${envPrefix}_TOKEN1_CAP`,
      token0Source: `${envPrefix}_TOKEN0_SOURCE`,
      token1Source: `${envPrefix}_TOKEN1_SOURCE`,
    },
  };
}

function main(): void {
  console.log("FxHedgeHook first-liquidity no-broadcast plan");
  console.log(`manifest ${MANIFEST}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const manifest = readManifest();
  if (manifest.network === "arc-testnet" && manifest.chainId === 5042002) {
    pass("manifest targets Arc testnet chainId 5042002");
  } else {
    fail("manifest must target Arc testnet chainId 5042002");
  }

  const family = (manifest.hookFamilies ?? []).find((entry: AnyRecord) => entry.name === "FxHedgeHook");
  if (!family) {
    fail("manifest missing FxHedgeHook family");
    console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
    process.exit(1);
  }

  if (isAddress(family.hookAddress) && isAddress(family.poolManager)) {
    pass("FxHedgeHook hook and PoolManager addresses are valid");
  } else {
    fail("FxHedgeHook hook or PoolManager address is invalid");
  }

  const liquidity = family.liquidityReadiness ?? {};
  if (liquidity.status === "pending-first-liquidity") {
    pass("FxHedgeHook liquidity status is explicitly pending first liquidity");
  } else if (liquidity.status === "seeded") {
    pass("FxHedgeHook liquidity is already marked seeded");
  } else {
    fail("FxHedgeHook liquidity status is missing");
  }

  if (typeof liquidity.operatorCommand === "string" && liquidity.operatorCommand.includes("hedge:arc:seed-liquidity")) {
    pass("liquidity operator command is recorded");
  } else {
    fail("liquidity operator command is missing");
  }

  if (typeof liquidity.operatorScript === "string" && existsSync(join(ROOT, liquidity.operatorScript))) {
    pass(`liquidity operator script exists at ${liquidity.operatorScript}`);
  } else {
    fail("liquidity operator script is missing");
  }

  if (
    typeof liquidity.operatorPlanCommand === "string"
    && liquidity.operatorPlanCommand.includes("uniswap:hedge:liquidity:plan")
  ) {
    pass("liquidity operator plan command is recorded");
  } else {
    fail("liquidity operator plan command is missing");
  }

  if (typeof liquidity.operatorPlanScript === "string" && existsSync(join(ROOT, liquidity.operatorPlanScript))) {
    pass(`liquidity operator plan script exists at ${liquidity.operatorPlanScript}`);
  } else {
    fail("liquidity operator plan script is missing");
  }

  const pools = (family.pools ?? []).filter((pool: AnyRecord) => pool.status === "live");
  if (pools.length === 6) pass("manifest has six live FxHedgeHook pools to seed");
  else fail(`expected six live FxHedgeHook pools to seed, found ${pools.length}`);

  const plans = pools.map((pool: AnyRecord) => formatPoolPlan(family, pool));
  for (const plan of plans) {
    if (
      isAddress(plan.poolKey.currency0)
      && isAddress(plan.poolKey.currency1)
      && isAddress(plan.poolKey.hooks)
      && isBytes32(plan.poolId)
    ) {
      pass(`${plan.symbol} has a complete seeding PoolKey`);
    } else {
      fail(`${plan.symbol} has an incomplete seeding PoolKey`);
    }

    const computedPoolId = poolIdFromKey(
      plan.poolKey.currency0,
      plan.poolKey.currency1,
      Number(plan.poolKey.fee),
      Number(plan.poolKey.tickSpacing),
      plan.poolKey.hooks,
    );
    if (sameBytes32(computedPoolId, plan.poolId)) {
      pass(`${plan.symbol} seed PoolId matches PoolKey`);
    } else {
      fail(`${plan.symbol} seed PoolId mismatch: ${computedPoolId}`);
    }

    if (Number.isInteger(plan.ticks.tickLower) && Number.isInteger(plan.ticks.tickUpper) && plan.ticks.tickLower < plan.ticks.tickUpper) {
      pass(`${plan.symbol} has usable full-range ticks ${plan.ticks.tickLower}:${plan.ticks.tickUpper}`);
    } else {
      fail(`${plan.symbol} has invalid seed ticks`);
    }

    if (
      typeof plan.env.liquidityDelta === "string"
      && typeof plan.env.token0Cap === "string"
      && typeof plan.env.token1Cap === "string"
    ) {
      pass(`${plan.symbol} has required seeding env names`);
    } else {
      fail(`${plan.symbol} is missing seeding env names`);
    }
  }

  if (liquidity.status === "pending-first-liquidity") {
    warn("first liquidity still requires a funded operator simulation and explicit broadcast approval");
  }

  console.log("");
  console.log("operator command, simulation by default:");
  console.log("  bun run hedge:arc:seed-liquidity");
  console.log("");
  console.log("shared env:");
  console.log("  KEEPER_PRIVATE_KEY or DEPLOYER_PRIVATE_KEY");
  console.log("  DEFAULT_TOKEN_SOURCE, DEFAULT_USDC_SOURCE");
  console.log("");
  console.log("per-pool env matrix:");
  for (const plan of plans) {
    console.log(`  ${plan.symbol}`);
    console.log(`    ${plan.env.liquidityDelta}`);
    console.log(`    ${plan.env.token0Cap} (${plan.poolKey.currency0})`);
    console.log(`    ${plan.env.token1Cap} (${plan.poolKey.currency1})`);
    console.log(`    optional ${plan.env.token0Source}, ${plan.env.token1Source}`);
    console.log(`    ticks ${plan.ticks.tickLower}:${plan.ticks.tickUpper}`);
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
