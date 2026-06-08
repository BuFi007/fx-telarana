// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only fill plan for the official Arc pool-publication input. This derives
// the 11 source pool templates from the Arc testnet evidence manifest and shows
// exactly which official fields must be populated after hook redeploys,
// PoolManager.initialize, first liquidity, StateView reads, subgraph reads, and
// route/quoter diagnostics exist.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const READINESS_MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEFAULT_OFFICIAL_INPUT = "deployments/uniswap-v4-official-arc-input.template.json";
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

function readJson(relativePath: string): AnyRecord {
  const path = join(ROOT, relativePath);
  if (!existsSync(path)) {
    fail(`missing ${relativePath}`);
    return {};
  }
  return JSON.parse(readFileSync(path, "utf-8"));
}

function officialInputPath(): string {
  return process.env.OFFICIAL_ARC_DEPLOYMENT_INPUT || DEFAULT_OFFICIAL_INPUT;
}

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value);
}

function isBytes32(value: unknown): value is string {
  return typeof value === "string" && BYTES32_RE.test(value);
}

function collectSourceTemplates(readiness: AnyRecord): AnyRecord[] {
  const templates: AnyRecord[] = [];
  for (const family of readiness.hookFamilies ?? []) {
    if (family.deployed === false) continue;
    for (const pool of family.pools ?? []) {
      const hooks = pool.hookAddress ?? family.hookAddress;
      templates.push({
        family: family.name,
        symbol: pool.symbol,
        expectedHookBits: family.permissionFlagsLow14Bits,
        sourcePoolManager: family.poolManager,
        sourceHookAddress: hooks,
        sourcePoolId: pool.poolId,
        sourceInitializeTx: pool.initializeTx,
        sourcePoolKey: {
          currency0: pool.currency0,
          currency1: pool.currency1,
          fee: pool.fee,
          tickSpacing: pool.tickSpacing,
          hooks,
        },
        sourceRouterQuoterStatus: family.routerQuoterStatus ?? null,
      });
    }
  }
  return templates;
}

function checkSourceTemplate(template: AnyRecord): void {
  const label = `${template.family ?? "unknown"} ${template.symbol ?? "unknown"}`;
  const key = template.sourcePoolKey ?? {};

  if (typeof template.family === "string" && typeof template.symbol === "string") {
    pass(`${label} has a family/symbol label`);
  } else {
    fail(`${label} is missing family/symbol`);
  }

  if (isBytes32(template.sourcePoolId)) pass(`${label} source poolId is recorded`);
  else fail(`${label} source poolId is missing`);

  if (isBytes32(template.sourceInitializeTx)) pass(`${label} source initialize tx is recorded`);
  else fail(`${label} source initialize tx is missing`);

  if (
    isAddress(key.currency0)
    && isAddress(key.currency1)
    && isAddress(key.hooks)
    && Number.isInteger(Number(key.fee))
    && Number.isInteger(Number(key.tickSpacing))
  ) {
    pass(`${label} source PoolKey is complete`);
  } else {
    fail(`${label} source PoolKey is incomplete`);
  }

  if (template.sourceRouterQuoterStatus != null) pass(`${label} source router/quoter caveat is available`);
  else fail(`${label} source router/quoter caveat is missing`);
}

function plannedPoolRecord(template: AnyRecord, officialPoolManager: string | null): AnyRecord {
  const sourceKey = template.sourcePoolKey ?? {};
  return {
    family: template.family,
    symbol: template.symbol,
    expectedHookBits: template.expectedHookBits,
    sourcePoolId: template.sourcePoolId,
    officialPoolManager: officialPoolManager ?? "<populate from official Arc deployment input>",
    officialFieldsToPopulate: {
      poolManager: officialPoolManager ?? "<official PoolManager>",
      hookAddress: "<official remine/redeploy hook address with matching low-14 bits>",
      poolKey: {
        currency0: sourceKey.currency0,
        currency1: sourceKey.currency1,
        fee: sourceKey.fee,
        tickSpacing: sourceKey.tickSpacing,
        hooks: "<official hookAddress>",
      },
      poolId: "<derive from official PoolKey>",
      initializeTx: "<official PoolManager.Initialize tx>",
      firstLiquidityTx: "<official positive PoolManager.ModifyLiquidity tx>",
      routerActiveClaim: false,
      routerQuoterStatus: template.sourceRouterQuoterStatus,
      stateViewVerification: {
        status: "pending",
        sqrtPriceX96: "<StateView.getSlot0(poolId)>",
        liquidity: "<StateView.getLiquidity(poolId), nonzero before router-active claim>",
      },
      subgraphVerification: {
        status: "pending",
        id: "<official v4 subgraph pool id>",
        hooks: "<official hookAddress>",
        token0: { id: sourceKey.currency0 },
        token1: { id: sourceKey.currency1 },
        feeTier: String(sourceKey.fee),
        tickSpacing: String(sourceKey.tickSpacing),
        sqrtPrice: "<official v4 subgraph sqrtPrice>",
        tick: "<official v4 subgraph tick>",
        liquidity: "<official v4 subgraph nonzero liquidity before router-active claim>",
      },
      receiptVerification: {
        initializeTxVerified: false,
        firstLiquidityTxVerified: false,
      },
    },
  };
}

function main(): void {
  const inputPath = officialInputPath();
  console.log("Official Arc pool-publication fill plan");
  console.log(`source ${READINESS_MANIFEST}`);
  console.log(`official input ${inputPath}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const readiness = readJson(READINESS_MANIFEST);
  const officialInput = readJson(inputPath);
  const templates = collectSourceTemplates(readiness);
  const officialPoolManager = isAddress(officialInput.contracts?.PoolManager)
    ? officialInput.contracts.PoolManager
    : null;

  if (readiness.network === "arc-testnet" && readiness.chainId === 5_042_002) {
    pass("source readiness manifest is Arc testnet");
  } else {
    fail("source readiness manifest must be Arc testnet");
  }

  if (officialInput.network === "arc-mainnet") pass("official deployment input targets Arc mainnet");
  else fail("official deployment input must target Arc mainnet");

  if (officialPoolManager) pass("official PoolManager is populated in deployment input");
  else warn("official PoolManager is pending; fill plan keeps PoolManager placeholders");

  if (templates.length === 11) pass("fill plan derives 11 source pool templates");
  else fail(`fill plan expected 11 source pool templates, found ${templates.length}`);

  for (const template of templates) checkSourceTemplate(template);

  console.log("");
  console.log("publication fill matrix");
  console.log(JSON.stringify({
    schemaVersion: 1,
    status: "fill-plan-not-a-readiness-claim",
    target: "arc-mainnet",
    sourceManifest: READINESS_MANIFEST,
    sourceDeploymentInput: inputPath,
    expectedPoolTemplateCount: templates.length,
    officialPoolManager: officialPoolManager ?? null,
    plannedOfficialPools: templates.map((template) => plannedPoolRecord(template, officialPoolManager)),
    nextCommand: "OFFICIAL_ARC_POOL_PUBLICATION_INPUT=<populated-file> bun run uniswap:official-arc:pools:check",
  }, null, 2));

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
