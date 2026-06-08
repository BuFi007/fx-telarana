// SPDX-License-Identifier: AGPL-3.0-only
//
// Read-only validator for official Uniswap v4 multichain indexing readiness.
// This checks official contract availability separately from protocol pool
// publication. It never broadcasts transactions.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createPublicClient, http } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const MULTICHAIN_POOL_PUBLICATION = "deployments/uniswap-v4-official-multichain-pools.template.json";
const ARC_READINESS_MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const DEPLOYMENTS_URL = "https://developers.uniswap.org/docs/protocols/v4/deployments";
const DEPLOYMENTS_MARKDOWN_URL = "https://developers.uniswap.org/docs/protocols/v4/deployments.md";
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

const requiredIndexingEvidence = [
  "officialPoolManager",
  "officialHookRedeployOrRemine",
  "officialPoolKeyAndPoolId",
  "poolManagerInitializeTx",
  "firstLiquidityTx",
  "stateViewSlot0AndLiquidity",
  "subgraphPoolEntity",
  "v4QuoterExactInputDiagnostic",
  "routerQuoterCaveats",
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

function readJson(relativePath: string): AnyRecord {
  const absolutePath = join(ROOT, relativePath);
  if (!existsSync(absolutePath)) {
    fail(`missing ${relativePath}`);
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

function targetByNetwork(manifest: AnyRecord, network: string): AnyRecord | undefined {
  const target = (manifest.targets ?? []).find((entry: AnyRecord) => entry.network === network);
  if (!target) fail(`multichain manifest missing ${network}`);
  return target;
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

function checkNullOfficialContracts(target: AnyRecord): void {
  const contracts = target.contracts ?? {};
  for (const name of requiredContracts) {
    if (contracts[name] == null) pass(`${target.network} ${name} is intentionally unset`);
    else fail(`${target.network} ${name} must stay unset while official v4 addresses are pending`);
  }
}

function checkPublishedContracts(target: AnyRecord, selfPoolManagers: string[]): void {
  const contracts = target.contracts ?? {};
  for (const name of requiredContracts) {
    if (isAddress(contracts[name])) pass(`${target.network} ${name} address is valid`);
    else fail(`${target.network} ${name} address is missing or invalid`);
  }

  if (sameAddress(contracts.Permit2, PERMIT2)) {
    pass(`${target.network} Permit2 is canonical`);
  } else {
    fail(`${target.network} Permit2 must match canonical Permit2`);
  }

  if (isAddress(contracts.PoolManager)) {
    for (const selfPoolManager of selfPoolManagers) {
      if (sameAddress(contracts.PoolManager, selfPoolManager)) {
        fail(`${target.network} official PoolManager reuses self-deployed PoolManager ${selfPoolManager}`);
      } else {
        pass(`${target.network} official PoolManager does not reuse ${selfPoolManager}`);
      }
    }
  }

  if (target.indexingReadiness === "official-contracts-known-hook-pool-publication-pending") {
    pass(`${target.network} does not overclaim hook indexing from contract addresses alone`);
  } else {
    fail(`${target.network} must keep hook indexing pending until pool publication evidence exists`);
  }

  if (target.hookRedeployStatus === "pending-official-hook-redeploy") {
    pass(`${target.network} hook redeploy remains explicitly pending`);
  } else {
    fail(`${target.network} hook redeploy status is missing`);
  }

  if (target.poolPublicationStatus === "pending-poolmanager-initialize-and-first-liquidity") {
    warn(`${target.network} official contracts are known, but fx-Telarana hook pools still need official initialize and first-liquidity evidence`);
  } else {
    fail(`${target.network} pool publication status must require initialize and first liquidity`);
  }
}

function checkRequiredEvidence(manifest: AnyRecord, target: AnyRecord): void {
  const required = new Set<string>(manifest.requiredIndexingEvidence ?? []);
  for (const name of requiredIndexingEvidence) {
    if (required.has(name)) pass(`required indexing evidence includes ${name}`);
    else fail(`required indexing evidence is missing ${name}`);
  }

  const actions = Array.isArray(target.nextRequiredActions) ? target.nextRequiredActions.join("\n") : "";
  for (const snippet of ["PoolManager", "liquidity", "StateView", "subgraph"]) {
    if (actions.includes(snippet)) pass(`${target.network} next actions cover ${snippet}`);
    else fail(`${target.network} next actions must cover ${snippet}`);
  }
}

function checkSourceFreshnessBlock(manifest: AnyRecord): void {
  const freshness = manifest.sourceFreshness ?? {};
  if (freshness.source === DEPLOYMENTS_MARKDOWN_URL) {
    pass("official docs freshness source markdown URL is recorded");
  } else {
    fail("official docs freshness source markdown URL is missing");
  }

  const script = "scripts/check-official-uniswap-v4-deployments-docs.ts";
  if (existsSync(join(ROOT, script))) {
    pass(`official docs freshness verifier exists at ${script}`);
  } else {
    fail(`official docs freshness verifier is missing at ${script}`);
  }

  const selfTestScript = "scripts/self-test-official-uniswap-v4-deployments-docs.ts";
  if (existsSync(join(ROOT, selfTestScript))) {
    pass(`official docs freshness self-test exists at ${selfTestScript}`);
  } else {
    fail(`official docs freshness self-test is missing at ${selfTestScript}`);
  }

  if (
    typeof freshness.command === "string"
    && freshness.command.includes("uniswap:official-multichain:docs:check")
  ) {
    pass("official docs freshness command is recorded");
  } else {
    fail("official docs freshness command is missing");
  }

  if (
    typeof freshness.selfTestCommand === "string"
    && freshness.selfTestCommand.includes("uniswap:official-multichain:docs:self-test")
  ) {
    pass("official docs freshness self-test command is recorded");
  } else {
    fail("official docs freshness self-test command is missing");
  }

  if (
    typeof freshness.currentResult === "string"
    && freshness.currentResult.includes("WARN=2")
    && freshness.currentResult.includes("FAIL=0")
  ) {
    pass("official docs freshness result is recorded");
  } else {
    fail("official docs freshness result is missing");
  }

  if (
    typeof freshness.currentSelfTestResult === "string"
    && freshness.currentSelfTestResult.includes("FAIL=0")
  ) {
    pass("official docs freshness self-test result is recorded");
  } else {
    fail("official docs freshness self-test result is missing");
  }

  const checks = Array.isArray(freshness.requiredChecks) ? freshness.requiredChecks.join("\n") : "";
  for (const snippet of [
    "official Uniswap v4 deployments Markdown",
    "Avalanche C-Chain official contract addresses",
    "Arbitrum One official contract addresses",
    "Arc mainnet must remain pending",
    "Avalanche Fuji must remain pending",
    "official contract address drift",
    "Self-test",
  ]) {
    if (checks.includes(snippet)) pass(`official docs freshness checks cover ${snippet}`);
    else fail(`official docs freshness checks must cover ${snippet}`);
  }
}

function checkDeploymentInputGenerationBlock(manifest: AnyRecord): void {
  const generation = manifest.deploymentInputGeneration ?? {};
  const script = "scripts/generate-official-multichain-deployment-inputs.ts";
  if (existsSync(join(ROOT, script))) {
    pass(`multichain deployment input generator exists at ${script}`);
  } else {
    fail(`multichain deployment input generator is missing at ${script}`);
  }

  const selfTestScript = "scripts/self-test-official-multichain-deployment-input-generator.ts";
  if (existsSync(join(ROOT, selfTestScript))) {
    pass(`multichain deployment input generator self-test exists at ${selfTestScript}`);
  } else {
    fail(`multichain deployment input generator self-test is missing at ${selfTestScript}`);
  }

  if (
    typeof generation.command === "string"
    && generation.command.includes("uniswap:official-multichain:input:generate")
  ) {
    pass("multichain deployment input generator command is recorded");
  } else {
    fail("multichain deployment input generator command is missing");
  }

  if (
    typeof generation.currentResult === "string"
    && generation.currentResult.includes("WARN=2")
    && generation.currentResult.includes("FAIL=0")
  ) {
    pass("multichain deployment input generator result is recorded");
  } else {
    fail("multichain deployment input generator result is missing");
  }

  if (
    typeof generation.selfTestCommand === "string"
    && generation.selfTestCommand.includes("uniswap:official-multichain:input:generate:self-test")
  ) {
    pass("multichain deployment input generator self-test command is recorded");
  } else {
    fail("multichain deployment input generator self-test command is missing");
  }

  if (
    typeof generation.currentSelfTestResult === "string"
    && generation.currentSelfTestResult.includes("FAIL=0")
  ) {
    pass("multichain deployment input generator self-test result is recorded");
  } else {
    fail("multichain deployment input generator self-test result is missing");
  }

  const checks = Array.isArray(generation.requiredChecks) ? generation.requiredChecks.join("\n") : "";
  for (const snippet of [
    "official Uniswap v4 deployments Markdown",
    "Arc mainnet and Avalanche Fuji pending",
    "Avalanche C-Chain and Arbitrum One",
    "self-deployed Arc testnet and Fuji rehearsal PoolManager",
    "future all-target population",
  ]) {
    if (checks.includes(snippet)) pass(`multichain deployment input generator checks cover ${snippet}`);
    else fail(`multichain deployment input generator checks must cover ${snippet}`);
  }
}

function checkPoolPublicationBlock(manifest: AnyRecord): void {
  const publication = manifest.poolPublication ?? {};
  if (publication.manifest === MULTICHAIN_POOL_PUBLICATION) {
    pass("multichain pool publication manifest path is recorded");
  } else {
    fail("multichain pool publication manifest path is missing");
  }

  if (existsSync(join(ROOT, MULTICHAIN_POOL_PUBLICATION))) {
    pass(`multichain pool publication template exists at ${MULTICHAIN_POOL_PUBLICATION}`);
  } else {
    fail(`multichain pool publication template is missing at ${MULTICHAIN_POOL_PUBLICATION}`);
  }

  const script = "scripts/check-official-multichain-pool-publication.ts";
  if (existsSync(join(ROOT, script))) {
    pass(`multichain pool publication verifier exists at ${script}`);
  } else {
    fail(`multichain pool publication verifier is missing at ${script}`);
  }

  const selfTestScript = "scripts/self-test-official-multichain-pool-publication.ts";
  if (existsSync(join(ROOT, selfTestScript))) {
    pass(`multichain pool publication self-test exists at ${selfTestScript}`);
  } else {
    fail(`multichain pool publication self-test is missing at ${selfTestScript}`);
  }

  if (
    typeof publication.command === "string"
    && publication.command.includes("uniswap:official-multichain:pools:check")
  ) {
    pass("multichain pool publication command is recorded");
  } else {
    fail("multichain pool publication command is missing");
  }

  if (
    typeof publication.selfTestCommand === "string"
    && publication.selfTestCommand.includes("uniswap:official-multichain:pools:self-test")
  ) {
    pass("multichain pool publication self-test command is recorded");
  } else {
    fail("multichain pool publication self-test command is missing");
  }

  if (
    typeof publication.currentResult === "string"
    && publication.currentResult.includes("WARN=4")
    && publication.currentResult.includes("FAIL=0")
  ) {
    pass("multichain pool publication result is recorded");
  } else {
    fail("multichain pool publication result is missing");
  }

  if (
    typeof publication.currentSelfTestResult === "string"
    && publication.currentSelfTestResult.includes("FAIL=0")
  ) {
    pass("multichain pool publication self-test result is recorded");
  } else {
    fail("multichain pool publication self-test result is missing");
  }

  const checks = Array.isArray(publication.requiredChecks) ? publication.requiredChecks.join("\n") : "";
  for (const snippet of [
    "target chain status",
    "official PoolManager",
    "Self-deployed Arc testnet",
    "low-14 permission bits",
    "poolIds must derive",
    "live target-chain PoolManager receipt verification",
    "Self-test",
  ]) {
    if (checks.includes(snippet)) pass(`multichain pool publication checks cover ${snippet}`);
    else fail(`multichain pool publication checks must cover ${snippet}`);
  }
}

async function checkOptionalBytecode(target: AnyRecord): Promise<void> {
  const rpcEnv = target.rpcEnv;
  if (typeof rpcEnv !== "string" || rpcEnv.length === 0) {
    fail(`${target.network} rpcEnv is missing`);
    return;
  }

  const rpcUrl = process.env[rpcEnv];
  if (!rpcUrl) {
    pass(`${target.network} optional bytecode check is documented by ${rpcEnv}`);
    return;
  }

  const client = createPublicClient({ transport: http(rpcUrl) });
  for (const name of requiredContracts) {
    const address = target.contracts?.[name];
    if (!isAddress(address)) continue;

    const code = await client.getBytecode({ address: address as `0x${string}` });
    if (code && code !== "0x") pass(`${target.network} ${name} has deployed bytecode`);
    else fail(`${target.network} ${name} has no deployed bytecode at ${address}`);
  }
}

async function checkTarget(
  manifest: AnyRecord,
  target: AnyRecord,
  selfPoolManagers: string[],
): Promise<void> {
  if (target.source === DEPLOYMENTS_URL) pass(`${target.network} source is official Uniswap deployments page`);
  else fail(`${target.network} source must be official Uniswap deployments page`);

  if (requiredNetworks.includes(target.network)) pass(`${target.network} is an expected target`);
  else fail(`${target.network} is not an expected target`);

  checkRequiredEvidence(manifest, target);

  if (target.network === "arc-mainnet") {
    if (target.chainId == null) pass("arc-mainnet chainId is intentionally pending official confirmation");
    else fail("arc-mainnet chainId must stay unset while official addresses are pending");

    if (target.status === "pending-official-uniswap-v4-addresses") pass("arc-mainnet status is pending official Uniswap v4 addresses");
    else fail("arc-mainnet status must be pending official addresses");

    if (target.officialDocsListedOn2026_06_08 === false) pass("arc-mainnet is not claimed as listed in official deployments on 2026-06-08");
    else fail("arc-mainnet must not be claimed listed without official evidence");

    if (target.indexingReadiness === "not-indexable-yet-official-uniswap-v4-addresses-pending") {
      warn("arc-mainnet indexing remains pending official Uniswap v4 addresses");
    } else {
      fail("arc-mainnet indexing readiness must stay pending");
    }

    checkNullOfficialContracts(target);
    await checkOptionalBytecode(target);
    return;
  }

  if (target.network === "avalanche-fuji") {
    if (target.chainId === 43113) pass("avalanche-fuji chainId is 43113");
    else fail("avalanche-fuji chainId must be 43113");

    if (target.status === "pending-official-uniswap-v4-addresses") pass("avalanche-fuji status is pending official Uniswap v4 addresses");
    else fail("avalanche-fuji status must be pending official addresses");

    if (target.officialDocsListedOn2026_06_08 === false) pass("avalanche-fuji is not claimed as listed in official deployments on 2026-06-08");
    else fail("avalanche-fuji must not be claimed listed without official evidence");

    if (isAddress(target.rehearsal?.poolManager)) pass("avalanche-fuji rehearsal PoolManager is recorded");
    else fail("avalanche-fuji rehearsal PoolManager is missing");

    if (target.rehearsal?.indexingClaim === "not-official-uniswap-indexed") {
      pass("avalanche-fuji rehearsal PoolManager is not claimed as officially indexed");
    } else {
      fail("avalanche-fuji rehearsal PoolManager must not be claimed official");
    }

    if (target.indexingReadiness === "rehearsal-only-not-official-indexing") {
      warn("avalanche-fuji remains rehearsal-only until official Uniswap v4 addresses are published");
    } else {
      fail("avalanche-fuji indexing readiness must stay rehearsal-only");
    }

    checkNullOfficialContracts(target);
    await checkOptionalBytecode(target);
    return;
  }

  if (target.network === "avalanche") {
    if (target.chainId === 43114) pass("avalanche chainId is 43114");
    else fail("avalanche chainId must be 43114");
  } else if (target.network === "arbitrum-one") {
    if (target.chainId === 42161) pass("arbitrum-one chainId is 42161");
    else fail("arbitrum-one chainId must be 42161");
  }

  if (target.status === "official-uniswap-v4-addresses-published") {
    pass(`${target.network} official Uniswap v4 addresses are recorded as published`);
  } else {
    fail(`${target.network} must have published official v4 address status`);
  }

  if (target.officialDocsListedOn2026_06_08 === true) {
    pass(`${target.network} is recorded as listed in official deployments on 2026-06-08`);
  } else {
    fail(`${target.network} official listing flag is missing`);
  }

  checkPublishedContracts(target, selfPoolManagers);
  await checkOptionalBytecode(target);
}

async function main(): Promise<void> {
  console.log("Official Uniswap v4 multichain readiness check");
  console.log(`manifest ${MULTICHAIN_MANIFEST}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  const manifest = readJson(MULTICHAIN_MANIFEST);
  const arcReadiness = readJson(ARC_READINESS_MANIFEST);

  if (manifest.schemaVersion === 1) pass("multichain manifest schemaVersion is 1");
  else fail("multichain manifest schemaVersion must be 1");

  if (manifest.source === DEPLOYMENTS_URL) pass("multichain manifest source is official Uniswap deployments page");
  else fail("multichain manifest source must be official Uniswap deployments page");

  if (manifest.sourceSnapshotDate === "2026-06-08") pass("multichain manifest records the source snapshot date");
  else fail("multichain manifest source snapshot date is missing");

  if (sameAddress(manifest.canonicalPermit2, PERMIT2)) pass("multichain manifest canonical Permit2 is correct");
  else fail("multichain manifest canonical Permit2 is incorrect");

  const targets = Array.isArray(manifest.targets) ? manifest.targets : [];
  const networks = targets.map((target: AnyRecord) => target.network);
  const uniqueNetworks = new Set(networks);
  if (uniqueNetworks.size === networks.length) pass("multichain target network labels are unique");
  else fail("multichain target network labels must be unique");

  for (const network of requiredNetworks) {
    if (targetByNetwork(manifest, network)) pass(`required target ${network} is present`);
  }

  const selfPoolManagers = collectSelfDeployedPoolManagers(manifest, arcReadiness);
  if (selfPoolManagers.length >= 3) {
    pass("self-deployed/rehearsal PoolManagers are available for reuse rejection");
  } else {
    fail("expected Arc testnet and Fuji rehearsal PoolManagers for reuse rejection");
  }

  const claimPolicy = Array.isArray(manifest.claimPolicy) ? manifest.claimPolicy.join("\n") : "";
  for (const snippet of ["official Uniswap indexing", "self-deployed", "Official contract addresses alone", "Router-active claims"]) {
    if (claimPolicy.includes(snippet)) pass(`claim policy covers ${snippet}`);
    else fail(`claim policy must cover ${snippet}`);
  }

  checkSourceFreshnessBlock(manifest);
  checkDeploymentInputGenerationBlock(manifest);
  checkPoolPublicationBlock(manifest);

  for (const target of targets) {
    await checkTarget(manifest, target, selfPoolManagers);
  }

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

await main();
