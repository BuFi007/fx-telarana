// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only fill plan for official Uniswap v4 pool-publication records across
// Arc, Avalanche Fuji, Avalanche, and Arbitrum. It derives the 11 source pool
// templates from Arc testnet evidence and shows the target-chain fields that
// must be populated before claiming official indexing.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const READINESS_MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const DEFAULT_POOL_PUBLICATION_INPUT = "deployments/uniswap-v4-official-multichain-pools.template.json";
const INPUT_ENV = "OFFICIAL_MULTICHAIN_POOL_PUBLICATION_INPUT";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

const requiredNetworks = [
  "arc-mainnet",
  "avalanche-fuji",
  "avalanche",
  "arbitrum-one",
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
  return process.env[INPUT_ENV] || DEFAULT_POOL_PUBLICATION_INPUT;
}

function repoRelativePathFor(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  if (index === -1) return undefined;

  const value = process.argv[index + 1];
  if (!value) throw new Error(`${flag} requires a relative path`);
  if (value.startsWith("/") || value.includes("..")) {
    throw new Error(`${flag} must stay inside the repository`);
  }

  return value;
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
  return typeof value === "string" && ADDRESS_RE.test(value);
}

function isBytes32(value: unknown): value is string {
  return typeof value === "string" && BYTES32_RE.test(value);
}

function targetByNetwork(multichain: AnyRecord, network: string): AnyRecord {
  return (multichain.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function publicationTarget(input: AnyRecord, network: string): AnyRecord {
  return (input.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
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

  if (Number.isInteger(Number(template.expectedHookBits))) pass(`${label} expected hook bits are recorded`);
  else fail(`${label} expected hook bits are missing`);

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

  if (template.sourceRouterQuoterStatus != null) pass(`${label} source router/quoter status is available`);
  else fail(`${label} source router/quoter status is missing`);
}

function targetRouterQuoterStatusFor(template: AnyRecord, target: AnyRecord): AnyRecord {
  const sourceStatus = template.sourceRouterQuoterStatus ?? {};

  if (template.family === "FxHedgeHook") {
    return {
      sourceRouterQuoterStatus: sourceStatus,
      targetRequirement: "official exact-input V4Quoter diagnostic required before ready publication",
      officialV4QuoterExactInputDiagnostic: {
        status: "<passed>",
        command: `<target RPC> quoteExactInputSingle through ${target.contracts?.Quoter ?? "<official Quoter>"}`,
        quoter: target.contracts?.Quoter ?? "<official target-chain Quoter>",
        poolManager: target.contracts?.PoolManager ?? "<official target-chain PoolManager>",
        hookData: "0x",
        result: "<target-chain exact-input quote result>",
      },
    };
  }

  if (template.family === "FxSwapHook") {
    return {
      sourceRouterQuoterStatus: sourceStatus,
      targetRequirement: "custom-route caveat required before ready publication",
      customRouteCaveat: "PMM-aware direct quote/exact-input protocol route; generic empty-hookData V4Quoter is not a readiness claim.",
    };
  }

  return {
    sourceRouterQuoterStatus: sourceStatus,
    targetRequirement: "custom-route caveat required before ready publication",
    customRouteCaveat: "hookData/attestation context required; generic empty-hookData V4Quoter is not a readiness claim.",
  };
}

function plannedPoolRecord(template: AnyRecord, target: AnyRecord): AnyRecord {
  const sourceKey = template.sourcePoolKey ?? {};
  const officialPoolManager = target.contracts?.PoolManager ?? null;
  return {
    family: template.family,
    symbol: template.symbol,
    expectedHookBits: template.expectedHookBits,
    sourcePoolId: template.sourcePoolId,
    sourceInitializeTx: template.sourceInitializeTx,
    officialPoolManager: officialPoolManager ?? "<pending official PoolManager>",
    fieldsToPopulate: {
      poolManager: officialPoolManager ?? "<official target-chain PoolManager>",
      hookAddress: "<target-chain remine/redeploy hook address with matching low-14 bits>",
      poolKey: {
        currency0: sourceKey.currency0,
        currency1: sourceKey.currency1,
        fee: sourceKey.fee,
        tickSpacing: sourceKey.tickSpacing,
        hooks: "<target-chain hookAddress>",
      },
      poolId: "<derive from official target-chain PoolKey>",
      initializeTx: "<official target-chain PoolManager.Initialize tx>",
      firstLiquidityTx: "<official target-chain positive PoolManager.ModifyLiquidity tx>",
      routerActiveClaim: false,
      routerQuoterStatus: targetRouterQuoterStatusFor(template, target),
      stateViewVerification: {
        status: "pending",
        sqrtPriceX96: "<StateView.getSlot0(poolId).sqrtPriceX96>",
        liquidity: "<StateView.getLiquidity(poolId)>",
      },
      subgraphVerification: {
        status: "pending",
        id: "<official v4 subgraph pool id>",
        hooks: "<target-chain hookAddress>",
        token0: { id: sourceKey.currency0 },
        token1: { id: sourceKey.currency1 },
        feeTier: String(sourceKey.fee),
        tickSpacing: String(sourceKey.tickSpacing),
        sqrtPrice: "<official v4 subgraph sqrtPrice>",
        tick: "<official v4 subgraph tick>",
        liquidity: "<official v4 subgraph liquidity>",
      },
      receiptVerification: {
        initializeTxVerified: false,
        firstLiquidityTxVerified: false,
      },
    },
  };
}

function targetPlan(
  network: string,
  multichain: AnyRecord,
  publicationInput: AnyRecord,
  templates: AnyRecord[],
): AnyRecord {
  const target = targetByNetwork(multichain, network);
  const inputTarget = publicationTarget(publicationInput, network);
  const officialPoolManager = target.contracts?.PoolManager ?? null;

  return {
    network,
    chainId: target.chainId ?? inputTarget.chainId ?? null,
    officialStatus: target.status ?? "missing",
    publicationStatus: inputTarget.status ?? target.poolPublicationStatus ?? "missing",
    officialPoolManager,
    rpcEnv: target.rpcEnv ?? inputTarget.rpcEnv ?? null,
    plannedPoolCount: templates.length,
    populatedPoolCount: Array.isArray(inputTarget.officialPools) ? inputTarget.officialPools.length : 0,
    readyCommand: `${INPUT_ENV}=<populated-file> bun run uniswap:official-multichain:pools:check`,
    plannedOfficialPools: templates.map((template) => plannedPoolRecord(template, target)),
  };
}

function checkTargetPlan(network: string, multichain: AnyRecord, publicationInput: AnyRecord): void {
  const target = targetByNetwork(multichain, network);
  const inputTarget = publicationTarget(publicationInput, network);

  if (target.network === network) pass(`${network} exists in multichain readiness manifest`);
  else fail(`${network} is missing from multichain readiness manifest`);

  if (inputTarget.network === network) pass(`${network} exists in pool-publication input`);
  else fail(`${network} is missing from pool-publication input`);

  if (target.status === "pending-official-uniswap-v4-addresses") {
    warn(`${network} official v4 addresses are pending; publication records remain placeholders`);
    return;
  }

  if (target.status === "official-uniswap-v4-addresses-published" && isAddress(target.contracts?.PoolManager)) {
    pass(`${network} official PoolManager is known`);
  } else {
    fail(`${network} official PoolManager is missing`);
  }

  if (target.poolPublicationStatus === "pending-poolmanager-initialize-and-first-liquidity") {
    warn(`${network} has official contracts but still needs hook redeploy, Initialize txs, first liquidity, StateView, subgraph, and route/quoter evidence`);
  } else if (target.poolPublicationStatus === "ready") {
    pass(`${network} hook pool publication is marked ready`);
  } else {
    fail(`${network} poolPublicationStatus is not recognized`);
  }
}

function buildFillPlanPacket(
  relativeInputPath: string,
  publicationInput: AnyRecord,
  multichain: AnyRecord,
  templates: AnyRecord[],
): AnyRecord {
  return {
    schemaVersion: 1,
    status: "fill-plan-not-a-readiness-claim",
    sourceManifest: READINESS_MANIFEST,
    sourceMultichainManifest: MULTICHAIN_MANIFEST,
    poolPublicationInput: relativeInputPath,
    expectedPoolTemplateCount: templates.length,
    requiredReadyEvidence: publicationInput.requiredReadyEvidence ?? [],
    validationSummary: {
      pass: counts.PASS,
      warn: counts.WARN,
      fail: counts.FAIL,
    },
    targets: requiredNetworks.map((network) => targetPlan(network, multichain, publicationInput, templates)),
  };
}

function main(): void {
  const relativeInputPath = inputPath();
  const outPath = repoRelativePathFor("--out");
  const checkPath = repoRelativePathFor("--check");
  if (outPath && checkPath) throw new Error("use either --out or --check, not both");

  console.log("Official Uniswap v4 multichain pool-publication fill plan");
  console.log(`source ${READINESS_MANIFEST}`);
  console.log(`multichain ${MULTICHAIN_MANIFEST}`);
  console.log(`pool publication input ${relativeInputPath}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const readiness = readJson(READINESS_MANIFEST);
  const multichain = readJson(MULTICHAIN_MANIFEST);
  const publicationInput = readJson(relativeInputPath);
  const templates = collectSourceTemplates(readiness);

  if (readiness.network === "arc-testnet" && readiness.chainId === 5_042_002) {
    pass("source readiness manifest is Arc testnet");
  } else {
    fail("source readiness manifest must be Arc testnet");
  }

  if (multichain.schemaVersion === 1) pass("multichain readiness manifest schemaVersion is 1");
  else fail("multichain readiness manifest schemaVersion must be 1");

  if (publicationInput.sourceManifest === READINESS_MANIFEST) pass("pool-publication input points at readiness manifest");
  else fail("pool-publication input sourceManifest is wrong");

  if (publicationInput.sourceMultichainManifest === MULTICHAIN_MANIFEST) {
    pass("pool-publication input points at multichain manifest");
  } else {
    fail("pool-publication input sourceMultichainManifest is wrong");
  }

  if (templates.length === 11) pass("fill plan derives 11 source pool templates");
  else fail(`fill plan expected 11 source pool templates, found ${templates.length}`);

  for (const template of templates) checkSourceTemplate(template);
  for (const network of requiredNetworks) checkTargetPlan(network, multichain, publicationInput);

  const packet = buildFillPlanPacket(relativeInputPath, publicationInput, multichain, templates);
  const json = `${JSON.stringify(packet, null, 2)}\n`;
  const summary = `summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`;

  if (outPath) {
    const absoluteOutPath = join(ROOT, outPath);
    mkdirSync(dirname(absoluteOutPath), { recursive: true });
    writeFileSync(absoluteOutPath, json);
    console.log("");
    console.log(`wrote ${outPath}`);
    console.log(summary);
    process.exit(counts.FAIL > 0 ? 1 : 0);
  }

  if (checkPath) {
    const current = readFileSync(join(ROOT, checkPath), "utf-8");
    if (current !== json) {
      throw new Error(`${checkPath} is stale; run bun run uniswap:official-multichain:pools:plan:write`);
    }

    console.log("");
    console.log(`${checkPath} is fresh`);
    console.log(summary);
    process.exit(counts.FAIL > 0 ? 1 : 0);
  }

  console.log("");
  console.log("publication fill matrix");
  console.log(json.trimEnd());

  console.log("");
  console.log(summary);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
