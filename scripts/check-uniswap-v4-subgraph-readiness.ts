// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only verifier for the final Uniswap v4 subgraph indexing gate.
// It can query an official subgraph endpoint when one is available, but while
// official Arc v4 is unpublished it validates that the manifest keeps the gate
// explicitly pending and records the exact fields to verify.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const POOL_PUBLICATION_ENV = "OFFICIAL_ARC_POOL_PUBLICATION_INPUT";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

const requiredPoolFields = [
  "id",
  "hooks",
  "liquidity",
  "sqrtPrice",
  "tick",
  "tickSpacing",
  "feeTier",
  "token0",
  "token1",
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
  return typeof value === "string" && ADDRESS_RE.test(value);
}

function isBytes32(value: unknown): value is string {
  return typeof value === "string" && BYTES32_RE.test(value);
}

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function collectPoolTemplates(manifest: AnyRecord): Array<{ symbol: string; poolId: string; hooks: string; family: string }> {
  const templates: Array<{ symbol: string; poolId: string; hooks: string; family: string }> = [];

  for (const family of manifest.hookFamilies ?? []) {
    if (family.deployed === false) continue;
    for (const pool of family.pools ?? []) {
      const hooks = pool.hookAddress ?? family.hookAddress;
      if (isBytes32(pool.poolId) && isAddress(hooks)) {
        templates.push({
          symbol: String(pool.symbol ?? "unknown"),
          poolId: pool.poolId,
          hooks,
          family: String(family.name ?? "unknown"),
        });
      }
    }
  }

  return templates;
}

function sameBigIntString(a: unknown, b: unknown): boolean {
  try {
    if (a == null || b == null || a === "") return false;
    return BigInt(String(a)) === BigInt(String(b));
  } catch {
    return false;
  }
}

function isPositiveBigIntLike(value: unknown): boolean {
  try {
    if (value == null || value === "") return false;
    return BigInt(String(value)) > 0n;
  } catch {
    return false;
  }
}

function normalizePublicationPool(pool: AnyRecord): AnyRecord {
  const key = pool.poolKey ?? {};

  return {
    ...pool,
    currency0: pool.currency0 ?? key.currency0,
    currency1: pool.currency1 ?? key.currency1,
    fee: pool.fee ?? key.fee,
    tickSpacing: pool.tickSpacing ?? key.tickSpacing,
    hooks: pool.hooks ?? key.hooks ?? pool.hookAddress,
  };
}

function officialPoolsForSubgraph(official: AnyRecord, subgraph: AnyRecord): AnyRecord[] {
  const explicitInput = process.env[POOL_PUBLICATION_ENV];
  if (explicitInput) {
    const input = readJson(explicitInput);
    return Array.isArray(input?.officialPools)
      ? input.officialPools.map(normalizePublicationPool)
      : [];
  }

  if (Array.isArray(subgraph.officialPools) && subgraph.officialPools.length > 0) {
    return subgraph.officialPools;
  }

  const publicationPools = official.poolPublication?.officialPools;
  return Array.isArray(publicationPools)
    ? publicationPools.map(normalizePublicationPool)
    : [];
}

async function queryPool(endpoint: string, poolId: string): Promise<AnyRecord | null> {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      query: `
        query VerifyPool($id: ID!) {
          pool(id: $id) {
            id
            hooks
            liquidity
            sqrtPrice
            tick
            tickSpacing
            feeTier
            token0 { id symbol decimals }
            token1 { id symbol decimals }
          }
        }
      `,
      variables: { id: poolId.toLowerCase() },
    }),
  });

  if (!response.ok) {
    fail(`subgraph request failed for ${poolId}: HTTP ${response.status}`);
    return null;
  }

  const payload = await response.json() as AnyRecord;
  if (Array.isArray(payload.errors) && payload.errors.length > 0) {
    fail(`subgraph returned GraphQL errors for ${poolId}: ${JSON.stringify(payload.errors).slice(0, 300)}`);
    return null;
  }

  return payload.data?.pool ?? null;
}

async function checkLiveSubgraph(endpoint: string, pools: AnyRecord[]): Promise<void> {
  for (const pool of pools) {
    if (
      !isBytes32(pool.poolId)
      || !isAddress(pool.hooks)
      || !isAddress(pool.currency0)
      || !isAddress(pool.currency1)
      || pool.fee == null
      || pool.tickSpacing == null
    ) {
      fail(`official subgraph pool entry is invalid for ${pool.symbol ?? "unknown"}`);
      continue;
    }

    const indexed = await queryPool(endpoint, pool.poolId);
    if (!indexed) {
      fail(`${pool.symbol ?? pool.poolId} is missing from the v4 subgraph`);
      continue;
    }

    if (String(indexed.id).toLowerCase() === pool.poolId.toLowerCase()) {
      pass(`${pool.symbol ?? pool.poolId} subgraph id matches poolId`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} subgraph id mismatch`);
    }

    if (sameAddress(indexed.hooks, pool.hooks)) {
      pass(`${pool.symbol ?? pool.poolId} subgraph hooks field matches expected hook`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} subgraph hooks field ${indexed.hooks} does not match ${pool.hooks}`);
    }

    if (sameAddress(indexed.token0?.id, pool.currency0)) {
      pass(`${pool.symbol ?? pool.poolId} subgraph token0 matches PoolKey`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} subgraph token0 ${indexed.token0?.id} does not match ${pool.currency0}`);
    }

    if (sameAddress(indexed.token1?.id, pool.currency1)) {
      pass(`${pool.symbol ?? pool.poolId} subgraph token1 matches PoolKey`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} subgraph token1 ${indexed.token1?.id} does not match ${pool.currency1}`);
    }

    if (sameBigIntString(indexed.feeTier, pool.fee)) {
      pass(`${pool.symbol ?? pool.poolId} subgraph feeTier matches PoolKey`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} subgraph feeTier ${indexed.feeTier} does not match ${pool.fee}`);
    }

    if (sameBigIntString(indexed.tickSpacing, pool.tickSpacing)) {
      pass(`${pool.symbol ?? pool.poolId} subgraph tickSpacing matches PoolKey`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} subgraph tickSpacing ${indexed.tickSpacing} does not match ${pool.tickSpacing}`);
    }

    if (indexed.sqrtPrice != null && indexed.tick != null) {
      pass(`${pool.symbol ?? pool.poolId} subgraph exposes price state`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} subgraph price state is incomplete`);
    }

    if (pool.requireNonzeroLiquidity === false) {
      if (indexed.liquidity != null) pass(`${pool.symbol ?? pool.poolId} subgraph exposes liquidity field`);
      else fail(`${pool.symbol ?? pool.poolId} subgraph liquidity field is missing`);
    } else if (isPositiveBigIntLike(indexed.liquidity)) {
      pass(`${pool.symbol ?? pool.poolId} subgraph liquidity is nonzero`);
    } else {
      fail(`${pool.symbol ?? pool.poolId} subgraph liquidity is not nonzero`);
    }
  }
}

async function main(): Promise<void> {
  console.log("Uniswap v4 subgraph readiness check");
  console.log(`manifest ${MANIFEST}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const manifest = readManifest();
  const official = manifest.officialArcMainnet ?? {};
  const subgraph = official.subgraphVerification ?? {};

  if (typeof manifest.officialUniswapReferences?.v4SubgraphQueries === "string") {
    pass("official v4 subgraph query docs reference is recorded");
  } else {
    fail("official v4 subgraph query docs reference is missing");
  }

  if (manifest.uniswapIndexerModel?.sourceOfTruth === "PoolManager events") {
    pass("manifest records PoolManager events as subgraph source of truth");
  } else {
    fail("manifest must record PoolManager events as the source of truth");
  }

  if (String(manifest.uniswapIndexerModel?.hookField ?? "").includes("hooks")) {
    pass("manifest records hooks as a first-class pool field");
  } else {
    fail("manifest must record the pool hooks field");
  }

  if (subgraph.status === "pending-official-arc-subgraph-and-official-poolids") {
    pass("official Arc subgraph verification is correctly pending");
  } else if (subgraph.status === "ready-to-query") {
    pass("official Arc subgraph verification is marked ready to query");
  } else {
    fail("official Arc subgraph verification status is missing or unknown");
  }

  const fields = new Set<string>(subgraph.requiredPoolFields ?? []);
  for (const field of requiredPoolFields) {
    if (fields.has(field)) pass(`subgraph verification requires pool.${field}`);
    else fail(`subgraph verification is missing pool.${field}`);
  }

  const templates = collectPoolTemplates(manifest);
  if (templates.length >= 11) {
    pass(`${templates.length} Arc-testnet pool templates have poolId + expected hooks for future subgraph checks`);
  } else {
    fail(`expected at least 11 Arc-testnet pool templates, found ${templates.length}`);
  }

  const officialPools = officialPoolsForSubgraph(official, subgraph);
  const endpoint = process.env.UNISWAP_V4_SUBGRAPH_URL || subgraph.endpoint;

  if (subgraph.status === "pending-official-arc-subgraph-and-official-poolids") {
    if (officialPools.length === 0) pass("official subgraph pool list is intentionally empty while pending official redeploy");
    else fail("official subgraph pool list must stay empty while official redeploy is pending");
    warn("official Arc v4 subgraph verification remains pending until official Arc pools are initialized and indexed");
  } else if (!endpoint) {
    fail("UNISWAP_V4_SUBGRAPH_URL or official subgraph endpoint is required when subgraph verification is ready");
  } else if (officialPools.length === 0) {
    fail("official subgraph pool list is empty despite ready-to-query status");
  } else {
    await checkLiveSubgraph(endpoint, officialPools);
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
