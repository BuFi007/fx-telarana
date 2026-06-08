// SPDX-License-Identifier: AGPL-3.0-only
//
// Exports compact hook metadata for Uniswap/indexer handoff. The artifact is
// derived from the larger readiness manifest so it cannot make independent
// official-indexing claims.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { encodeAbiParameters, keccak256 } from "viem";

type AnyRecord = Record<string, any>;

const ROOT = resolve(import.meta.dir, "..");
const DEFAULT_MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const MANIFEST_ENV = "UNISWAP_HOOK_METADATA_MANIFEST";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;
const LOW_14_MASK = 0x3fffn;

function repoRelativePathForValue(label: string, value: string): string {
  if (value.startsWith("/") || value.includes("..")) {
    throw new Error(`${label} must stay inside the repository`);
  }
  return value;
}

function manifestPath(): string {
  return process.env[MANIFEST_ENV]
    ? repoRelativePathForValue(MANIFEST_ENV, process.env[MANIFEST_ENV]!)
    : DEFAULT_MANIFEST;
}

function readManifest(relativeManifestPath: string): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, relativeManifestPath), "utf-8"));
}

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value);
}

function isBytes32(value: unknown): value is string {
  return typeof value === "string" && BYTES32_RE.test(value);
}

function low14Bits(address: string): number {
  return Number(BigInt(address) & LOW_14_MASK);
}

function requireField<T>(label: string, value: T | null | undefined): T {
  if (value == null || value === "") {
    throw new Error(`${label} is required for hook indexer metadata`);
  }
  return value;
}

function poolHookAddress(family: AnyRecord, pool: AnyRecord): string {
  const hooks = pool.hookAddress ?? family.hookAddress;
  if (!isAddress(hooks)) {
    throw new Error(`${family.name} ${pool.symbol ?? "unknown"} has no valid hook address`);
  }
  return hooks;
}

function poolIdFromKey(poolKey: AnyRecord): string {
  return keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [
      poolKey.currency0 as `0x${string}`,
      poolKey.currency1 as `0x${string}`,
      Number(poolKey.fee),
      Number(poolKey.tickSpacing),
      poolKey.hooks as `0x${string}`,
    ],
  ));
}

function hookPermissionsFor(family: AnyRecord, hookAddress: string): AnyRecord {
  const expectedLow14 = Number(requireField(`${family.name}.permissionFlagsLow14Bits`, family.permissionFlagsLow14Bits));
  const actualLow14 = low14Bits(hookAddress);
  if (actualLow14 !== expectedLow14) {
    throw new Error(`${family.name} hook low-14 bits ${actualLow14} do not match ${expectedLow14}`);
  }

  return {
    low14Bits: expectedLow14,
    flags: family.permissions ?? [],
    customDeltas: Boolean(family.customDeltas),
  };
}

function poolMetadata(family: AnyRecord, pool: AnyRecord): AnyRecord {
  if (!isBytes32(pool.poolId)) {
    throw new Error(`${family.name} ${pool.symbol ?? "unknown"} has no valid poolId`);
  }
  if (!isBytes32(pool.initializeTx)) {
    throw new Error(`${family.name} ${pool.symbol ?? "unknown"} has no valid initializeTx`);
  }

  const hooks = poolHookAddress(family, pool);
  const poolKey = {
    currency0: requireField(`${family.name} ${pool.symbol}.currency0`, pool.currency0),
    currency1: requireField(`${family.name} ${pool.symbol}.currency1`, pool.currency1),
    fee: requireField(`${family.name} ${pool.symbol}.fee`, pool.fee),
    tickSpacing: requireField(`${family.name} ${pool.symbol}.tickSpacing`, pool.tickSpacing),
    hooks,
  };
  const derivedPoolId = poolIdFromKey(poolKey);
  if (derivedPoolId.toLowerCase() !== pool.poolId.toLowerCase()) {
    throw new Error(`${family.name} ${pool.symbol ?? "unknown"} poolId does not derive from PoolKey`);
  }

  return {
    symbol: pool.symbol,
    status: pool.status,
    poolManager: family.poolManager,
    hookAddress: hooks,
    poolId: pool.poolId,
    poolKey,
    initializeTx: pool.initializeTx,
    initializeBlock: pool.initializeBlock ?? null,
    configureTx: pool.configureTx ?? null,
    configureBlock: pool.configureBlock ?? null,
    bindGatewayRouteTx: pool.bindGatewayRouteTx ?? null,
    sqrtPriceX96: pool.sqrtPriceX96 ?? null,
  };
}

function familyMetadata(family: AnyRecord): AnyRecord {
  const pools = Array.isArray(family.pools)
    ? family.pools.map((pool: AnyRecord) => poolMetadata(family, pool))
    : [];
  const representativeHook = pools[0]?.hookAddress ?? family.hookAddress ?? null;

  return {
    name: family.name,
    source: family.source,
    deployed: family.deployed,
    poolManager: family.poolManager ?? null,
    hookAddress: family.hookAddress ?? null,
    hookAddressMode: family.hookAddress == null && pools.length > 0 ? "per-pool" : "family",
    hookPermissions: isAddress(representativeHook) ? hookPermissionsFor(family, representativeHook) : null,
    indexerStatus: family.indexerStatus ?? null,
    routerQuoterStatus: family.routerQuoterStatus ?? null,
    liquidityReadiness: family.liquidityReadiness ?? null,
    pools,
  };
}

function buildPacket(manifest: AnyRecord, relativeManifestPath: string): AnyRecord {
  const hookFamilies = (manifest.hookFamilies ?? []).map((family: AnyRecord) => familyMetadata(family));
  const poolCount = hookFamilies.reduce((sum: number, family: AnyRecord) => sum + family.pools.length, 0);

  return {
    schemaVersion: 1,
    generatedFrom: relativeManifestPath,
    network: manifest.network,
    chainId: manifest.chainId,
    generatedAt: manifest.generatedAt,
    project: {
      name: "fx-Telarana",
      repository: "https://github.com/BuFi007/fx-telarana",
      purpose: "Uniswap v4 hook metadata for indexer/reviewer handoff",
    },
    officialIndexingCaveat: {
      arcMainnetStatus: manifest.officialArcMainnet?.status,
      arcMainnetChainId: manifest.officialArcMainnet?.chainId,
      selfDeployedArcTestnetIsOfficial: false,
      doNotClaimYet: manifest.submissionPackage?.doNotClaimYet ?? [],
    },
    uniswapIndexerModel: manifest.uniswapIndexerModel,
    officialArcPoolPublication: manifest.officialArcMainnet?.poolPublication,
    officialMultichainTargets: manifest.officialMultichain?.targets ?? [],
    summary: {
      hookFamilyCount: hookFamilies.length,
      publishedArcTestnetPoolCount: poolCount,
    },
    hookFamilies,
    evidenceCommands: {
      readiness: manifest.evidenceCommands?.offlineReadiness,
      metadataExport: manifest.evidenceCommands?.hookMetadataExport,
      metadataCheck: manifest.evidenceCommands?.hookMetadataFreshness,
      metadataSelfTest: manifest.evidenceCommands?.hookMetadataSelfTest,
      officialArcPoolPublication: manifest.evidenceCommands?.officialArcPoolPublicationCheck,
      officialMultichainReadiness: manifest.evidenceCommands?.officialMultichainReadiness,
    },
  };
}

function repoRelativePathFor(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  if (index === -1) return undefined;

  const value = process.argv[index + 1];
  if (!value) throw new Error(`${flag} requires a relative path`);
  return repoRelativePathForValue(flag, value);
}

function main(): void {
  const relativeManifestPath = manifestPath();
  const manifest = readManifest(relativeManifestPath);
  const packet = buildPacket(manifest, relativeManifestPath);
  const json = `${JSON.stringify(packet, null, 2)}\n`;
  const outPath = repoRelativePathFor("--out");
  const checkPath = repoRelativePathFor("--check");

  if (outPath && checkPath) throw new Error("use either --out or --check, not both");

  if (outPath) {
    const absoluteOutPath = join(ROOT, outPath);
    mkdirSync(dirname(absoluteOutPath), { recursive: true });
    writeFileSync(absoluteOutPath, json);
    console.log(`wrote ${outPath}`);
    return;
  }

  if (checkPath) {
    if (!existsSync(join(ROOT, checkPath))) {
      throw new Error(`${checkPath} does not exist`);
    }
    const current = readFileSync(join(ROOT, checkPath), "utf-8");
    if (current !== json) {
      throw new Error(`${checkPath} is stale; run bun run uniswap:hook-metadata:write`);
    }
    console.log(`${checkPath} is fresh`);
    return;
  }

  console.log(json.trimEnd());
}

main();
