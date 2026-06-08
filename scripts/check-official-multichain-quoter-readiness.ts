// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only verifier for target-chain Uniswap v4 Quoter evidence across Arc,
// Avalanche Fuji, Avalanche, and Arbitrum. It validates the pending shape today
// and enforces exact-input Quoter evidence or explicit custom-route caveats
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

const requiredPoolFields = [
  "poolId",
  "poolKey",
  "routerQuoterStatus",
  "quoteExactInput",
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

function diagnosticEvidenceIsPopulated(value: unknown, target: AnyRecord, pool: AnyRecord, ready: boolean): boolean {
  if (!value || typeof value !== "object") return false;

  const evidence = value as AnyRecord;
  const status = String(evidence.status ?? evidence.result ?? "").toLowerCase();
  const hasPositiveStatus = /pass|passed|supported|proven|verified/.test(status)
    && !/unsupported|not-supported|fail|failed/.test(status);
  if (!hasPositiveStatus) return false;

  const hasContext = [
    evidence.command,
    evidence.quoter,
    evidence.poolManager,
    evidence.hookData,
    evidence.note,
  ].some(isFilledString);
  if (!hasContext) return false;

  if (ready && isAddress(target.contracts?.Quoter) && isAddress(evidence.quoter)) {
    if (!sameAddress(evidence.quoter, target.contracts.Quoter)) return false;
  }

  if (ready && isAddress(target.contracts?.PoolManager) && isAddress(evidence.poolManager)) {
    if (!sameAddress(evidence.poolManager, target.contracts.PoolManager)) return false;
  }

  if (ready && isBytes32(pool.poolId) && isBytes32(evidence.poolId)) {
    if (String(evidence.poolId).toLowerCase() !== String(pool.poolId).toLowerCase()) return false;
  }

  return true;
}

function exactInputEvidence(status: AnyRecord, target: AnyRecord, pool: AnyRecord, ready: boolean): boolean {
  const diagnosticEvidence = [
    status.officialV4QuoterExactInputDiagnostic,
    status.targetV4QuoterExactInputDiagnostic,
    status.v4QuoterExactInputDiagnostic,
    status.v4QuoterDiagnostic,
    status.quoterDiagnostic,
  ].some((evidence) => diagnosticEvidenceIsPopulated(evidence, target, pool, ready));

  if (diagnosticEvidence) return true;
  if (ready) return false;

  const exactInput = String(status.exactInput ?? status.officialExactInput ?? "").toLowerCase();
  return /support|pass|proven|fixture/.test(exactInput) && !/unsupported|not-supported|fail/.test(exactInput);
}

function poolHasExactInputEvidence(pool: AnyRecord, status: AnyRecord, target: AnyRecord, ready: boolean): boolean {
  if (diagnosticEvidenceIsPopulated(pool.quoteExactInput, target, pool, ready)) return true;

  const quoteExactInput = String(pool.quoteExactInput ?? "").toLowerCase();
  if (
    /support|pass|proven|verified|fixture/.test(quoteExactInput)
    && !/unsupported|not-supported|fail|failed/.test(quoteExactInput)
  ) {
    return true;
  }

  return exactInputEvidence(status, target, pool, ready);
}

function customRouteCaveat(status: AnyRecord): boolean {
  return [
    status.customRouteCaveat,
    status.settlementCaveat,
    status.hookData,
    status.genericV4Quoter,
  ]
    .filter(isFilledString)
    .some((value) => /not-generic|custom|required|attestation|gateway|settlement|protocol router|direct quote/i.test(value));
}

function checkQuoterConfig(manifest: AnyRecord): void {
  const quoter = manifest.quoterVerification ?? {};

  if (typeof quoter.command === "string" && quoter.command.includes("uniswap:official-multichain:quoter:check")) {
    pass("multichain Quoter verification command is recorded");
  } else {
    fail("multichain Quoter verification command is missing");
  }

  if (quoter.poolPublicationInputEnv === INPUT_ENV) {
    pass(`multichain Quoter verification reads ${INPUT_ENV}`);
  } else {
    fail(`multichain Quoter verification must record ${INPUT_ENV}`);
  }

  if (quoter.requiredContract === "Quoter") {
    pass("multichain Quoter verification requires Quoter");
  } else {
    fail("multichain Quoter verification requiredContract is missing");
  }

  const fields = new Set<string>(quoter.requiredPoolFields ?? []);
  for (const field of requiredPoolFields) {
    if (fields.has(field)) pass(`multichain Quoter verification requires pool.${field}`);
    else fail(`multichain Quoter verification is missing pool.${field}`);
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
    pass(`${label} has complete PoolKey addresses for Quoter input`);
  } else {
    fail(`${label} has incomplete PoolKey addresses for Quoter input`);
  }

  if (normalized.fee != null && normalized.tickSpacing != null) pass(`${label} has fee and tickSpacing for Quoter input`);
  else fail(`${label} is missing fee or tickSpacing for Quoter input`);

  if (status && typeof status === "object") {
    pass(`${label} routerQuoterStatus is recorded`);
  } else {
    fail(`${label} routerQuoterStatus is missing`);
    return;
  }

  const hasExactInput = poolHasExactInputEvidence(normalized, status, target, ready);
  const hasCustomRoute = customRouteCaveat(status);

  if (String(normalized.family) === "FxHedgeHook" && ready) {
    if (hasExactInput) pass(`${label} ready FxHedgeHook exact-input Quoter evidence is recorded`);
    else fail(`${label} ready FxHedgeHook pool requires official exact-input Quoter evidence`);
    return;
  }

  if (hasExactInput) {
    pass(`${label} exact-input Quoter evidence is recorded`);
  } else if (hasCustomRoute) {
    pass(`${label} has documented custom-route Quoter caveat`);
  } else {
    fail(`${label} requires exact-input Quoter evidence or a custom-route caveat`);
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
    if (target.contracts?.Quoter == null && publication.officialPoolManager == null) {
      pass(`${network} Quoter is intentionally unset while official addresses are pending`);
    } else {
      fail(`${network} Quoter must stay unset while official addresses are pending`);
    }

    if (pools.length === 0) pass(`${network} Quoter pool list is empty while official addresses are pending`);
    else fail(`${network} Quoter pool list must stay empty while official addresses are pending`);

    warn(`${network} Quoter verification remains pending official Uniswap v4 addresses`);
    return;
  }

  if (isAddress(target.contracts?.Quoter)) pass(`${network} official Quoter address is recorded`);
  else fail(`${network} official Quoter address is missing`);

  if (publication.status === "pending-official-hook-pool-publication") {
    if (pools.length === 0) pass(`${network} Quoter pool list is empty until hook pools are published`);
    else fail(`${network} pending hook-pool publication must not carry Quoter pool records`);

    warn(`${network} Quoter verification remains pending official hook-pool publication`);
    return;
  }

  if (publication.status === "draft") warn(`${network} Quoter publication is draft-only and not a readiness claim`);
  if (publication.status === "ready") pass(`${network} Quoter publication is marked ready`);

  if (pools.length === Number(publicationInput.expectedPoolTemplateCount)) {
    pass(`${network} Quoter pool count matches expected template count`);
  } else {
    fail(`${network} Quoter pool count ${pools.length} does not match ${publicationInput.expectedPoolTemplateCount}`);
  }

  for (const pool of pools) checkPool(target, pool, publication.status === "ready");
}

function main(): void {
  const relativeInputPath = inputPath();
  console.log("Official Uniswap v4 multichain Quoter readiness check");
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

  checkQuoterConfig(multichain);
  for (const network of requiredNetworks) checkTarget(multichain, publicationInput, network);

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
