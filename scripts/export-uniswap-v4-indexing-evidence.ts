// SPDX-License-Identifier: AGPL-3.0-only
//
// Exports a single read-only JSON packet for Uniswap/indexer review.
// It derives the packet from the readiness manifest so the submission evidence
// stays tied to the same fields validated by the local check scripts.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

type AnyRecord = Record<string, any>;

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

function readManifest(): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, MANIFEST), "utf-8"));
}

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value);
}

function isBytes32(value: unknown): value is string {
  return typeof value === "string" && BYTES32_RE.test(value);
}

function requireField<T>(label: string, value: T | null | undefined): T {
  if (value == null || value === "") {
    throw new Error(`${label} is required for indexing evidence export`);
  }
  return value;
}

function poolKeyFor(family: AnyRecord, pool: AnyRecord): AnyRecord {
  const hooks = pool.hookAddress ?? family.hookAddress;
  if (!isAddress(hooks)) {
    throw new Error(`${family.name} ${pool.symbol ?? "unknown"} has no valid hook address`);
  }

  return {
    currency0: requireField(`${family.name} ${pool.symbol}.currency0`, pool.currency0),
    currency1: requireField(`${family.name} ${pool.symbol}.currency1`, pool.currency1),
    fee: requireField(`${family.name} ${pool.symbol}.fee`, pool.fee),
    tickSpacing: requireField(`${family.name} ${pool.symbol}.tickSpacing`, pool.tickSpacing),
    hooks,
  };
}

function collectPools(manifest: AnyRecord): AnyRecord[] {
  const pools: AnyRecord[] = [];

  for (const family of manifest.hookFamilies ?? []) {
    if (family.deployed === false) continue;

    for (const pool of family.pools ?? []) {
      if (!isBytes32(pool.poolId)) {
        throw new Error(`${family.name} ${pool.symbol ?? "unknown"} has no valid poolId`);
      }

      if (!isBytes32(pool.initializeTx)) {
        throw new Error(`${family.name} ${pool.symbol ?? "unknown"} has no valid initializeTx`);
      }

      pools.push({
        family: family.name,
        symbol: pool.symbol,
        status: pool.status,
        poolManager: family.poolManager,
        poolId: pool.poolId,
        poolKey: poolKeyFor(family, pool),
        initializeTx: pool.initializeTx,
        initializeBlock: pool.initializeBlock ?? null,
        configureTx: pool.configureTx ?? null,
        configureBlock: pool.configureBlock ?? null,
        bindGatewayRouteTx: pool.bindGatewayRouteTx ?? null,
        sqrtPriceX96: pool.sqrtPriceX96 ?? null,
        hookPermissions: {
          low14Bits: family.permissionFlagsLow14Bits,
          flags: family.permissions ?? [],
          customDeltas: Boolean(family.customDeltas),
        },
        liquidityReadiness: family.liquidityReadiness ?? null,
        routerQuoterStatus: family.routerQuoterStatus ?? null,
      });
    }
  }

  return pools;
}

function buildPacket(manifest: AnyRecord): AnyRecord {
  const pools = collectPools(manifest);

  return {
    schemaVersion: 1,
    generatedFrom: MANIFEST,
    network: manifest.network,
    chainId: manifest.chainId,
    generatedAt: manifest.generatedAt,
    officialUniswapReferences: manifest.officialUniswapReferences,
    indexerModel: manifest.uniswapIndexerModel,
    arcTestnet: manifest.arcTestnet,
    officialArcMainnet: {
      status: manifest.officialArcMainnet?.status,
      chainId: manifest.officialArcMainnet?.chainId,
      contracts: manifest.officialArcMainnet?.contracts,
      requiredContracts: manifest.officialArcMainnet?.requiredContracts,
      hookRedeployPlan: manifest.officialArcMainnet?.hookRedeployPlan,
      deploymentInputTemplate: manifest.officialArcMainnet?.deploymentInputTemplate,
      deploymentInputGenerateCommand: manifest.officialArcMainnet?.deploymentInputGenerateCommand,
      currentDeploymentInputGenerateResult: manifest.officialArcMainnet?.currentDeploymentInputGenerateResult,
      deploymentInputGenerateSelfTestCommand: manifest.officialArcMainnet?.deploymentInputGenerateSelfTestCommand,
      currentDeploymentInputGenerateSelfTestResult: manifest.officialArcMainnet?.currentDeploymentInputGenerateSelfTestResult,
      deploymentInputCheckCommand: manifest.officialArcMainnet?.deploymentInputCheckCommand,
      currentDeploymentInputResult: manifest.officialArcMainnet?.currentDeploymentInputResult,
      deploymentInputSelfTestCommand: manifest.officialArcMainnet?.deploymentInputSelfTestCommand,
      currentDeploymentInputSelfTestResult: manifest.officialArcMainnet?.currentDeploymentInputSelfTestResult,
      deploymentInputRequiredChecks: manifest.officialArcMainnet?.deploymentInputRequiredChecks,
      poolPublication: manifest.officialArcMainnet?.poolPublication,
      migrationChecklist: manifest.officialArcMainnet?.migrationChecklist,
      stateViewVerification: manifest.officialArcMainnet?.stateViewVerification,
      subgraphVerification: manifest.officialArcMainnet?.subgraphVerification,
    },
    officialMultichain: manifest.officialMultichain,
    pools,
    evidenceCommands: manifest.evidenceCommands,
    submissionPackage: manifest.submissionPackage,
  };
}

function repoRelativePathFor(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  if (index === -1) return undefined;

  const value = process.argv[index + 1];
  if (!value) {
    throw new Error(`${flag} requires a relative path`);
  }

  if (value.startsWith("/") || value.includes("..")) {
    throw new Error(`${flag} must stay inside the repository`);
  }

  return value;
}

function main(): void {
  const manifest = readManifest();
  const packet = buildPacket(manifest);
  const json = `${JSON.stringify(packet, null, 2)}\n`;
  const outPath = repoRelativePathFor("--out");
  const checkPath = repoRelativePathFor("--check");

  if (outPath && checkPath) {
    throw new Error("use either --out or --check, not both");
  }

  if (outPath) {
    const absoluteOutPath = join(ROOT, outPath);
    mkdirSync(dirname(absoluteOutPath), { recursive: true });
    writeFileSync(absoluteOutPath, json);
    console.log(`wrote ${outPath}`);
    return;
  }

  if (checkPath) {
    const current = readFileSync(join(ROOT, checkPath), "utf-8");
    if (current !== json) {
      throw new Error(`${checkPath} is stale; run bun run uniswap:evidence:write`);
    }

    console.log(`${checkPath} is fresh`);
    return;
  }

  console.log(json.trimEnd());
}

main();
