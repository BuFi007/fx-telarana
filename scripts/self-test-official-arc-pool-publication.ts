// SPDX-License-Identifier: AGPL-3.0-only
//
// Regression self-test for the official Arc pool publication checker.
// It creates populated temporary inputs from the readiness manifest, proves that
// draft mode passes offline, and proves that ready mode fails without live
// official PoolManager receipt verification.

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { encodeAbiParameters, keccak256 } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const TEMPLATE = "deployments/uniswap-v4-official-arc-pools.template.json";
const TEMP_DEPLOYMENT_INPUT = "deployments/.tmp-official-arc-input.self-test.json";
const TEMP_DRAFT_INPUT = "deployments/.tmp-official-arc-pools-draft.self-test.json";
const TEMP_READY_INPUT = "deployments/.tmp-official-arc-pools-ready.self-test.json";
const TEMP_BAD_ROUTER_INPUT = "deployments/.tmp-official-arc-pools-bad-router.self-test.json";
const OFFICIAL_PM = "0x1111111111111111111111111111111111111111";
const DEFAULT_SQRT_PRICE_X96 = "79228162514264337593543950336";
const SELF_TEST_CHAIN_ID = 999999;
const LOW_14_MASK = 0x3fffn;

const counts: Record<Severity, number> = { PASS: 0, FAIL: 0 };

function record(severity: Severity, message: string): void {
  counts[severity] += 1;
  console.log(`${severity.padEnd(4)} ${message}`);
}

function pass(message: string): void {
  record("PASS", message);
}

function fail(message: string): void {
  record("FAIL", message);
}

function readJson(relativePath: string): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, relativePath), "utf-8"));
}

function writeJson(relativePath: string, value: AnyRecord): void {
  writeFileSync(join(ROOT, relativePath), `${JSON.stringify(value, null, 2)}\n`);
}

function cleanup(): void {
  for (const relativePath of [TEMP_DEPLOYMENT_INPUT, TEMP_DRAFT_INPUT, TEMP_READY_INPUT, TEMP_BAD_ROUTER_INPUT]) {
    const absolutePath = join(ROOT, relativePath);
    if (existsSync(absolutePath)) rmSync(absolutePath);
  }
}

function hookAddressFor(index: number, expectedLow14Bits: number): string {
  const value = (BigInt(index + 1) << 16n) | BigInt(expectedLow14Bits);
  if ((value & LOW_14_MASK) !== BigInt(expectedLow14Bits)) {
    throw new Error(`generated hook address does not match low-14 bits ${expectedLow14Bits}`);
  }

  return `0x${value.toString(16).padStart(40, "0")}`;
}

function bytes32For(label: string): string {
  return keccak256(encodeAbiParameters([{ type: "string" }], [label]));
}

function poolIdFromKey(currency0: string, currency1: string, fee: number, tickSpacing: number, hooks: string): string {
  return keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [currency0 as `0x${string}`, currency1 as `0x${string}`, fee, tickSpacing, hooks as `0x${string}`],
  ));
}

function collectTemplates(manifest: AnyRecord): AnyRecord[] {
  const templates: AnyRecord[] = [];

  for (const family of manifest.hookFamilies ?? []) {
    if (family.deployed === false) continue;

    for (const pool of family.pools ?? []) {
      const hooks = pool.hookAddress ?? family.hookAddress;
      templates.push({
        family: family.name,
        symbol: pool.symbol,
        sourceHookAddress: hooks,
        expectedHookBits: Number(family.permissionFlagsLow14Bits),
        sourcePoolKey: {
          currency0: pool.currency0,
          currency1: pool.currency1,
          fee: Number(pool.fee),
          tickSpacing: Number(pool.tickSpacing),
          hooks,
        },
        sourceSqrtPriceX96: pool.sqrtPriceX96,
      });
    }
  }

  return templates;
}

function routerQuoterStatusFor(template: AnyRecord): AnyRecord {
  if (template.family === "FxHedgeHook") {
    return {
      exactInput: "fixture-passed",
      officialV4QuoterExactInputDiagnostic: {
        status: "passed",
        command: "fixture: quoteExactInputSingle",
        quoter: "0x4444444444444444444444444444444444444444",
        poolManager: OFFICIAL_PM,
        hookData: "0x",
        note: "Fixture only; production records must carry the real target-chain Quoter result.",
      },
    };
  }

  if (template.family === "FxSwapHook") {
    return {
      exactInput: "supported-via-direct-quote-and-protocol-router",
      customRouteCaveat: "Fixture custom-route caveat for PMM-aware exact-input settlement.",
      note: "Fixture only; production records must carry the real route result or caveat.",
    };
  }

  return {
    customRouteCaveat: "Fixture custom-route caveat for hookData or attestation-required routing.",
    hookData: "Gateway route or trusted-router context required",
    note: "Fixture only; production records must carry the real route result or caveat.",
  };
}

function officialPoolFromTemplate(template: AnyRecord, index: number): AnyRecord {
  const hookAddress = hookAddressFor(index, Number(template.expectedHookBits));
  const sourceKey = template.sourcePoolKey ?? {};
  const poolKey = {
    currency0: sourceKey.currency0,
    currency1: sourceKey.currency1,
    fee: Number(sourceKey.fee),
    tickSpacing: Number(sourceKey.tickSpacing),
    hooks: hookAddress,
  };
  const poolId = poolIdFromKey(
    poolKey.currency0,
    poolKey.currency1,
    poolKey.fee,
    poolKey.tickSpacing,
    poolKey.hooks,
  );
  const sqrtPriceX96 = template.sourceSqrtPriceX96 ?? DEFAULT_SQRT_PRICE_X96;
  const liquidity = "1000000000000";
  const tick = "0";

  return {
    family: template.family,
    symbol: template.symbol,
    poolManager: OFFICIAL_PM,
    hookAddress,
    poolId,
    poolKey,
    initializeTx: bytes32For(`${template.family}:${template.symbol}:initialize`),
    firstLiquidityTx: bytes32For(`${template.family}:${template.symbol}:first-liquidity`),
    routerActiveClaim: true,
    routerQuoterStatus: routerQuoterStatusFor(template),
    sqrtPriceX96,
    liquidity,
    stateViewVerification: {
      status: "verified",
      sqrtPriceX96,
      liquidity,
      slot0: {
        sqrtPriceX96,
        tick,
      },
    },
    subgraphVerification: {
      status: "verified",
      id: poolId,
      hooks: hookAddress,
      token0: { id: poolKey.currency0 },
      token1: { id: poolKey.currency1 },
      feeTier: String(poolKey.fee),
      tickSpacing: String(poolKey.tickSpacing),
      sqrtPrice: sqrtPriceX96,
      tick,
      liquidity,
    },
  };
}

function buildDeploymentInput(): AnyRecord {
  return {
    schemaVersion: 1,
    network: "arc-mainnet",
    source: "https://developers.uniswap.org/docs/protocols/v4/deployments",
    status: "ready",
    chainId: SELF_TEST_CHAIN_ID,
    retrievedAt: "2026-06-08T00:00:00.000Z",
    contracts: {
      PoolManager: OFFICIAL_PM,
      PositionManager: "0x2222222222222222222222222222222222222222",
      UniversalRouter: "0x3333333333333333333333333333333333333333",
      Quoter: "0x4444444444444444444444444444444444444444",
      StateView: "0x5555555555555555555555555555555555555555",
      Permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    },
  };
}

function buildPoolPublication(status: "draft" | "ready", officialPools: AnyRecord[]): AnyRecord {
  const template = readJson(TEMPLATE);
  return {
    ...template,
    status,
    chainId: SELF_TEST_CHAIN_ID,
    retrievedAt: "2026-06-08T00:00:00.000Z",
    sourceDeploymentInput: TEMP_DEPLOYMENT_INPUT,
    expectedPoolTemplateCount: officialPools.length,
    officialPools,
  };
}

function withBadRouterEvidence(officialPools: AnyRecord[]): AnyRecord[] {
  return officialPools.map((pool, index) => index === 0
    ? {
      ...pool,
      routerQuoterStatus: {
        note: "Fixture intentionally incomplete.",
      },
    }
    : pool);
}

function runPoolPublicationCheck(inputPath: string): { status: number; stdout: string; stderr: string } {
  const env = {
    ...process.env,
    OFFICIAL_ARC_POOL_PUBLICATION_INPUT: inputPath,
  };
  delete env.OFFICIAL_ARC_RPC_URL;

  const result = spawnSync("bun", ["scripts/check-official-arc-pool-publication.ts"], {
    cwd: ROOT,
    env,
    encoding: "utf8",
  });

  return {
    status: result.status ?? 1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function expect(condition: boolean, message: string, details?: string): void {
  if (condition) {
    pass(message);
    return;
  }

  fail(message);
  if (details) console.log(details.trimEnd());
}

function main(): void {
  console.log("Official Arc pool publication checker self-test");
  console.log("mode read-only/no-broadcast; temporary fixtures are cleaned up");
  console.log("");

  cleanup();

  try {
    const manifest = readJson(MANIFEST);
    const officialPools = collectTemplates(manifest).map(officialPoolFromTemplate);

    writeJson(TEMP_DEPLOYMENT_INPUT, buildDeploymentInput());
    writeJson(TEMP_DRAFT_INPUT, buildPoolPublication("draft", officialPools));
    writeJson(TEMP_READY_INPUT, buildPoolPublication("ready", officialPools));
    writeJson(TEMP_BAD_ROUTER_INPUT, buildPoolPublication("draft", withBadRouterEvidence(officialPools)));

    expect(officialPools.length > 0, `generated ${officialPools.length} official pool fixture records`);

    const draft = runPoolPublicationCheck(TEMP_DRAFT_INPUT);
    expect(draft.status === 0, "draft populated fixture passes offline preflight", draft.stdout || draft.stderr);
    expect(
      /summary PASS=\d+ WARN=\d+ FAIL=0/.test(draft.stdout),
      "draft populated fixture has FAIL=0",
      draft.stdout,
    );
    expect(
      draft.stdout.includes("populated draft and cannot be used for readiness claims"),
      "draft populated fixture is explicitly not a readiness claim",
      draft.stdout,
    );

    const ready = runPoolPublicationCheck(TEMP_READY_INPUT);
    expect(ready.status !== 0, "ready populated fixture fails without OFFICIAL_ARC_RPC_URL", ready.stdout || ready.stderr);
    expect(
      ready.stdout.includes("OFFICIAL_ARC_RPC_URL is required before a ready official pool publication can pass"),
      "ready populated fixture requires live official Arc RPC receipt verification",
      ready.stdout,
    );
    expect(/summary PASS=\d+ WARN=0 FAIL=1/.test(ready.stdout), "ready populated fixture has exactly one expected failure", ready.stdout);

    const badRouter = runPoolPublicationCheck(TEMP_BAD_ROUTER_INPUT);
    expect(badRouter.status !== 0, "missing router/quoter evidence fixture fails", badRouter.stdout || badRouter.stderr);
    expect(
      badRouter.stdout.includes("router/quoter evidence must include exact-input proof or a custom-route caveat"),
      "missing router/quoter fixture fails for the explicit evidence reason",
      badRouter.stdout,
    );
  } finally {
    cleanup();
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
