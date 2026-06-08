// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only verifier for target-chain Uniswap v4 subgraph evidence across
// Arc, Avalanche Fuji, Avalanche, and Arbitrum. It validates the pending shape
// today and can query pool entities once official pool records exist.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const DEFAULT_POOL_PUBLICATION_INPUT = "deployments/uniswap-v4-official-multichain-pools.template.json";
const INPUT_ENV = "OFFICIAL_MULTICHAIN_POOL_PUBLICATION_INPUT";
const ENDPOINT_ENV = "UNISWAP_V4_SUBGRAPH_URL";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

const requiredNetworks = [
  "arc-mainnet",
  "avalanche-fuji",
  "avalanche",
  "arbitrum-one",
] as const;

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

function inputPath(): string {
  return process.env[INPUT_ENV] || DEFAULT_POOL_PUBLICATION_INPUT;
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
  return typeof value === "string" && ADDRESS_RE.test(value) && !ZERO_ADDRESS_RE.test(value);
}

function isBytes32(value: unknown): value is string {
  return typeof value === "string" && BYTES32_RE.test(value);
}

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
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

function targetByNetwork(manifest: AnyRecord, network: string): AnyRecord {
  return (manifest.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function publicationTarget(input: AnyRecord, network: string): AnyRecord {
  return (input.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function normalizePool(pool: AnyRecord): AnyRecord {
  const key = pool.poolKey ?? {};
  const subgraphEvidence = pool.subgraphVerification ?? {};

  return {
    ...pool,
    currency0: pool.currency0 ?? key.currency0,
    currency1: pool.currency1 ?? key.currency1,
    fee: pool.fee ?? key.fee,
    tickSpacing: pool.tickSpacing ?? key.tickSpacing,
    hooks: pool.hooks ?? key.hooks ?? pool.hookAddress,
    subgraphId: pool.subgraphId ?? subgraphEvidence.id ?? pool.poolId,
    liquidity: pool.liquidity ?? subgraphEvidence.liquidity,
    sqrtPrice: pool.sqrtPrice ?? subgraphEvidence.sqrtPrice,
    tick: pool.tick ?? subgraphEvidence.tick,
  };
}

function endpointFor(manifest: AnyRecord, target: AnyRecord, publication: AnyRecord): string | undefined {
  const subgraph = manifest.subgraphVerification ?? {};
  const endpointEnv = publication.subgraphEndpointEnv ?? target.subgraphEndpointEnv ?? subgraph.endpointEnv;
  if (typeof endpointEnv === "string" && process.env[endpointEnv]) return process.env[endpointEnv];
  if (process.env[ENDPOINT_ENV]) return process.env[ENDPOINT_ENV];
  if (typeof publication.subgraphEndpoint === "string") return publication.subgraphEndpoint;
  if (typeof target.subgraphEndpoint === "string") return target.subgraphEndpoint;
  if (typeof subgraph.endpoint === "string") return subgraph.endpoint;
  return undefined;
}

function checkSubgraphConfig(manifest: AnyRecord): void {
  const subgraph = manifest.subgraphVerification ?? {};

  if (typeof subgraph.command === "string" && subgraph.command.includes("uniswap:official-multichain:subgraph:check")) {
    pass("multichain subgraph verification command is recorded");
  } else {
    fail("multichain subgraph verification command is missing");
  }

  if (subgraph.poolPublicationInputEnv === INPUT_ENV) {
    pass(`multichain subgraph verification reads ${INPUT_ENV}`);
  } else {
    fail(`multichain subgraph verification must record ${INPUT_ENV}`);
  }

  if (subgraph.endpointEnv === ENDPOINT_ENV) {
    pass(`multichain subgraph verification records ${ENDPOINT_ENV}`);
  } else {
    fail(`multichain subgraph verification endpoint env must be ${ENDPOINT_ENV}`);
  }

  if (subgraph.requiredSource === "Uniswap v4 subgraph pool entity") {
    pass("multichain subgraph verification requires v4 pool entities");
  } else {
    fail("multichain subgraph verification requiredSource is missing");
  }

  const fields = new Set<string>(subgraph.requiredPoolFields ?? []);
  for (const field of requiredPoolFields) {
    if (fields.has(field)) pass(`multichain subgraph verification requires pool.${field}`);
    else fail(`multichain subgraph verification is missing pool.${field}`);
  }
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

async function verifyLiveSubgraph(endpoint: string, network: string, pools: AnyRecord[]): Promise<void> {
  for (const pool of pools.map(normalizePool)) {
    const label = `${network} ${pool.family ?? "unknown"} ${pool.symbol ?? pool.poolId ?? "unknown"}`;

    if (
      !isBytes32(pool.poolId)
      || !isAddress(pool.hooks)
      || !isAddress(pool.currency0)
      || !isAddress(pool.currency1)
      || pool.fee == null
      || pool.tickSpacing == null
    ) {
      fail(`${label} has incomplete subgraph verification input`);
      continue;
    }

    const indexed = await queryPool(endpoint, pool.poolId);
    if (!indexed) {
      fail(`${label} is missing from the v4 subgraph`);
      continue;
    }

    if (String(indexed.id).toLowerCase() === String(pool.subgraphId ?? pool.poolId).toLowerCase()) {
      pass(`${label} subgraph id matches poolId`);
    } else {
      fail(`${label} subgraph id mismatch`);
    }

    if (sameAddress(indexed.hooks, pool.hooks)) {
      pass(`${label} subgraph hooks match PoolKey`);
    } else {
      fail(`${label} subgraph hooks ${indexed.hooks} do not match ${pool.hooks}`);
    }

    if (sameAddress(indexed.token0?.id, pool.currency0)) pass(`${label} subgraph token0 matches PoolKey`);
    else fail(`${label} subgraph token0 ${indexed.token0?.id} does not match ${pool.currency0}`);

    if (sameAddress(indexed.token1?.id, pool.currency1)) pass(`${label} subgraph token1 matches PoolKey`);
    else fail(`${label} subgraph token1 ${indexed.token1?.id} does not match ${pool.currency1}`);

    if (sameBigIntString(indexed.feeTier, pool.fee)) pass(`${label} subgraph feeTier matches PoolKey`);
    else fail(`${label} subgraph feeTier ${indexed.feeTier} does not match ${pool.fee}`);

    if (sameBigIntString(indexed.tickSpacing, pool.tickSpacing)) pass(`${label} subgraph tickSpacing matches PoolKey`);
    else fail(`${label} subgraph tickSpacing ${indexed.tickSpacing} does not match ${pool.tickSpacing}`);

    if (indexed.sqrtPrice != null && indexed.tick != null) pass(`${label} subgraph exposes price state`);
    else fail(`${label} subgraph price state is incomplete`);

    if (pool.sqrtPrice == null || sameBigIntString(indexed.sqrtPrice, pool.sqrtPrice)) {
      pass(`${label} subgraph sqrtPrice matches published evidence or is unconstrained`);
    } else {
      fail(`${label} subgraph sqrtPrice does not match published evidence`);
    }

    if (pool.tick == null || sameBigIntString(indexed.tick, pool.tick)) {
      pass(`${label} subgraph tick matches published evidence or is unconstrained`);
    } else {
      fail(`${label} subgraph tick does not match published evidence`);
    }

    if (pool.requireNonzeroLiquidity === false || pool.routerActiveClaim === false) {
      if (indexed.liquidity != null) pass(`${label} subgraph liquidity field is readable`);
      else fail(`${label} subgraph liquidity field is missing`);
    } else if (isPositiveBigIntLike(indexed.liquidity)) {
      pass(`${label} subgraph liquidity is nonzero`);
    } else {
      fail(`${label} subgraph liquidity is not nonzero`);
    }
  }
}

async function checkTarget(multichain: AnyRecord, publicationInput: AnyRecord, network: string): Promise<void> {
  const target = targetByNetwork(multichain, network);
  const publication = publicationTarget(publicationInput, network);
  const pools = Array.isArray(publication.officialPools) ? publication.officialPools : [];

  if (target.network === network) pass(`${network} exists in multichain manifest`);
  else fail(`${network} is missing from multichain manifest`);

  if (publication.network === network) pass(`${network} exists in pool-publication input`);
  else fail(`${network} is missing from pool-publication input`);

  if (target.status === "pending-official-uniswap-v4-addresses") {
    if (pools.length === 0) pass(`${network} subgraph pool list is empty while official addresses are pending`);
    else fail(`${network} subgraph pool list must stay empty while official addresses are pending`);

    warn(`${network} subgraph verification remains pending official Uniswap v4 addresses`);
    return;
  }

  if (target.status === "official-uniswap-v4-addresses-published") {
    pass(`${network} official v4 contracts are published before subgraph pool claims`);
  } else {
    fail(`${network} target status does not permit subgraph pool claims`);
  }

  if (publication.status === "pending-official-hook-pool-publication") {
    if (pools.length === 0) pass(`${network} subgraph pool list is empty until hook pools are published`);
    else fail(`${network} pending hook-pool publication must not carry subgraph pool records`);

    warn(`${network} subgraph verification remains pending official hook-pool publication`);
    return;
  }

  if (publication.status === "draft") warn(`${network} subgraph publication is draft-only and not a readiness claim`);
  if (publication.status === "ready") pass(`${network} subgraph publication is marked ready`);

  if (pools.length === Number(publicationInput.expectedPoolTemplateCount)) {
    pass(`${network} subgraph pool count matches expected template count`);
  } else {
    fail(`${network} subgraph pool count ${pools.length} does not match ${publicationInput.expectedPoolTemplateCount}`);
  }

  const endpoint = endpointFor(multichain, target, publication);
  if (publication.status === "ready" && !endpoint) {
    fail(`${network} ready subgraph verification requires ${ENDPOINT_ENV} or a chain endpoint`);
  } else if (endpoint) {
    await verifyLiveSubgraph(endpoint, network, pools);
  } else {
    warn(`${network} subgraph live reads skipped until ${ENDPOINT_ENV} is configured`);
  }
}

async function main(): Promise<void> {
  const relativeInputPath = inputPath();
  console.log("Official Uniswap v4 multichain subgraph readiness check");
  console.log(`multichain ${MULTICHAIN_MANIFEST}`);
  console.log(`pool publication input ${relativeInputPath}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const multichain = readJson(MULTICHAIN_MANIFEST);
  const publicationInput = readJson(relativeInputPath);

  if (multichain.schemaVersion === 1) pass("multichain readiness manifest schemaVersion is 1");
  else fail("multichain readiness manifest schemaVersion must be 1");

  if (publicationInput.sourceMultichainManifest === MULTICHAIN_MANIFEST) {
    pass("pool-publication input points at multichain manifest");
  } else {
    fail("pool-publication input sourceMultichainManifest is wrong");
  }

  checkSubgraphConfig(multichain);
  for (const network of requiredNetworks) await checkTarget(multichain, publicationInput, network);

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
