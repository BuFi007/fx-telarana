// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only validator for generated or hand-reviewed target-chain official
// Uniswap v4 deployment inputs. It never broadcasts transactions.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const DEFAULT_INPUT = "deployments/uniswap-v4-official-multichain-readiness.json";
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const ARC_READINESS_MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const INPUT_ENV = "OFFICIAL_MULTICHAIN_DEPLOYMENT_INPUT";
const DEPLOYMENTS_URL = "https://developers.uniswap.org/docs/protocols/v4/deployments";
const DEPLOYMENTS_MARKDOWN_URL = `${DEPLOYMENTS_URL}.md`;
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS_RE = /^0x0{40}$/i;
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

const requiredNetworks = [
  "arc-mainnet",
  "avalanche-fuji",
  "avalanche",
  "arbitrum-one",
] as const;

const requiredContracts = [
  "PoolManager",
  "PositionManager",
  "UniversalRouter",
  "Quoter",
  "StateView",
  "Permit2",
] as const;

const optionalContracts = [
  "PositionDescriptor",
  "UniversalRouter211",
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
  return process.env[INPUT_ENV] || DEFAULT_INPUT;
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

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function targetByNetwork(source: AnyRecord, network: string): AnyRecord {
  return (source.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function collectSelfDeployedPoolManagers(multichain: AnyRecord, arcReadiness: AnyRecord): string[] {
  const managers = new Set<string>();
  for (const value of multichain.selfDeployedPoolManagers?.arcTestnet ?? []) {
    if (isAddress(value)) managers.add(value.toLowerCase());
  }

  const rehearsal = multichain.selfDeployedPoolManagers?.avalancheFujiRehearsalPoolManager;
  if (isAddress(rehearsal)) managers.add(rehearsal.toLowerCase());

  for (const manager of Object.values(arcReadiness.arcTestnet?.poolManagers ?? {}) as AnyRecord[]) {
    if (isAddress(manager.address)) managers.add(manager.address.toLowerCase());
  }

  return [...managers];
}

function checkHeader(input: AnyRecord): void {
  if (input.schemaVersion === 1) pass("multichain deployment input schemaVersion is 1");
  else fail("multichain deployment input schemaVersion must be 1");

  if (input.source === DEPLOYMENTS_URL) pass("multichain deployment input source is official Uniswap deployments");
  else fail("multichain deployment input source must be official Uniswap deployments");

  if (input.sourceMarkdown == null || input.sourceMarkdown === DEPLOYMENTS_MARKDOWN_URL) {
    pass("multichain deployment input sourceMarkdown is official or intentionally omitted");
  } else {
    fail("multichain deployment input sourceMarkdown must be official Uniswap deployments Markdown");
  }

  if (typeof input.generatedAt === "string" || typeof input.generatedAt === "undefined") {
    pass("multichain deployment input generatedAt is recorded or using readiness manifest default");
  } else {
    fail("multichain deployment input generatedAt must be an ISO string when present");
  }
}

function checkTargetSet(input: AnyRecord): void {
  const targets = Array.isArray(input.targets) ? input.targets : [];
  const labels = targets.map((target: AnyRecord) => target.network);
  const uniqueLabels = new Set(labels);

  if (targets.length === requiredNetworks.length) {
    pass(`multichain deployment input has ${targets.length} targets`);
  } else {
    fail(`multichain deployment input target count ${targets.length} does not match ${requiredNetworks.length}`);
  }

  if (uniqueLabels.size === labels.length) pass("multichain deployment input target labels are unique");
  else fail("multichain deployment input target labels must be unique");

  for (const network of requiredNetworks) {
    if (labels.includes(network)) pass(`multichain deployment input includes ${network}`);
    else fail(`multichain deployment input is missing ${network}`);
  }
}

function checkPendingTarget(target: AnyRecord, manifestTarget: AnyRecord): void {
  const network = String(target.network ?? "unknown");
  if (target.status === "pending-official-uniswap-v4-addresses") {
    pass(`${network} remains pending official v4 addresses`);
  } else {
    fail(`${network} must stay pending while the multichain manifest is pending`);
  }

  if (target.chainId === manifestTarget.chainId) pass(`${network} chainId matches manifest`);
  else fail(`${network} chainId does not match manifest`);

  const populated = Object.entries(target.contracts ?? {}).filter(([, value]) => value != null);
  if (populated.length === 0) pass(`${network} official contracts stay unset while pending`);
  else fail(`${network} must not populate official contracts while pending`);

  warn(`${network} remains externally pending official Uniswap v4 deployment`);
}

function checkPublishedTarget(
  target: AnyRecord,
  manifestTarget: AnyRecord,
  selfPoolManagers: string[],
): void {
  const network = String(target.network ?? "unknown");
  if (target.status === "official-uniswap-v4-addresses-published") {
    pass(`${network} records official v4 addresses as published`);
  } else {
    fail(`${network} must record official v4 addresses as published`);
  }

  if (target.chainId === manifestTarget.chainId) pass(`${network} chainId matches manifest`);
  else fail(`${network} chainId does not match manifest`);

  if (target.source === DEPLOYMENTS_URL) pass(`${network} target source is official Uniswap deployments`);
  else fail(`${network} target source must be official Uniswap deployments`);

  for (const name of requiredContracts) {
    const value = target.contracts?.[name];
    if (isAddress(value)) pass(`${network} ${name} address is valid`);
    else fail(`${network} ${name} address is missing or invalid`);

    const expected = manifestTarget.contracts?.[name];
    if (sameAddress(value, expected)) pass(`${network} ${name} matches multichain manifest`);
    else fail(`${network} ${name} does not match multichain manifest`);
  }

  for (const name of optionalContracts) {
    const value = target.contracts?.[name];
    const expected = manifestTarget.contracts?.[name];
    if (value == null && expected == null) {
      pass(`${network} optional ${name} is consistently unset`);
    } else if (isAddress(value) && sameAddress(value, expected)) {
      pass(`${network} optional ${name} matches multichain manifest`);
    } else {
      fail(`${network} optional ${name} does not match multichain manifest`);
    }
  }

  if (sameAddress(target.contracts?.Permit2, PERMIT2)) pass(`${network} Permit2 is canonical`);
  else fail(`${network} Permit2 must match canonical Permit2`);

  for (const selfPoolManager of selfPoolManagers) {
    if (sameAddress(target.contracts?.PoolManager, selfPoolManager)) {
      fail(`${network} PoolManager reuses self-deployed/rehearsal PoolManager ${selfPoolManager}`);
    } else {
      pass(`${network} PoolManager does not reuse ${selfPoolManager}`);
    }
  }

  if (target.indexingReadiness === "official-contracts-known-hook-pool-publication-pending") {
    pass(`${network} does not overclaim hook indexing from official contracts alone`);
  } else {
    fail(`${network} must keep hook indexing pending until pool publication evidence exists`);
  }

  if (target.poolPublicationStatus === "pending-poolmanager-initialize-and-first-liquidity") {
    pass(`${network} requires PoolManager initialize and first-liquidity evidence`);
  } else {
    fail(`${network} must require PoolManager initialize and first-liquidity evidence`);
  }
}

function checkTargets(input: AnyRecord, multichain: AnyRecord, selfPoolManagers: string[]): void {
  for (const network of requiredNetworks) {
    const target = targetByNetwork(input, network);
    const manifestTarget = targetByNetwork(multichain, network);

    if (target.network === network) pass(`${network} deployment input target is present`);
    else {
      fail(`${network} deployment input target is missing`);
      continue;
    }

    if (manifestTarget.network === network) pass(`${network} has matching multichain manifest target`);
    else {
      fail(`${network} is missing from multichain manifest`);
      continue;
    }

    if (target.displayName == null || target.displayName === manifestTarget.displayName) {
      pass(`${network} displayName is consistent or omitted`);
    } else {
      fail(`${network} displayName does not match manifest`);
    }

    if (manifestTarget.status === "pending-official-uniswap-v4-addresses") {
      checkPendingTarget(target, manifestTarget);
    } else if (manifestTarget.status === "official-uniswap-v4-addresses-published") {
      checkPublishedTarget(target, manifestTarget, selfPoolManagers);
    } else {
      fail(`${network} has unsupported manifest status ${String(manifestTarget.status)}`);
    }
  }
}

function main(): void {
  const relativePath = inputPath();
  console.log("Official Uniswap v4 multichain deployment input check");
  console.log(`input ${relativePath}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const input = readJson(relativePath);
  const multichain = readJson(MULTICHAIN_MANIFEST);
  const arcReadiness = readJson(ARC_READINESS_MANIFEST);
  const selfPoolManagers = collectSelfDeployedPoolManagers(multichain, arcReadiness);

  if (selfPoolManagers.length >= 3) pass("self-deployed/rehearsal PoolManagers are available for reuse rejection");
  else fail("expected Arc testnet and Fuji rehearsal PoolManagers for reuse rejection");

  checkHeader(input);
  checkTargetSet(input);
  checkTargets(input, multichain, selfPoolManagers);

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
