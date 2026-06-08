// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only verifier for target-chain Universal Router execution evidence
// across Arc, Avalanche Fuji, Avalanche, and Arbitrum. It validates the pending
// shape today and enforces execution evidence or explicit custom-route caveats
// once official pool publication records exist.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const DEFAULT_POOL_PUBLICATION_INPUT = "deployments/uniswap-v4-official-multichain-pools.template.json";
const INPUT_ENV = "OFFICIAL_MULTICHAIN_POOL_PUBLICATION_INPUT";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

const requiredNetworks = [
  "arc-mainnet",
  "avalanche-fuji",
  "avalanche",
  "arbitrum-one",
] as const;

const requiredContracts = [
  "UniversalRouter",
  "Permit2",
  "PoolManager",
] as const;

const requiredPoolFields = [
  "poolId",
  "poolKey",
  "routerQuoterStatus",
  "routerExecution",
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

function isFilledString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function targetByNetwork(manifest: AnyRecord, network: string): AnyRecord {
  return (manifest.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function publicationTarget(input: AnyRecord, network: string): AnyRecord {
  return (input.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function normalizePool(pool: AnyRecord): AnyRecord {
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

function executionEvidenceIsPopulated(value: unknown, target: AnyRecord, pool: AnyRecord, ready: boolean): boolean {
  if (!value || typeof value !== "object") return false;

  const evidence = value as AnyRecord;
  const status = String(evidence.status ?? evidence.result ?? "").toLowerCase();
  const hasPositiveStatus = /pass|passed|supported|proven|verified|prepared/.test(status)
    && !/unsupported|not-supported|fail|failed/.test(status);
  if (!hasPositiveStatus) return false;

  const hasContext = [
    evidence.command,
    evidence.universalRouter,
    evidence.permit2,
    evidence.poolManager,
    evidence.planner,
    evidence.hookData,
    evidence.note,
  ].some(isFilledString);
  if (!hasContext) return false;

  if (ready && isAddress(target.contracts?.UniversalRouter) && isAddress(evidence.universalRouter)) {
    if (!sameAddress(evidence.universalRouter, target.contracts.UniversalRouter)) return false;
  }

  if (ready && isAddress(target.contracts?.Permit2) && isAddress(evidence.permit2)) {
    if (!sameAddress(evidence.permit2, target.contracts.Permit2)) return false;
  }

  if (ready && isAddress(target.contracts?.PoolManager) && isAddress(evidence.poolManager)) {
    if (!sameAddress(evidence.poolManager, target.contracts.PoolManager)) return false;
  }

  if (ready && isBytes32(pool.poolId) && isBytes32(evidence.poolId)) {
    if (String(evidence.poolId).toLowerCase() !== String(pool.poolId).toLowerCase()) return false;
  }

  return true;
}

function routerExecutionEvidence(pool: AnyRecord, status: AnyRecord, target: AnyRecord, ready: boolean): boolean {
  const candidates = [
    pool.routerExecution,
    pool.routerExecution?.universalRouterExecution,
    pool.routerExecution?.universalRouterDiagnostic,
    pool.routerExecution?.v4PlannerExecution,
    pool.routerExecution?.routeExecutionDiagnostic,
    status.routerExecution,
    status.universalRouterExecution,
    status.universalRouterDiagnostic,
    status.v4PlannerExecution,
    status.routeExecutionDiagnostic,
  ];

  if (candidates.some((evidence) => executionEvidenceIsPopulated(evidence, target, pool, ready))) {
    return true;
  }

  if (ready) return false;

  const textEvidence = [
    pool.routerExecution,
    status.exactInput,
    status.officialExactInput,
    status.supportedInternalQuote,
  ]
    .filter(isFilledString)
    .join("\n")
    .toLowerCase();

  return /universal router|v4planner|protocol router|exact-input|supported|fixture/.test(textEvidence)
    && !/unsupported|not-supported|fail|failed/.test(textEvidence);
}

function customRouteCaveat(status: AnyRecord): boolean {
  return [
    status.customRouteCaveat,
    status.settlementCaveat,
    status.hookData,
    status.genericV4Quoter,
    status.targetRequirement,
  ]
    .filter(isFilledString)
    .some((value) => /not-generic|custom|required|attestation|gateway|settlement|protocol router|direct quote/i.test(value));
}

function checkRouterConfig(manifest: AnyRecord): void {
  const router = manifest.routerExecutionVerification ?? {};

  if (typeof router.command === "string" && router.command.includes("uniswap:official-multichain:router:check")) {
    pass("multichain router execution command is recorded");
  } else {
    fail("multichain router execution command is missing");
  }

  if (router.poolPublicationInputEnv === INPUT_ENV) {
    pass(`multichain router execution reads ${INPUT_ENV}`);
  } else {
    fail(`multichain router execution must record ${INPUT_ENV}`);
  }

  const contracts = new Set<string>(router.requiredContracts ?? []);
  for (const contract of requiredContracts) {
    if (contracts.has(contract)) pass(`multichain router execution requires ${contract}`);
    else fail(`multichain router execution is missing ${contract}`);
  }

  const fields = new Set<string>(router.requiredPoolFields ?? []);
  for (const field of requiredPoolFields) {
    if (fields.has(field)) pass(`multichain router execution requires pool.${field}`);
    else fail(`multichain router execution is missing pool.${field}`);
  }

  const checks = Array.isArray(router.requiredChecks) ? router.requiredChecks.join("\n") : "";
  for (const snippet of [
    "official Uniswap v4 deployments",
    "Universal Router",
    "Permit2",
    "FxHedgeHook",
    "custom-route caveat",
  ]) {
    if (checks.includes(snippet)) pass(`multichain router execution checks cover ${snippet}`);
    else fail(`multichain router execution checks must cover ${snippet}`);
  }
}

function checkPool(target: AnyRecord, pool: AnyRecord, ready: boolean): void {
  const normalized = normalizePool(pool);
  const label = `${target.network} ${normalized.family ?? "unknown"} ${normalized.symbol ?? normalized.poolId ?? "unknown"}`;
  const status = normalized.routerQuoterStatus;

  if (!isBytes32(normalized.poolId)) {
    fail(`${label} poolId is invalid`);
    return;
  }

  if (isAddress(normalized.currency0) && isAddress(normalized.currency1) && isAddress(normalized.hooks)) {
    pass(`${label} has complete PoolKey addresses for router execution input`);
  } else {
    fail(`${label} has incomplete PoolKey addresses for router execution input`);
  }

  if (normalized.fee != null && normalized.tickSpacing != null) pass(`${label} has fee and tickSpacing for router execution input`);
  else fail(`${label} is missing fee or tickSpacing for router execution input`);

  if (status && typeof status === "object") {
    pass(`${label} routerQuoterStatus is recorded`);
  } else {
    fail(`${label} routerQuoterStatus is missing`);
    return;
  }

  const hasRouterExecution = routerExecutionEvidence(normalized, status, target, ready);
  const hasCustomRoute = customRouteCaveat(status);

  if (String(normalized.family) === "FxHedgeHook" && ready) {
    if (hasRouterExecution) pass(`${label} ready FxHedgeHook router execution evidence is recorded`);
    else fail(`${label} ready FxHedgeHook pool requires official Universal Router execution evidence`);
    return;
  }

  if (hasRouterExecution) {
    pass(`${label} router execution evidence is recorded`);
  } else if (hasCustomRoute) {
    pass(`${label} has documented custom-route execution caveat`);
  } else {
    fail(`${label} requires Universal Router execution evidence or a custom-route caveat`);
  }
}

function checkTarget(multichain: AnyRecord, publicationInput: AnyRecord, network: string): void {
  const target = targetByNetwork(multichain, network);
  const publication = publicationTarget(publicationInput, network);
  const pools = Array.isArray(publication.officialPools) ? publication.officialPools : [];

  if (target.network === network) pass(`${network} exists in multichain manifest`);
  else fail(`${network} is missing from multichain manifest`);

  if (publication.network === network) pass(`${network} exists in pool-publication input`);
  else fail(`${network} is missing from pool-publication input`);

  if (target.status === "pending-official-uniswap-v4-addresses") {
    if (
      target.contracts?.UniversalRouter == null
      && target.contracts?.Permit2 == null
      && publication.officialPoolManager == null
    ) {
      pass(`${network} router contracts are intentionally unset while official addresses are pending`);
    } else {
      fail(`${network} router contracts must stay unset while official addresses are pending`);
    }

    if (pools.length === 0) pass(`${network} router execution pool list is empty while official addresses are pending`);
    else fail(`${network} router execution pool list must stay empty while official addresses are pending`);

    warn(`${network} router execution verification remains pending official Uniswap v4 addresses`);
    return;
  }

  if (isAddress(target.contracts?.UniversalRouter)) pass(`${network} official Universal Router address is recorded`);
  else fail(`${network} official Universal Router address is missing`);

  if (isAddress(target.contracts?.Permit2)) pass(`${network} official Permit2 address is recorded`);
  else fail(`${network} official Permit2 address is missing`);

  if (publication.status === "pending-official-hook-pool-publication") {
    if (pools.length === 0) pass(`${network} router execution pool list is empty until hook pools are published`);
    else fail(`${network} pending hook-pool publication must not carry router execution records`);

    warn(`${network} router execution verification remains pending official hook-pool publication`);
    return;
  }

  if (publication.status === "draft") warn(`${network} router execution publication is draft-only and not a readiness claim`);
  if (publication.status === "ready") pass(`${network} router execution publication is marked ready`);

  if (pools.length === Number(publicationInput.expectedPoolTemplateCount)) {
    pass(`${network} router execution pool count matches expected template count`);
  } else {
    fail(`${network} router execution pool count ${pools.length} does not match ${publicationInput.expectedPoolTemplateCount}`);
  }

  for (const pool of pools) checkPool(target, pool, publication.status === "ready");
}

function main(): void {
  const relativeInputPath = inputPath();
  console.log("Official Uniswap v4 multichain router execution readiness check");
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

  checkRouterConfig(multichain);
  for (const network of requiredNetworks) checkTarget(multichain, publicationInput, network);

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
