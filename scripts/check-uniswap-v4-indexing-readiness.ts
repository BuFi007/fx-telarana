// SPDX-License-Identifier: AGPL-3.0-only
//
// Verifies the Arc testnet Uniswap v4 indexing readiness manifest.
// This does not broadcast transactions. It checks that published pool IDs,
// hook permission bits, and official-mainnet caveats are internally consistent.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { encodeAbiParameters, keccak256 } from "viem";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const EVIDENCE_SNAPSHOT = "deployments/uniswap-v4-indexing-evidence-5042002.json";
const MULTICHAIN_MANIFEST = "deployments/uniswap-v4-official-multichain-readiness.json";
const MULTICHAIN_POOL_PUBLICATION = "deployments/uniswap-v4-official-multichain-pools.template.json";
const DEPLOYMENTS_MARKDOWN_URL = "https://developers.uniswap.org/docs/protocols/v4/deployments.md";
const OFFICIAL_ARC_INPUT_TEMPLATE = "deployments/uniswap-v4-official-arc-input.template.json";
const HEDGE_DEPLOYMENT = "deployments/fx-hedge-hook-5042002.json";
const HEDGE_STABLE_DEPLOYMENT = "deployments/fx-hedge-stable-pools-5042002.json";
const FXSWAP_DEPLOYMENT = "deployments/fxswap-vault-backed-v2-5042002.json";
const ARC_DEPLOYMENT = "deployments/arc-testnet.json";
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;
const ZERO_BYTES32 = /^0x0{64}$/i;
const LOW_14_MASK = 0x3fffn;

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

function readJson<T extends AnyRecord>(relativePath: string): T {
  const path = join(ROOT, relativePath);
  if (!existsSync(path)) {
    fail(`missing ${relativePath}`);
    return {} as T;
  }

  try {
    return JSON.parse(readFileSync(path, "utf-8")) as T;
  } catch (error) {
    fail(`invalid JSON in ${relativePath}: ${String(error)}`);
    return {} as T;
  }
}

function isAddress(value: unknown): value is string {
  return typeof value === "string" && ADDRESS_RE.test(value);
}

function isBytes32(value: unknown): value is string {
  return typeof value === "string" && BYTES32_RE.test(value);
}

function isNonZeroBytes32(value: unknown): value is string {
  return isBytes32(value) && !ZERO_BYTES32.test(value);
}

function sameAddress(a: unknown, b: unknown): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function low14Bits(address: string): number {
  return Number(BigInt(address) & LOW_14_MASK);
}

function poolIdFromKey(currency0: string, currency1: string, fee: number, tickSpacing: number, hooks: string): string {
  return keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [currency0 as `0x${string}`, currency1 as `0x${string}`, fee, tickSpacing, hooks as `0x${string}`],
  ));
}

function checkAddress(label: string, value: unknown): value is string {
  if (isAddress(value)) {
    pass(`${label} is a valid address`);
    return true;
  }
  fail(`${label} is not a valid address`);
  return false;
}

function checkBytes32(label: string, value: unknown): value is string {
  if (isNonZeroBytes32(value)) {
    pass(`${label} is a non-zero bytes32`);
    return true;
  }
  fail(`${label} is missing or zero`);
  return false;
}

function checkUintString(label: string, value: unknown): void {
  if (typeof value === "string" && /^[0-9]+$/.test(value) && BigInt(value) > 0n) {
    pass(`${label} is a positive integer string`);
  } else {
    fail(`${label} is missing or not a positive integer string`);
  }
}

function checkHookFlags(family: AnyRecord): void {
  if (family.deployed === false) {
    if (family.hookAddress == null) {
      pass(`${family.name} is marked undeployed and has no hook address`);
    } else {
      warn(`${family.name} is marked undeployed but has hookAddress=${family.hookAddress}`);
    }
    return;
  }

  if (
    family.hookAddress == null
    && Array.isArray(family.pools)
    && family.pools.some((pool: AnyRecord) => pool.hookAddress != null)
  ) {
    pass(`${family.name} uses per-pool hook addresses; pool-level hook bits will be checked`);
    return;
  }

  if (!checkAddress(`${family.name}.hookAddress`, family.hookAddress)) return;
  const expected = Number(family.permissionFlagsLow14Bits);
  const actual = low14Bits(family.hookAddress);
  if (actual === expected) {
    pass(`${family.name} low-14 hook bits match ${expected}`);
  } else {
    fail(`${family.name} low-14 hook bits ${actual} do not match expected ${expected}`);
  }
}

function checkOfficialMainnetBlock(manifest: AnyRecord): void {
  const official = manifest.officialArcMainnet ?? {};
  if (official.status === "pending-official-uniswap-v4-addresses") {
    pass("official Arc mainnet status is correctly marked pending official Uniswap v4 addresses");
  } else {
    fail("official Arc mainnet status must remain pending until Uniswap publishes Arc v4 addresses");
  }

  if (official.arcListedInUniswapDeploymentsOn2026_06_08 === false) {
    pass("manifest does not claim Arc was listed in Uniswap v4 deployments on 2026-06-08");
  } else {
    fail("manifest must not claim official Arc v4 deployments are listed without evidence");
  }

  const required = new Set<string>(official.requiredContracts ?? []);
  for (const name of ["PoolManager", "PositionManager", "UniversalRouter", "Quoter", "StateView", "Permit2"]) {
    if (required.has(name)) pass(`official migration requires ${name}`);
    else fail(`official migration checklist is missing ${name}`);
  }

  if (typeof official.readinessCommand === "string" && official.readinessCommand.includes("uniswap:official-arc:check")) {
    pass("official Arc readiness command is recorded");
  } else {
    fail("official Arc readiness command is missing");
  }

  if (typeof official.migrationPlanCommand === "string" && official.migrationPlanCommand.includes("uniswap:official-arc:plan")) {
    pass("official Arc migration plan command is recorded");
  } else {
    fail("official Arc migration plan command is missing");
  }

  const hookRedeployPlan = official.hookRedeployPlan ?? {};
  if (hookRedeployPlan.status === "pending-official-uniswap-v4-addresses") {
    pass("official Arc hook redeploy plan is correctly pending official addresses");
  } else {
    fail("official Arc hook redeploy plan status must stay pending until official addresses are published");
  }

  if (
    typeof hookRedeployPlan.command === "string"
    && hookRedeployPlan.command.includes("uniswap:official-arc:hooks:plan")
  ) {
    pass("official Arc hook redeploy plan command is recorded");
  } else {
    fail("official Arc hook redeploy plan command is missing");
  }

  if (
    typeof hookRedeployPlan.currentResult === "string"
    && hookRedeployPlan.currentResult.includes("WARN=1")
    && hookRedeployPlan.currentResult.includes("FAIL=0")
  ) {
    pass("official Arc hook redeploy plan result is recorded");
  } else {
    fail("official Arc hook redeploy plan result is missing");
  }

  const hookRedeployChecks = Array.isArray(hookRedeployPlan.requiredChecks)
    ? hookRedeployPlan.requiredChecks.join("\n")
    : "";
  for (const snippet of [
    "official Arc deployment input",
    "self-deployed Arc testnet PoolManager",
    "env-provided POOL_MANAGER",
    "FX_VAULT",
    "vault-backed",
    "runCreate2",
    "low-14 bits",
  ]) {
    if (hookRedeployChecks.includes(snippet)) pass(`official hook redeploy plan covers ${snippet}`);
    else fail(`official hook redeploy plan must cover ${snippet}`);
  }

  if (official.deploymentInputTemplate === OFFICIAL_ARC_INPUT_TEMPLATE) {
    pass("official Arc deployment input template is recorded");
  } else {
    fail("official Arc deployment input template is missing");
  }

  if (
    typeof official.deploymentInputGenerateCommand === "string"
    && official.deploymentInputGenerateCommand.includes("uniswap:official-arc:input:generate")
  ) {
    pass("official Arc deployment input generator command is recorded");
  } else {
    fail("official Arc deployment input generator command is missing");
  }

  if (
    typeof official.currentDeploymentInputGenerateResult === "string"
    && official.currentDeploymentInputGenerateResult.includes("WARN=1")
    && official.currentDeploymentInputGenerateResult.includes("FAIL=0")
  ) {
    pass("official Arc deployment input generator result is recorded");
  } else {
    fail("official Arc deployment input generator result is missing");
  }

  if (
    typeof official.deploymentInputGenerateSelfTestCommand === "string"
    && official.deploymentInputGenerateSelfTestCommand.includes("uniswap:official-arc:input:generate:self-test")
  ) {
    pass("official Arc deployment input generator self-test command is recorded");
  } else {
    fail("official Arc deployment input generator self-test command is missing");
  }

  if (
    typeof official.currentDeploymentInputGenerateSelfTestResult === "string"
    && official.currentDeploymentInputGenerateSelfTestResult.includes("FAIL=0")
  ) {
    pass("official Arc deployment input generator self-test result is recorded");
  } else {
    fail("official Arc deployment input generator self-test result is missing");
  }

  if (
    typeof official.deploymentInputCheckCommand === "string"
    && official.deploymentInputCheckCommand.includes("uniswap:official-arc:input:check")
  ) {
    pass("official Arc deployment input check command is recorded");
  } else {
    fail("official Arc deployment input check command is missing");
  }

  if (
    typeof official.currentDeploymentInputResult === "string"
    && official.currentDeploymentInputResult.includes("WARN=1")
    && official.currentDeploymentInputResult.includes("FAIL=0")
  ) {
    pass("official Arc deployment input check result is recorded");
  } else {
    fail("official Arc deployment input check result is missing");
  }

  if (
    typeof official.deploymentInputSelfTestCommand === "string"
    && official.deploymentInputSelfTestCommand.includes("uniswap:official-arc:input:self-test")
  ) {
    pass("official Arc deployment input self-test command is recorded");
  } else {
    fail("official Arc deployment input self-test command is missing");
  }

  if (
    typeof official.currentDeploymentInputSelfTestResult === "string"
    && official.currentDeploymentInputSelfTestResult.includes("FAIL=0")
  ) {
    pass("official Arc deployment input self-test result is recorded");
  } else {
    fail("official Arc deployment input self-test result is missing");
  }

  const deploymentInputChecks = Array.isArray(official.deploymentInputRequiredChecks)
    ? official.deploymentInputRequiredChecks.join("\n")
    : "";
  for (const snippet of [
    "all official contract addresses unset",
    "Generator",
    "validator-compatible input",
    "official Uniswap v4 deployments page",
    "self-deployed Arc testnet PoolManager",
    "canonical Permit2",
    "deployed bytecode",
  ]) {
    if (deploymentInputChecks.includes(snippet)) pass(`official deployment input check covers ${snippet}`);
    else fail(`official deployment input checks must cover ${snippet}`);
  }

  const poolPublication = official.poolPublication ?? {};
  if (poolPublication.status === "pending-official-uniswap-v4-addresses") {
    pass("official Arc pool publication is correctly pending official pool records");
  } else {
    fail("official Arc pool publication status must stay pending until official pools are published");
  }

  if (poolPublication.inputTemplate === "deployments/uniswap-v4-official-arc-pools.template.json") {
    pass("official Arc pool publication template is recorded");
  } else {
    fail("official Arc pool publication template is missing");
  }

  if (typeof poolPublication.command === "string" && poolPublication.command.includes("uniswap:official-arc:pools:check")) {
    pass("official Arc pool publication command is recorded");
  } else {
    fail("official Arc pool publication command is missing");
  }

  if (
    typeof poolPublication.currentResult === "string"
    && poolPublication.currentResult.includes("WARN=1")
    && poolPublication.currentResult.includes("FAIL=0")
  ) {
    pass("official Arc pool publication result is recorded");
  } else {
    fail("official Arc pool publication result is missing");
  }

  if (
    typeof poolPublication.planCommand === "string"
    && poolPublication.planCommand.includes("uniswap:official-arc:pools:plan")
  ) {
    pass("official Arc pool publication fill-plan command is recorded");
  } else {
    fail("official Arc pool publication fill-plan command is missing");
  }

  if (
    typeof poolPublication.currentPlanResult === "string"
    && poolPublication.currentPlanResult.includes("WARN=1")
    && poolPublication.currentPlanResult.includes("FAIL=0")
  ) {
    pass("official Arc pool publication fill-plan result is recorded");
  } else {
    fail("official Arc pool publication fill-plan result is missing");
  }

  if (
    typeof poolPublication.selfTestCommand === "string"
    && poolPublication.selfTestCommand.includes("uniswap:official-arc:pools:self-test")
  ) {
    pass("official Arc pool publication self-test command is recorded");
  } else {
    fail("official Arc pool publication self-test command is missing");
  }

  if (
    typeof poolPublication.currentSelfTestResult === "string"
    && poolPublication.currentSelfTestResult.includes("FAIL=0")
  ) {
    pass("official Arc pool publication self-test result is recorded");
  } else {
    fail("official Arc pool publication self-test result is missing");
  }

  const publicationFields = new Set<string>(poolPublication.requiredPoolFields ?? []);
  for (const field of [
    "family",
    "symbol",
    "poolManager",
    "hookAddress",
    "poolId",
    "poolKey",
    "initializeTx",
    "firstLiquidityTx",
    "routerQuoterStatus",
    "stateViewVerification",
    "subgraphVerification",
  ]) {
    if (publicationFields.has(field)) pass(`official pool publication requires ${field}`);
    else fail(`official pool publication is missing ${field}`);
  }

  const publicationChecks = Array.isArray(poolPublication.requiredChecks)
    ? poolPublication.requiredChecks.join("\n")
    : "";
  for (const snippet of [
    "pool count matches",
    "sourceDeploymentInput.contracts.PoolManager",
    "self-deployed Arc testnet PoolManager",
    "low-14 permission bits",
    "poolId is unique",
    "fill plan",
    "firstLiquidityTx",
    "draft files",
    "ready files require OFFICIAL_ARC_RPC_URL",
    "self-test",
    "StateView sqrtPriceX96",
    "subgraph id",
    "PoolManager Initialize",
    "PoolManager ModifyLiquidity",
  ]) {
    if (publicationChecks.includes(snippet)) pass(`official pool publication check covers ${snippet}`);
    else fail(`official pool publication checks must cover ${snippet}`);
  }

  if (Array.isArray(poolPublication.officialPools) && poolPublication.officialPools.length === 0) {
    pass("official pool publication list is intentionally empty while official redeploy is pending");
  } else {
    fail("official pool publication list must stay empty until official Arc pools are published");
  }

  if (
    typeof official.currentMigrationPlanResult === "string"
    && official.currentMigrationPlanResult.includes("WARN=1")
    && official.currentMigrationPlanResult.includes("FAIL=0")
  ) {
    pass("official Arc migration plan result is recorded");
  } else {
    fail("official Arc migration plan result is missing");
  }

  const stateView = official.stateViewVerification ?? {};
  if (stateView.status === "pending-official-arc-stateview-and-official-poolids") {
    pass("official Arc StateView verification is correctly pending official pool IDs");
  } else {
    fail("official Arc StateView verification status must stay pending until official pools are published");
  }

  if (typeof stateView.command === "string" && stateView.command.includes("uniswap:stateview:check")) {
    pass("official Arc StateView verification command is recorded");
  } else {
    fail("official Arc StateView verification command is missing");
  }

  if (stateView.poolPublicationInputEnv === "OFFICIAL_ARC_POOL_PUBLICATION_INPUT") {
    pass("official Arc StateView verification reads the shared pool publication input");
  } else {
    fail("official Arc StateView verification must record OFFICIAL_ARC_POOL_PUBLICATION_INPUT");
  }

  if (
    typeof stateView.currentResult === "string"
    && stateView.currentResult.includes("WARN=1")
    && stateView.currentResult.includes("FAIL=0")
  ) {
    pass("official Arc StateView verification result is recorded");
  } else {
    fail("official Arc StateView verification result is missing");
  }

  const stateViewFields = new Set<string>(stateView.requiredPoolFields ?? []);
  for (const field of ["poolId", "currency0", "currency1", "fee", "tickSpacing", "hooks", "sqrtPriceX96", "liquidity"]) {
    if (stateViewFields.has(field)) pass(`official StateView verification requires pool.${field}`);
    else fail(`official StateView verification is missing pool.${field}`);
  }

  if (Array.isArray(stateView.officialPools) && stateView.officialPools.length === 0) {
    pass("official StateView pool list is intentionally empty while official redeploy is pending");
  } else {
    fail("official StateView pool list must stay empty until official Arc pools are published");
  }

  const subgraph = official.subgraphVerification ?? {};
  if (subgraph.status === "pending-official-arc-subgraph-and-official-poolids") {
    pass("official Arc subgraph verification is correctly pending official pool IDs");
  } else {
    fail("official Arc subgraph verification status must stay pending until official pools are published");
  }

  if (typeof subgraph.command === "string" && subgraph.command.includes("uniswap:subgraph:check")) {
    pass("official Arc subgraph verification command is recorded");
  } else {
    fail("official Arc subgraph verification command is missing");
  }

  if (subgraph.poolPublicationInputEnv === "OFFICIAL_ARC_POOL_PUBLICATION_INPUT") {
    pass("official Arc subgraph verification reads the shared pool publication input");
  } else {
    fail("official Arc subgraph verification must record OFFICIAL_ARC_POOL_PUBLICATION_INPUT");
  }

  if (
    typeof subgraph.currentResult === "string"
    && subgraph.currentResult.includes("WARN=1")
    && subgraph.currentResult.includes("FAIL=0")
  ) {
    pass("official Arc subgraph verification result is recorded");
  } else {
    fail("official Arc subgraph verification result is missing");
  }

  const subgraphFields = new Set<string>(subgraph.requiredPoolFields ?? []);
  for (const field of ["id", "hooks", "liquidity", "sqrtPrice", "tick", "tickSpacing", "feeTier", "token0", "token1"]) {
    if (subgraphFields.has(field)) pass(`official subgraph verification requires pool.${field}`);
    else fail(`official subgraph verification is missing pool.${field}`);
  }

  if (Array.isArray(subgraph.officialPools) && subgraph.officialPools.length === 0) {
    pass("official subgraph pool list is intentionally empty while official redeploy is pending");
  } else {
    fail("official subgraph pool list must stay empty until official Arc pools are published");
  }

  if (
    official.status === "pending-official-uniswap-v4-addresses"
    && official.contracts
    && ["PoolManager", "PositionManager", "UniversalRouter", "Quoter", "StateView", "Permit2"]
      .every((name) => official.contracts[name] == null)
  ) {
    pass("official Arc contract addresses are intentionally unset while status is pending");
  } else if (official.status === "pending-official-uniswap-v4-addresses") {
    fail("official Arc contract addresses must stay unset while status is pending");
  }

  const officialArcScript = "scripts/check-official-arc-v4-readiness.ts";
  if (existsSync(join(ROOT, officialArcScript))) {
    pass(`official Arc readiness verifier exists at ${officialArcScript}`);
  } else {
    fail(`official Arc readiness verifier is missing at ${officialArcScript}`);
  }

  const officialArcPlanScript = "scripts/plan-official-arc-mainnet-migration.ts";
  if (existsSync(join(ROOT, officialArcPlanScript))) {
    pass(`official Arc migration planner exists at ${officialArcPlanScript}`);
  } else {
    fail(`official Arc migration planner is missing at ${officialArcPlanScript}`);
  }

  const officialArcHookRedeployPlanScript = "scripts/plan-official-arc-hook-redeploy.ts";
  if (existsSync(join(ROOT, officialArcHookRedeployPlanScript))) {
    pass(`official Arc hook redeploy planner exists at ${officialArcHookRedeployPlanScript}`);
  } else {
    fail(`official Arc hook redeploy planner is missing at ${officialArcHookRedeployPlanScript}`);
  }

  const officialArcInputTemplate = OFFICIAL_ARC_INPUT_TEMPLATE;
  if (existsSync(join(ROOT, officialArcInputTemplate))) {
    pass(`official Arc deployment input template exists at ${officialArcInputTemplate}`);
  } else {
    fail(`official Arc deployment input template is missing at ${officialArcInputTemplate}`);
  }

  const officialArcInputScript = "scripts/check-official-arc-deployment-input.ts";
  if (existsSync(join(ROOT, officialArcInputScript))) {
    pass(`official Arc deployment input verifier exists at ${officialArcInputScript}`);
  } else {
    fail(`official Arc deployment input verifier is missing at ${officialArcInputScript}`);
  }

  const officialArcInputGenerator = "scripts/generate-official-arc-deployment-input.ts";
  if (existsSync(join(ROOT, officialArcInputGenerator))) {
    pass(`official Arc deployment input generator exists at ${officialArcInputGenerator}`);
  } else {
    fail(`official Arc deployment input generator is missing at ${officialArcInputGenerator}`);
  }

  const officialArcInputGeneratorSelfTest = "scripts/self-test-official-arc-deployment-input-generator.ts";
  if (existsSync(join(ROOT, officialArcInputGeneratorSelfTest))) {
    pass(`official Arc deployment input generator self-test exists at ${officialArcInputGeneratorSelfTest}`);
  } else {
    fail(`official Arc deployment input generator self-test is missing at ${officialArcInputGeneratorSelfTest}`);
  }

  const officialArcInputSelfTest = "scripts/self-test-official-arc-deployment-input.ts";
  if (existsSync(join(ROOT, officialArcInputSelfTest))) {
    pass(`official Arc deployment input self-test exists at ${officialArcInputSelfTest}`);
  } else {
    fail(`official Arc deployment input self-test is missing at ${officialArcInputSelfTest}`);
  }

  const officialArcPoolPublicationTemplate = "deployments/uniswap-v4-official-arc-pools.template.json";
  if (existsSync(join(ROOT, officialArcPoolPublicationTemplate))) {
    pass(`official Arc pool publication template exists at ${officialArcPoolPublicationTemplate}`);
  } else {
    fail(`official Arc pool publication template is missing at ${officialArcPoolPublicationTemplate}`);
  }

  const officialArcPoolPublicationScript = "scripts/check-official-arc-pool-publication.ts";
  if (existsSync(join(ROOT, officialArcPoolPublicationScript))) {
    pass(`official Arc pool publication verifier exists at ${officialArcPoolPublicationScript}`);
  } else {
    fail(`official Arc pool publication verifier is missing at ${officialArcPoolPublicationScript}`);
  }

  const officialArcPoolPublicationPlan = "scripts/plan-official-arc-pool-publication.ts";
  if (existsSync(join(ROOT, officialArcPoolPublicationPlan))) {
    pass(`official Arc pool publication fill planner exists at ${officialArcPoolPublicationPlan}`);
  } else {
    fail(`official Arc pool publication fill planner is missing at ${officialArcPoolPublicationPlan}`);
  }

  const officialArcPoolPublicationSelfTest = "scripts/self-test-official-arc-pool-publication.ts";
  if (existsSync(join(ROOT, officialArcPoolPublicationSelfTest))) {
    pass(`official Arc pool publication self-test exists at ${officialArcPoolPublicationSelfTest}`);
  } else {
    fail(`official Arc pool publication self-test is missing at ${officialArcPoolPublicationSelfTest}`);
  }

  const officialStateViewScript = "scripts/check-official-arc-stateview-readiness.ts";
  if (existsSync(join(ROOT, officialStateViewScript))) {
    pass(`official Arc StateView verifier exists at ${officialStateViewScript}`);
  } else {
    fail(`official Arc StateView verifier is missing at ${officialStateViewScript}`);
  }

  const officialSubgraphScript = "scripts/check-uniswap-v4-subgraph-readiness.ts";
  if (existsSync(join(ROOT, officialSubgraphScript))) {
    pass(`official Arc subgraph verifier exists at ${officialSubgraphScript}`);
  } else {
    fail(`official Arc subgraph verifier is missing at ${officialSubgraphScript}`);
  }

  const evidenceExportScript = "scripts/export-uniswap-v4-indexing-evidence.ts";
  if (existsSync(join(ROOT, evidenceExportScript))) {
    pass(`indexing evidence exporter exists at ${evidenceExportScript}`);
  } else {
    fail(`indexing evidence exporter is missing at ${evidenceExportScript}`);
  }

  const submissionAuditScript = "scripts/audit-uniswap-v4-indexing-submission.ts";
  if (existsSync(join(ROOT, submissionAuditScript))) {
    pass(`indexing submission audit runner exists at ${submissionAuditScript}`);
  } else {
    fail(`indexing submission audit runner is missing at ${submissionAuditScript}`);
  }
}

function checkEvidenceCommands(manifest: AnyRecord): void {
  const commands = manifest.evidenceCommands ?? {};
  const expected = [
    ["offlineReadiness", "uniswap:indexing:check"],
    ["officialArcReadiness", "uniswap:official-arc:check"],
    ["officialArcMigrationPlan", "uniswap:official-arc:plan"],
    ["officialArcHookRedeployPlan", "uniswap:official-arc:hooks:plan"],
    ["officialArcDeploymentInputGenerate", "uniswap:official-arc:input:generate"],
    ["officialArcDeploymentInputGenerateSelfTest", "uniswap:official-arc:input:generate:self-test"],
    ["officialArcDeploymentInputCheck", "uniswap:official-arc:input:check"],
    ["officialArcDeploymentInputSelfTest", "uniswap:official-arc:input:self-test"],
    ["officialArcPoolPublicationCheck", "uniswap:official-arc:pools:check"],
    ["officialArcPoolPublicationPlan", "uniswap:official-arc:pools:plan"],
    ["officialArcPoolPublicationSelfTest", "uniswap:official-arc:pools:self-test"],
    ["officialMultichainReadiness", "uniswap:official-multichain:check"],
    ["officialMultichainDeploymentInputCheck", "uniswap:official-multichain:input:check"],
    ["officialMultichainDeploymentInputGenerate", "uniswap:official-multichain:input:generate"],
    ["officialMultichainDeploymentInputGenerateSelfTest", "uniswap:official-multichain:input:generate:self-test"],
    ["officialMultichainDocsFreshness", "uniswap:official-multichain:docs:check"],
    ["officialMultichainDocsFreshnessSelfTest", "uniswap:official-multichain:docs:self-test"],
    ["officialMultichainPoolPublication", "uniswap:official-multichain:pools:check"],
    ["officialMultichainPoolPublicationSelfTest", "uniswap:official-multichain:pools:self-test"],
    ["officialArcStateViewReadiness", "uniswap:stateview:check"],
    ["subgraphReadiness", "uniswap:subgraph:check"],
    ["submissionEvidenceExport", "uniswap:evidence:export"],
    ["submissionEvidenceSnapshot", "uniswap:evidence:write"],
    ["submissionEvidenceFreshness", "uniswap:evidence:check"],
    ["submissionAudit", "uniswap:submission:audit"],
    ["onchainReceiptVerifier", "uniswap:indexing:onchain"],
    ["hedgeHookLiquidityVerifier", "uniswap:hedge:liquidity"],
    ["hedgeHookLiquiditySeedPlan", "uniswap:hedge:liquidity:plan"],
    ["hedgeHookLiquidityOperatorScript", "hedge:arc:seed-liquidity"],
    ["hedgeHookV4QuoterDiagnostic", "uniswap:hedge:v4quoter"],
    ["fxSwapHookV4QuoterDiagnostic", "uniswap:fxswap:v4quoter"],
    ["pendingHedgePoolsPlan", "hedge:arc:plan-stables"],
    ["pendingHedgePoolsOperatorScript", "hedge:arc:configure-stables"],
  ] as const;

  for (const [key, snippet] of expected) {
    if (typeof commands[key] === "string" && commands[key].includes(snippet)) {
      pass(`evidence command ${key} is present`);
    } else {
      fail(`evidence command ${key} is missing ${snippet}`);
    }
  }
}

function checkOfficialMultichainBlock(
  manifest: AnyRecord,
  multichain: AnyRecord,
  snapshot: AnyRecord,
): void {
  const block = manifest.officialMultichain ?? {};
  if (block.manifest === MULTICHAIN_MANIFEST) {
    pass("official multichain readiness manifest path is recorded");
  } else {
    fail("official multichain readiness manifest path is missing");
  }

  if (existsSync(join(ROOT, MULTICHAIN_MANIFEST))) {
    pass(`official multichain readiness manifest exists at ${MULTICHAIN_MANIFEST}`);
  } else {
    fail(`official multichain readiness manifest is missing at ${MULTICHAIN_MANIFEST}`);
  }

  const script = "scripts/check-official-multichain-v4-readiness.ts";
  if (existsSync(join(ROOT, script))) {
    pass(`official multichain verifier exists at ${script}`);
  } else {
    fail(`official multichain verifier is missing at ${script}`);
  }

  if (typeof block.command === "string" && block.command.includes("uniswap:official-multichain:check")) {
    pass("official multichain readiness command is recorded");
  } else {
    fail("official multichain readiness command is missing");
  }

  if (
    typeof block.currentResult === "string"
    && block.currentResult.includes("WARN=4")
    && block.currentResult.includes("FAIL=0")
  ) {
    pass("official multichain readiness result is recorded");
  } else {
    fail("official multichain readiness result is missing");
  }

  const freshness = block.sourceFreshness ?? {};
  if (freshness.source === DEPLOYMENTS_MARKDOWN_URL) {
    pass("official multichain docs freshness source markdown URL is recorded");
  } else {
    fail("official multichain docs freshness source markdown URL is missing");
  }

  const freshnessScript = "scripts/check-official-uniswap-v4-deployments-docs.ts";
  if (existsSync(join(ROOT, freshnessScript))) {
    pass(`official multichain docs freshness verifier exists at ${freshnessScript}`);
  } else {
    fail(`official multichain docs freshness verifier is missing at ${freshnessScript}`);
  }

  const freshnessSelfTest = "scripts/self-test-official-uniswap-v4-deployments-docs.ts";
  if (existsSync(join(ROOT, freshnessSelfTest))) {
    pass(`official multichain docs freshness self-test exists at ${freshnessSelfTest}`);
  } else {
    fail(`official multichain docs freshness self-test is missing at ${freshnessSelfTest}`);
  }

  if (
    typeof freshness.command === "string"
    && freshness.command.includes("uniswap:official-multichain:docs:check")
  ) {
    pass("official multichain docs freshness command is recorded");
  } else {
    fail("official multichain docs freshness command is missing");
  }

  if (
    typeof freshness.selfTestCommand === "string"
    && freshness.selfTestCommand.includes("uniswap:official-multichain:docs:self-test")
  ) {
    pass("official multichain docs freshness self-test command is recorded");
  } else {
    fail("official multichain docs freshness self-test command is missing");
  }

  if (
    typeof freshness.currentResult === "string"
    && freshness.currentResult.includes("WARN=2")
    && freshness.currentResult.includes("FAIL=0")
  ) {
    pass("official multichain docs freshness result is recorded");
  } else {
    fail("official multichain docs freshness result is missing");
  }

  if (
    typeof freshness.currentSelfTestResult === "string"
    && freshness.currentSelfTestResult.includes("FAIL=0")
  ) {
    pass("official multichain docs freshness self-test result is recorded");
  } else {
    fail("official multichain docs freshness self-test result is missing");
  }

  const freshnessChecks = Array.isArray(freshness.requiredChecks) ? freshness.requiredChecks.join("\n") : "";
  for (const snippet of [
    "official Uniswap v4 deployments Markdown",
    "Avalanche C-Chain official contract addresses",
    "Arbitrum One official contract addresses",
    "Arc mainnet must remain pending",
    "Avalanche Fuji must remain pending",
    "official contract address drift",
    "Self-test",
  ]) {
    if (freshnessChecks.includes(snippet)) pass(`official multichain docs freshness checks cover ${snippet}`);
    else fail(`official multichain docs freshness checks must cover ${snippet}`);
  }

  const generation = block.deploymentInputGeneration ?? {};
  const generationCheckScript = "scripts/check-official-multichain-deployment-inputs.ts";
  if (existsSync(join(ROOT, generationCheckScript))) {
    pass(`official multichain deployment input checker exists at ${generationCheckScript}`);
  } else {
    fail(`official multichain deployment input checker is missing at ${generationCheckScript}`);
  }

  const generationScript = "scripts/generate-official-multichain-deployment-inputs.ts";
  if (existsSync(join(ROOT, generationScript))) {
    pass(`official multichain deployment input generator exists at ${generationScript}`);
  } else {
    fail(`official multichain deployment input generator is missing at ${generationScript}`);
  }

  const generationSelfTest = "scripts/self-test-official-multichain-deployment-input-generator.ts";
  if (existsSync(join(ROOT, generationSelfTest))) {
    pass(`official multichain deployment input generator self-test exists at ${generationSelfTest}`);
  } else {
    fail(`official multichain deployment input generator self-test is missing at ${generationSelfTest}`);
  }

  if (
    typeof generation.checkCommand === "string"
    && generation.checkCommand.includes("uniswap:official-multichain:input:check")
  ) {
    pass("official multichain deployment input checker command is recorded");
  } else {
    fail("official multichain deployment input checker command is missing");
  }

  if (
    typeof generation.currentCheckResult === "string"
    && generation.currentCheckResult.includes("WARN=2")
    && generation.currentCheckResult.includes("FAIL=0")
  ) {
    pass("official multichain deployment input checker result is recorded");
  } else {
    fail("official multichain deployment input checker result is missing");
  }

  if (
    typeof generation.command === "string"
    && generation.command.includes("uniswap:official-multichain:input:generate")
  ) {
    pass("official multichain deployment input generator command is recorded");
  } else {
    fail("official multichain deployment input generator command is missing");
  }

  if (
    typeof generation.currentResult === "string"
    && generation.currentResult.includes("WARN=2")
    && generation.currentResult.includes("FAIL=0")
  ) {
    pass("official multichain deployment input generator result is recorded");
  } else {
    fail("official multichain deployment input generator result is missing");
  }

  if (
    typeof generation.selfTestCommand === "string"
    && generation.selfTestCommand.includes("uniswap:official-multichain:input:generate:self-test")
  ) {
    pass("official multichain deployment input generator self-test command is recorded");
  } else {
    fail("official multichain deployment input generator self-test command is missing");
  }

  if (
    typeof generation.currentSelfTestResult === "string"
    && generation.currentSelfTestResult.includes("FAIL=0")
  ) {
    pass("official multichain deployment input generator self-test result is recorded");
  } else {
    fail("official multichain deployment input generator self-test result is missing");
  }

  const generationChecks = Array.isArray(generation.requiredChecks) ? generation.requiredChecks.join("\n") : "";
  for (const snippet of [
    "Standalone checker",
    "official Uniswap v4 deployments Markdown",
    "Arc mainnet and Avalanche Fuji pending",
    "Avalanche C-Chain and Arbitrum One",
    "self-deployed Arc testnet and Fuji rehearsal PoolManager",
    "standalone checker compatibility",
    "future all-target manifest-update failure",
  ]) {
    if (generationChecks.includes(snippet)) pass(`official multichain deployment input generator checks cover ${snippet}`);
    else fail(`official multichain deployment input generator checks must cover ${snippet}`);
  }

  const publication = block.poolPublication ?? {};
  if (publication.manifest === MULTICHAIN_POOL_PUBLICATION) {
    pass("official multichain pool publication manifest path is recorded");
  } else {
    fail("official multichain pool publication manifest path is missing");
  }

  if (existsSync(join(ROOT, MULTICHAIN_POOL_PUBLICATION))) {
    pass(`official multichain pool publication template exists at ${MULTICHAIN_POOL_PUBLICATION}`);
  } else {
    fail(`official multichain pool publication template is missing at ${MULTICHAIN_POOL_PUBLICATION}`);
  }

  const publicationScript = "scripts/check-official-multichain-pool-publication.ts";
  if (existsSync(join(ROOT, publicationScript))) {
    pass(`official multichain pool publication verifier exists at ${publicationScript}`);
  } else {
    fail(`official multichain pool publication verifier is missing at ${publicationScript}`);
  }

  const publicationSelfTest = "scripts/self-test-official-multichain-pool-publication.ts";
  if (existsSync(join(ROOT, publicationSelfTest))) {
    pass(`official multichain pool publication self-test exists at ${publicationSelfTest}`);
  } else {
    fail(`official multichain pool publication self-test is missing at ${publicationSelfTest}`);
  }

  if (
    typeof publication.command === "string"
    && publication.command.includes("uniswap:official-multichain:pools:check")
  ) {
    pass("official multichain pool publication command is recorded");
  } else {
    fail("official multichain pool publication command is missing");
  }

  if (
    typeof publication.selfTestCommand === "string"
    && publication.selfTestCommand.includes("uniswap:official-multichain:pools:self-test")
  ) {
    pass("official multichain pool publication self-test command is recorded");
  } else {
    fail("official multichain pool publication self-test command is missing");
  }

  if (
    typeof publication.currentResult === "string"
    && publication.currentResult.includes("WARN=4")
    && publication.currentResult.includes("FAIL=0")
  ) {
    pass("official multichain pool publication result is recorded");
  } else {
    fail("official multichain pool publication result is missing");
  }

  if (
    typeof publication.currentSelfTestResult === "string"
    && publication.currentSelfTestResult.includes("FAIL=0")
  ) {
    pass("official multichain pool publication self-test result is recorded");
  } else {
    fail("official multichain pool publication self-test result is missing");
  }

  const publicationChecks = Array.isArray(publication.requiredChecks) ? publication.requiredChecks.join("\n") : "";
  for (const snippet of [
    "target chain status",
    "official PoolManager",
    "Self-deployed Arc testnet",
    "low-14 permission bits",
    "poolIds must derive",
    "live target-chain PoolManager receipt verification",
    "Self-test",
  ]) {
    if (publicationChecks.includes(snippet)) pass(`official multichain pool publication checks cover ${snippet}`);
    else fail(`official multichain pool publication checks must cover ${snippet}`);
  }

  if (multichain.schemaVersion === 1) {
    pass("official multichain manifest schemaVersion is 1");
  } else {
    fail("official multichain manifest schemaVersion must be 1");
  }

  const targetNames = new Set((multichain.targets ?? []).map((target: AnyRecord) => target.network));
  for (const network of ["arc-mainnet", "avalanche-fuji", "avalanche", "arbitrum-one"]) {
    if (targetNames.has(network)) pass(`official multichain manifest includes ${network}`);
    else fail(`official multichain manifest is missing ${network}`);
  }

  const targets = new Map<string, AnyRecord>(
    (multichain.targets ?? []).map((target: AnyRecord) => [target.network, target]),
  );
  const arc = targets.get("arc-mainnet") ?? {};
  const fuji = targets.get("avalanche-fuji") ?? {};
  const avalanche = targets.get("avalanche") ?? {};
  const arbitrum = targets.get("arbitrum-one") ?? {};

  if (arc.status === "pending-official-uniswap-v4-addresses" && arc.officialDocsListedOn2026_06_08 === false) {
    pass("official multichain keeps Arc mainnet pending official addresses");
  } else {
    fail("official multichain must keep Arc mainnet pending official addresses");
  }

  if (
    fuji.status === "pending-official-uniswap-v4-addresses"
    && fuji.officialDocsListedOn2026_06_08 === false
    && fuji.rehearsal?.indexingClaim === "not-official-uniswap-indexed"
  ) {
    pass("official multichain keeps Avalanche Fuji rehearsal-only");
  } else {
    fail("official multichain must keep Avalanche Fuji rehearsal-only until official addresses exist");
  }

  if (
    avalanche.status === "official-uniswap-v4-addresses-published"
    && avalanche.chainId === 43114
    && isAddress(avalanche.contracts?.PoolManager)
    && isAddress(avalanche.contracts?.Quoter)
    && isAddress(avalanche.contracts?.StateView)
  ) {
    pass("official multichain records Avalanche official v4 contracts");
  } else {
    fail("official multichain is missing Avalanche official v4 contracts");
  }

  if (
    arbitrum.status === "official-uniswap-v4-addresses-published"
    && arbitrum.chainId === 42161
    && isAddress(arbitrum.contracts?.PoolManager)
    && isAddress(arbitrum.contracts?.Quoter)
    && isAddress(arbitrum.contracts?.StateView)
  ) {
    pass("official multichain records Arbitrum One official v4 contracts");
  } else {
    fail("official multichain is missing Arbitrum One official v4 contracts");
  }

  for (const target of [avalanche, arbitrum]) {
    if (
      target.indexingReadiness === "official-contracts-known-hook-pool-publication-pending"
      && target.poolPublicationStatus === "pending-poolmanager-initialize-and-first-liquidity"
    ) {
      pass(`${target.network} does not overclaim indexed hook pools`);
    } else {
      fail(`${target.network} must keep hook pool indexing pending`);
    }
  }

  if (snapshot.officialMultichain?.status === block.status) {
    pass("indexing evidence snapshot official multichain status matches manifest");
  } else {
    fail("indexing evidence snapshot official multichain status does not match manifest");
  }

  if (snapshot.officialMultichain?.currentResult === block.currentResult) {
    pass("indexing evidence snapshot official multichain result matches manifest");
  } else {
    fail("indexing evidence snapshot official multichain result does not match manifest");
  }

  if (
    snapshot.officialMultichain?.sourceFreshness?.currentResult
    === block.sourceFreshness?.currentResult
  ) {
    pass("indexing evidence snapshot official multichain docs freshness result matches manifest");
  } else {
    fail("indexing evidence snapshot official multichain docs freshness result does not match manifest");
  }

  if (
    snapshot.officialMultichain?.sourceFreshness?.currentSelfTestResult
    === block.sourceFreshness?.currentSelfTestResult
  ) {
    pass("indexing evidence snapshot official multichain docs freshness self-test result matches manifest");
  } else {
    fail("indexing evidence snapshot official multichain docs freshness self-test result does not match manifest");
  }

  if (
    snapshot.officialMultichain?.deploymentInputGeneration?.currentCheckResult
    === block.deploymentInputGeneration?.currentCheckResult
  ) {
    pass("indexing evidence snapshot official multichain deployment input checker result matches manifest");
  } else {
    fail("indexing evidence snapshot official multichain deployment input checker result does not match manifest");
  }

  if (
    snapshot.officialMultichain?.deploymentInputGeneration?.currentResult
    === block.deploymentInputGeneration?.currentResult
  ) {
    pass("indexing evidence snapshot official multichain deployment input generator result matches manifest");
  } else {
    fail("indexing evidence snapshot official multichain deployment input generator result does not match manifest");
  }

  if (
    snapshot.officialMultichain?.deploymentInputGeneration?.currentSelfTestResult
    === block.deploymentInputGeneration?.currentSelfTestResult
  ) {
    pass("indexing evidence snapshot official multichain deployment input generator self-test result matches manifest");
  } else {
    fail("indexing evidence snapshot official multichain deployment input generator self-test result does not match manifest");
  }

  if (
    snapshot.officialMultichain?.poolPublication?.currentResult
    === block.poolPublication?.currentResult
  ) {
    pass("indexing evidence snapshot official multichain pool publication result matches manifest");
  } else {
    fail("indexing evidence snapshot official multichain pool publication result does not match manifest");
  }

  if (
    snapshot.officialMultichain?.poolPublication?.currentSelfTestResult
    === block.poolPublication?.currentSelfTestResult
  ) {
    pass("indexing evidence snapshot official multichain pool publication self-test result matches manifest");
  } else {
    fail("indexing evidence snapshot official multichain pool publication self-test result does not match manifest");
  }
}

function manifestPoolIds(manifest: AnyRecord): Set<string> {
  const ids = new Set<string>();
  for (const family of manifest.hookFamilies ?? []) {
    if (family.deployed === false) continue;
    for (const pool of family.pools ?? []) {
      if (isBytes32(pool.poolId)) ids.add(pool.poolId.toLowerCase());
    }
  }
  return ids;
}

function checkSubmissionEvidenceSnapshot(manifest: AnyRecord, snapshot: AnyRecord): void {
  const submission = manifest.submissionPackage ?? {};
  if (submission.indexingEvidenceSnapshot === EVIDENCE_SNAPSHOT) {
    pass("submission package records the indexing evidence snapshot path");
  } else {
    fail("submission package is missing the indexing evidence snapshot path");
  }

  if (
    typeof submission.indexingEvidenceSnapshotCommand === "string"
    && submission.indexingEvidenceSnapshotCommand.includes("uniswap:evidence:write")
  ) {
    pass("submission package records the indexing evidence snapshot command");
  } else {
    fail("submission package is missing the indexing evidence snapshot command");
  }

  if (
    typeof submission.indexingEvidenceCheckCommand === "string"
    && submission.indexingEvidenceCheckCommand.includes("uniswap:evidence:check")
  ) {
    pass("submission package records the indexing evidence freshness command");
  } else {
    fail("submission package is missing the indexing evidence freshness command");
  }

  if (
    typeof submission.indexingSubmissionAuditCommand === "string"
    && submission.indexingSubmissionAuditCommand.includes("uniswap:submission:audit")
  ) {
    pass("submission package records the executable submission audit command");
  } else {
    fail("submission package is missing the executable submission audit command");
  }

  if (
    typeof submission.currentSubmissionAuditResult === "string"
    && submission.currentSubmissionAuditResult.includes("CHECKS=")
    && submission.currentSubmissionAuditResult.includes("FAIL=0")
  ) {
    pass("submission package records the current submission audit result");
  } else {
    fail("submission package is missing the current submission audit result");
  }

  const doNotClaim = Array.isArray(submission.doNotClaimYet) ? submission.doNotClaimYet : [];
  if (doNotClaim.some((entry: unknown) => typeof entry === "string" && entry.includes("Router-active/liquid FxHedgeHook"))) {
    pass("submission package records the FxHedgeHook first-liquidity do-not-claim caveat");
  } else {
    fail("submission package is missing the FxHedgeHook first-liquidity do-not-claim caveat");
  }

  if (snapshot.generatedFrom === MANIFEST) {
    pass("indexing evidence snapshot records its manifest source");
  } else {
    fail("indexing evidence snapshot does not point at the readiness manifest");
  }

  if (snapshot.network === manifest.network && snapshot.chainId === manifest.chainId) {
    pass("indexing evidence snapshot network and chainId match manifest");
  } else {
    fail("indexing evidence snapshot network or chainId does not match manifest");
  }

  if (snapshot.officialArcMainnet?.status === manifest.officialArcMainnet?.status) {
    pass("indexing evidence snapshot official Arc status matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc status does not match manifest");
  }

  if (snapshot.officialArcMainnet?.deploymentInputTemplate === manifest.officialArcMainnet?.deploymentInputTemplate) {
    pass("indexing evidence snapshot official Arc deployment input template matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc deployment input template does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.deploymentInputGenerateCommand
    === manifest.officialArcMainnet?.deploymentInputGenerateCommand
  ) {
    pass("indexing evidence snapshot official Arc deployment input generator command matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc deployment input generator command does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.currentDeploymentInputGenerateResult
    === manifest.officialArcMainnet?.currentDeploymentInputGenerateResult
  ) {
    pass("indexing evidence snapshot official Arc deployment input generator result matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc deployment input generator result does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.deploymentInputGenerateSelfTestCommand
    === manifest.officialArcMainnet?.deploymentInputGenerateSelfTestCommand
  ) {
    pass("indexing evidence snapshot official Arc deployment input generator self-test command matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc deployment input generator self-test command does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.currentDeploymentInputGenerateSelfTestResult
    === manifest.officialArcMainnet?.currentDeploymentInputGenerateSelfTestResult
  ) {
    pass("indexing evidence snapshot official Arc deployment input generator self-test result matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc deployment input generator self-test result does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.deploymentInputCheckCommand
    === manifest.officialArcMainnet?.deploymentInputCheckCommand
  ) {
    pass("indexing evidence snapshot official Arc deployment input check command matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc deployment input check command does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.currentDeploymentInputResult
    === manifest.officialArcMainnet?.currentDeploymentInputResult
  ) {
    pass("indexing evidence snapshot official Arc deployment input result matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc deployment input result does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.currentDeploymentInputSelfTestResult
    === manifest.officialArcMainnet?.currentDeploymentInputSelfTestResult
  ) {
    pass("indexing evidence snapshot official Arc deployment input self-test result matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc deployment input self-test result does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.hookRedeployPlan?.currentResult
    === manifest.officialArcMainnet?.hookRedeployPlan?.currentResult
  ) {
    pass("indexing evidence snapshot official Arc hook redeploy plan result matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc hook redeploy plan result does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.poolPublication?.status
    === manifest.officialArcMainnet?.poolPublication?.status
  ) {
    pass("indexing evidence snapshot official Arc pool publication status matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc pool publication status does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.poolPublication?.currentResult
    === manifest.officialArcMainnet?.poolPublication?.currentResult
  ) {
    pass("indexing evidence snapshot official Arc pool publication result matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc pool publication result does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.poolPublication?.planCommand
    === manifest.officialArcMainnet?.poolPublication?.planCommand
  ) {
    pass("indexing evidence snapshot official Arc pool publication fill-plan command matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc pool publication fill-plan command does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.poolPublication?.currentPlanResult
    === manifest.officialArcMainnet?.poolPublication?.currentPlanResult
  ) {
    pass("indexing evidence snapshot official Arc pool publication fill-plan result matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc pool publication fill-plan result does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.poolPublication?.currentSelfTestResult
    === manifest.officialArcMainnet?.poolPublication?.currentSelfTestResult
  ) {
    pass("indexing evidence snapshot official Arc pool publication self-test result matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc pool publication self-test result does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.stateViewVerification?.status
    === manifest.officialArcMainnet?.stateViewVerification?.status
  ) {
    pass("indexing evidence snapshot official Arc StateView status matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc StateView status does not match manifest");
  }

  if (
    snapshot.officialArcMainnet?.stateViewVerification?.currentResult
    === manifest.officialArcMainnet?.stateViewVerification?.currentResult
  ) {
    pass("indexing evidence snapshot official Arc StateView result matches manifest");
  } else {
    fail("indexing evidence snapshot official Arc StateView result does not match manifest");
  }

  const expectedIds = manifestPoolIds(manifest);
  const snapshotPools = Array.isArray(snapshot.pools) ? snapshot.pools : [];
  const snapshotIds = new Set<string>();
  for (const pool of snapshotPools) {
    if (isBytes32(pool.poolId)) snapshotIds.add(pool.poolId.toLowerCase());
  }

  if (snapshotPools.length === expectedIds.size && snapshotIds.size === expectedIds.size) {
    pass(`indexing evidence snapshot has ${expectedIds.size} pool records`);
  } else {
    fail(`indexing evidence snapshot pool count ${snapshotPools.length} does not match manifest count ${expectedIds.size}`);
  }

  const hedgeFamily = findFamily(manifest, "FxHedgeHook");
  const hedgeSnapshotPools = snapshotPools.filter((pool: AnyRecord) => pool.family === "FxHedgeHook");
  if (
    hedgeFamily
    && hedgeSnapshotPools.length > 0
    && hedgeSnapshotPools.every(
      (pool: AnyRecord) => pool.liquidityReadiness?.status === hedgeFamily.liquidityReadiness?.status,
    )
  ) {
    pass("indexing evidence snapshot carries FxHedgeHook liquidity readiness status");
  } else {
    fail("indexing evidence snapshot is missing FxHedgeHook liquidity readiness status");
  }

  if (
    hedgeFamily
    && hedgeSnapshotPools.length > 0
    && hedgeSnapshotPools.every(
      (pool: AnyRecord) =>
        pool.liquidityReadiness?.currentOperatorPlanResult
        === hedgeFamily.liquidityReadiness?.currentOperatorPlanResult,
    )
  ) {
    pass("indexing evidence snapshot carries FxHedgeHook first-liquidity plan result");
  } else {
    fail("indexing evidence snapshot is missing FxHedgeHook first-liquidity plan result");
  }

  for (const id of expectedIds) {
    if (snapshotIds.has(id)) pass(`indexing evidence snapshot includes pool ${id}`);
    else fail(`indexing evidence snapshot is missing pool ${id}`);
  }

  for (const pool of snapshotPools) {
    const key = pool.poolKey ?? {};
    if (
      isAddress(key.currency0)
      && isAddress(key.currency1)
      && Number.isInteger(Number(key.fee))
      && Number.isInteger(Number(key.tickSpacing))
      && isAddress(key.hooks)
    ) {
      pass(`indexing evidence snapshot ${pool.family} ${pool.symbol} has a complete PoolKey`);
    } else {
      fail(`indexing evidence snapshot ${pool.family} ${pool.symbol} has an incomplete PoolKey`);
    }
  }
}

function checkHedgeFamily(manifest: AnyRecord, hedgeDeployment: AnyRecord, stableDeployment: AnyRecord): void {
  const family = findFamily(manifest, "FxHedgeHook");
  if (!family) return;

  if (sameAddress(family.hookAddress, hedgeDeployment.FxHedgeHook)) {
    pass("FxHedgeHook address matches deployments/fx-hedge-hook-5042002.json");
  } else {
    fail("FxHedgeHook address does not match deployments/fx-hedge-hook-5042002.json");
  }

  if (sameAddress(family.poolManager, hedgeDeployment.PoolManager)) {
    pass("FxHedgeHook PoolManager matches hedge deployment manifest");
  } else {
    fail("FxHedgeHook PoolManager does not match hedge deployment manifest");
  }

  if (Number(family.permissionFlagsLow14Bits) === Number(hedgeDeployment.permissionFlagsLow14Bits)) {
    pass("FxHedgeHook permission flags match hedge deployment manifest");
  } else {
    fail("FxHedgeHook permission flags differ from hedge deployment manifest");
  }

  const quoterStatus = family.routerQuoterStatus ?? {};
  if (quoterStatus.genericV4Quoter === "locally-proven-with-official-v4quoter-diagnostic") {
    pass("FxHedgeHook generic V4Quoter status is backed by the local diagnostic");
  } else {
    fail("FxHedgeHook generic V4Quoter status must point at the local diagnostic result");
  }

  if (quoterStatus.exactInput === "supported-in-local-official-v4quoter-diagnostic") {
    pass("FxHedgeHook exact-input quoter support is documented");
  } else {
    fail("FxHedgeHook exact-input quoter support is missing");
  }

  if (quoterStatus.exactOutput === "supported-in-local-official-v4quoter-diagnostic") {
    pass("FxHedgeHook exact-output quoter support is documented");
  } else {
    fail("FxHedgeHook exact-output quoter support is missing");
  }

  const diagnostic = family.quoterDiagnostic ?? {};
  if (typeof diagnostic.test === "string" && existsSync(join(ROOT, diagnostic.test))) {
    pass(`FxHedgeHook V4Quoter diagnostic test exists at ${diagnostic.test}`);
  } else {
    fail("FxHedgeHook V4Quoter diagnostic test path is missing");
  }

  if (typeof diagnostic.command === "string" && diagnostic.command.includes("uniswap:hedge:v4quoter")) {
    pass("FxHedgeHook V4Quoter diagnostic command is recorded");
  } else {
    fail("FxHedgeHook V4Quoter diagnostic command is missing");
  }

  if (typeof diagnostic.result === "string" && diagnostic.result.includes("2 passed") && diagnostic.result.includes("0 failed")) {
    pass("FxHedgeHook V4Quoter diagnostic result is recorded");
  } else {
    fail("FxHedgeHook V4Quoter diagnostic result is missing");
  }

  const liquidityReadiness = family.liquidityReadiness ?? {};
  if (liquidityReadiness.status === "pending-first-liquidity") {
    warn("FxHedgeHook first liquidity is explicitly marked pending for router-active market claims");
  } else if (liquidityReadiness.status === "seeded") {
    pass("FxHedgeHook liquidity is marked seeded");
  } else {
    fail("FxHedgeHook liquidity readiness status is missing");
  }

  if (typeof liquidityReadiness.command === "string" && liquidityReadiness.command.includes("uniswap:hedge:liquidity")) {
    pass("FxHedgeHook liquidity readiness command is recorded");
  } else {
    fail("FxHedgeHook liquidity readiness command is missing");
  }

  if (
    typeof liquidityReadiness.operatorPlanCommand === "string"
    && liquidityReadiness.operatorPlanCommand.includes("uniswap:hedge:liquidity:plan")
  ) {
    pass("FxHedgeHook liquidity operator plan command is recorded");
  } else {
    fail("FxHedgeHook liquidity operator plan command is missing");
  }

  const liquidityPlanScript = liquidityReadiness.operatorPlanScript;
  if (typeof liquidityPlanScript === "string" && existsSync(join(ROOT, liquidityPlanScript))) {
    pass(`FxHedgeHook liquidity operator plan script exists at ${liquidityPlanScript}`);
  } else {
    fail("FxHedgeHook liquidity operator plan script is missing");
  }

  if (
    typeof liquidityReadiness.currentOperatorPlanResult === "string"
    && liquidityReadiness.currentOperatorPlanResult.includes("WARN=1")
    && liquidityReadiness.currentOperatorPlanResult.includes("FAIL=0")
  ) {
    pass("FxHedgeHook liquidity operator plan result is recorded");
  } else {
    fail("FxHedgeHook liquidity operator plan result is missing");
  }

  if (
    liquidityReadiness.status === "pending-first-liquidity"
    && typeof liquidityReadiness.routerActiveClaim === "string"
    && liquidityReadiness.routerActiveClaim.includes("Do not claim")
  ) {
    pass("FxHedgeHook router-active liquidity caveat is recorded");
  } else if (liquidityReadiness.status === "pending-first-liquidity") {
    fail("FxHedgeHook router-active liquidity caveat is missing");
  }

  const liquidityScript = "scripts/check-fx-hedge-liquidity-readiness.ts";
  if (existsSync(join(ROOT, liquidityScript))) {
    pass(`FxHedgeHook liquidity readiness verifier exists at ${liquidityScript}`);
  } else {
    fail(`FxHedgeHook liquidity readiness verifier is missing at ${liquidityScript}`);
  }

  const liquidityOperatorScript = liquidityReadiness.operatorScript;
  if (typeof liquidityOperatorScript === "string" && existsSync(join(ROOT, liquidityOperatorScript))) {
    pass(`FxHedgeHook liquidity operator script exists at ${liquidityOperatorScript}`);
  } else {
    fail("FxHedgeHook liquidity operator script is missing");
  }

  if (
    typeof liquidityReadiness.operatorCommand === "string"
    && liquidityReadiness.operatorCommand.includes("hedge:arc:seed-liquidity")
  ) {
    pass("FxHedgeHook liquidity operator command is recorded");
  } else {
    fail("FxHedgeHook liquidity operator command is missing");
  }

  const setupScript = family.pendingSetupScript?.script;
  if (typeof setupScript === "string" && existsSync(join(ROOT, setupScript))) {
    pass(`FxHedgeHook pending setup script exists at ${setupScript}`);
  } else {
    fail("FxHedgeHook pending setup script is missing");
  }

  const planCommand = family.pendingSetupScript?.planCommand;
  if (typeof planCommand === "string" && planCommand.includes("hedge:arc:plan-stables")) {
    pass("FxHedgeHook no-key stable pool plan command is recorded");
  } else {
    fail("FxHedgeHook no-key stable pool plan command is missing");
  }

  const operatorCommand = family.pendingSetupScript?.operatorCommand;
  if (typeof operatorCommand === "string" && operatorCommand.includes("hedge:arc:configure-stables")) {
    pass("FxHedgeHook operator configure command is recorded");
  } else {
    fail("FxHedgeHook operator configure command is missing");
  }

  const planScript = "scripts/plan-fx-hedge-stable-pools.ts";
  if (existsSync(join(ROOT, planScript))) {
    pass(`FxHedgeHook no-key stable pool verifier exists at ${planScript}`);
  } else {
    fail(`FxHedgeHook no-key stable pool verifier is missing at ${planScript}`);
  }

  const pools = Array.isArray(family.pools) ? family.pools : [];
  const live = pools.filter((pool: AnyRecord) => pool.status === "live");
  const pending = pools.filter((pool: AnyRecord) => pool.status !== "live");

  if (live.length === 6) pass("FxHedgeHook has all six manifest-backed live pools");
  else fail(`FxHedgeHook should have six live pools, found ${live.length}`);

  if (pending.length === 0) {
    pass("FxHedgeHook has no pending stable pools in the readiness manifest");
  }

  if (sameAddress(stableDeployment.FxHedgeHook, family.hookAddress)) {
    pass("FxHedgeHook stable deployment manifest matches hook address");
  } else {
    fail("FxHedgeHook stable deployment manifest hook address mismatch");
  }

  if (sameAddress(stableDeployment.PoolManager, family.poolManager)) {
    pass("FxHedgeHook stable deployment manifest matches PoolManager");
  } else {
    fail("FxHedgeHook stable deployment manifest PoolManager mismatch");
  }

  if (pending.length > 0) {
    warn(`FxHedgeHook has ${pending.length} pending pool(s); do not claim all six hedge pools are live`);
  }

  for (const pool of pools) {
    if (!isAddress(pool.currency0) || !isAddress(pool.currency1) || !isAddress(family.hookAddress)) continue;
    const computedPoolId = poolIdFromKey(
      pool.currency0,
      pool.currency1,
      Number(pool.fee),
      Number(pool.tickSpacing),
      family.hookAddress,
    );
    const expectedField = pool.status === "live" ? pool.poolId : pool.expectedPoolId;
    if (computedPoolId === expectedField) {
      pass(`${pool.symbol} PoolId matches PoolKey derivation`);
    } else {
      fail(`${pool.symbol} PoolId ${expectedField} does not match PoolKey derivation ${computedPoolId}`);
    }
  }

  for (const pool of live) {
    const prefix = pool.manifestPrefix;
    if (!prefix) {
      fail(`live hedge pool ${pool.symbol} is missing manifestPrefix`);
      continue;
    }

    checkBytes32(`${pool.symbol}.poolId`, pool.poolId);
    checkBytes32(`${pool.symbol}.initializeTx`, pool.initializeTx);
    checkBytes32(`${pool.symbol}.configureTx`, pool.configureTx);

    const deployment =
      hedgeDeployment[`${prefix}_poolId`] === pool.poolId ? hedgeDeployment : stableDeployment;

    if (deployment[`${prefix}_initialized`] === true) {
      pass(`${pool.symbol} initialized=true in deployment manifest`);
    } else {
      fail(`${pool.symbol} is live but ${prefix}_initialized is not true`);
    }

    if (deployment[`${prefix}_poolId`] === pool.poolId) {
      pass(`${pool.symbol} poolId matches deployment manifest`);
    } else {
      fail(`${pool.symbol} poolId differs from deployment manifest`);
    }

    if (deployment[`${prefix}_initializeTx`] === pool.initializeTx) {
      pass(`${pool.symbol} initializeTx matches deployment manifest`);
    } else {
      fail(`${pool.symbol} initializeTx differs from deployment manifest`);
    }

    if (deployment[`${prefix}_configureTx`] === pool.configureTx) {
      pass(`${pool.symbol} configureTx matches deployment manifest`);
    } else {
      fail(`${pool.symbol} configureTx differs from deployment manifest`);
    }

    if (typeof pool.sqrtPriceX96 === "string" && deployment[`${prefix}_sqrtPriceX96`] === pool.sqrtPriceX96) {
      pass(`${pool.symbol} sqrtPriceX96 matches deployment manifest`);
    } else {
      fail(`${pool.symbol} sqrtPriceX96 differs from deployment manifest`);
    }
  }

  for (const pool of pending) {
    checkBytes32(`${pool.symbol}.expectedPoolId`, pool.expectedPoolId);
    checkUintString(`${pool.symbol}.setupSqrtPriceX96`, pool.setupSqrtPriceX96);
    if (pool.poolId == null && pool.initializeTx == null && pool.configureTx == null) {
      pass(`${pool.symbol} is correctly marked pending without live tx hashes`);
    } else {
      fail(`${pool.symbol} is pending but has live pool/tx fields populated`);
    }
  }
}

function checkFxSwapFamily(manifest: AnyRecord, fxswapDeployment: AnyRecord, arcDeployment: AnyRecord): void {
  const family = findFamily(manifest, "FxSwapHook");
  if (!family) return;

  if (sameAddress(family.poolManager, fxswapDeployment.poolManager)) {
    pass("FxSwapHook PoolManager matches fxswap vault-backed manifest");
  } else {
    fail("FxSwapHook PoolManager does not match fxswap vault-backed manifest");
  }

  const quoterStatus = family.routerQuoterStatus ?? {};
  if (quoterStatus.genericV4Quoter === "diagnostic-proven-not-generic-empty-hookdata") {
    pass("FxSwapHook generic V4Quoter limitation is backed by the local diagnostic");
  } else {
    fail("FxSwapHook generic V4Quoter status must point at the local negative diagnostic");
  }

  if (quoterStatus.exactInput === "supported-via-direct-quote-and-protocol-router") {
    pass("FxSwapHook exact-input protocol route support is documented");
  } else {
    fail("FxSwapHook exact-input protocol route support is missing");
  }

  if (quoterStatus.exactOutput === "unsupported") {
    pass("FxSwapHook exact-output unsupported caveat is present");
  } else {
    fail("FxSwapHook exact-output unsupported caveat is missing");
  }

  const diagnostic = family.quoterDiagnostic ?? {};
  if (typeof diagnostic.test === "string" && existsSync(join(ROOT, diagnostic.test))) {
    pass(`FxSwapHook V4Quoter diagnostic test exists at ${diagnostic.test}`);
  } else {
    fail("FxSwapHook V4Quoter diagnostic test path is missing");
  }

  if (typeof diagnostic.command === "string" && diagnostic.command.includes("uniswap:fxswap:v4quoter")) {
    pass("FxSwapHook V4Quoter diagnostic command is recorded");
  } else {
    fail("FxSwapHook V4Quoter diagnostic command is missing");
  }

  if (typeof diagnostic.result === "string" && diagnostic.result.includes("3 passed") && diagnostic.result.includes("0 failed")) {
    pass("FxSwapHook V4Quoter diagnostic result is recorded");
  } else {
    fail("FxSwapHook V4Quoter diagnostic result is missing");
  }

  const poolSwapNote = arcDeployment.external?.PoolSwapTest_deprecatedNote;
  if (typeof poolSwapNote === "string" && poolSwapNote.includes("DEPRECATED for FxSwapHook PMM use")) {
    pass("arc-testnet manifest records PoolSwapTest incompatibility for FxSwapHook PMM use");
  } else {
    warn("arc-testnet manifest does not clearly record PoolSwapTest incompatibility");
  }

  for (const pool of family.pools ?? []) {
    checkAddress(`FxSwapHook ${pool.symbol} hookAddress`, pool.hookAddress);
    if (isAddress(pool.hookAddress)) {
      const actual = low14Bits(pool.hookAddress);
      const expected = Number(family.permissionFlagsLow14Bits);
      if (actual === expected) pass(`FxSwapHook ${pool.symbol} low-14 hook bits match ${expected}`);
      else fail(`FxSwapHook ${pool.symbol} low-14 hook bits ${actual} do not match expected ${expected}`);
    }

    if (isAddress(pool.currency0) && isAddress(pool.currency1) && isAddress(pool.hookAddress) && pool.poolId) {
      const computedPoolId = poolIdFromKey(
        pool.currency0,
        pool.currency1,
        Number(pool.fee),
        Number(pool.tickSpacing),
        pool.hookAddress,
      );
      if (computedPoolId === pool.poolId) {
        pass(`FxSwapHook ${pool.symbol} PoolId matches PoolKey derivation`);
      } else {
        fail(`FxSwapHook ${pool.symbol} PoolId ${pool.poolId} does not match PoolKey derivation ${computedPoolId}`);
      }
    }

    if (pool.poolId == null) {
      warn(`FxSwapHook ${pool.symbol} poolId is not machine-readable yet`);
    } else if (isNonZeroBytes32(pool.poolId)) {
      pass(`FxSwapHook ${pool.symbol} poolId is present`);
      checkBytes32(`FxSwapHook ${pool.symbol} initializeTx`, pool.initializeTx);
    } else {
      fail(`FxSwapHook ${pool.symbol} poolId is invalid`);
    }
  }
}

function checkGatewayFamily(manifest: AnyRecord, arcDeployment: AnyRecord): void {
  const family = findFamily(manifest, "TelaranaGatewayHubHook");
  if (!family) return;
  const arcPool = arcDeployment.waveN6?.newGatewayPool ?? {};
  const arcPoolKey = arcPool.poolKey ?? {};

  if (sameAddress(family.hookAddress, arcDeployment.contracts?.TelaranaGatewayHubHook?.address)) {
    pass("TelaranaGatewayHubHook address matches arc-testnet manifest");
  } else {
    fail("TelaranaGatewayHubHook address does not match arc-testnet manifest");
  }

  const quoterStatus = family.routerQuoterStatus ?? {};
  if (quoterStatus.genericV4Quoter === "not-generic-hookdata-required") {
    pass("TelaranaGatewayHubHook generic quoter caveat is present");
  } else {
    fail("TelaranaGatewayHubHook must be marked hookData-required for generic quoting");
  }

  for (const pool of family.pools ?? []) {
    checkBytes32(`TelaranaGatewayHubHook ${pool.symbol} poolId`, pool.poolId);
    checkBytes32(`TelaranaGatewayHubHook ${pool.symbol} initializeTx`, pool.initializeTx);
    if (sameAddress(pool.hookAddress ?? family.hookAddress, family.hookAddress)) {
      pass(`TelaranaGatewayHubHook ${pool.symbol} PoolKey hook matches family hook`);
    } else {
      fail(`TelaranaGatewayHubHook ${pool.symbol} PoolKey hook does not match family hook`);
    }

    if (
      sameAddress(pool.currency0, arcPoolKey.currency0)
      && sameAddress(pool.currency1, arcPoolKey.currency1)
      && Number(pool.fee) === Number(arcPoolKey.fee)
      && Number(pool.tickSpacing) === Number(arcPoolKey.tickSpacing)
      && sameAddress(pool.hookAddress ?? family.hookAddress, arcPoolKey.hooks)
    ) {
      pass(`TelaranaGatewayHubHook ${pool.symbol} PoolKey matches arc-testnet manifest`);
    } else {
      fail(`TelaranaGatewayHubHook ${pool.symbol} PoolKey does not match arc-testnet manifest`);
    }

    if (poolIdFromKey(
      pool.currency0,
      pool.currency1,
      Number(pool.fee),
      Number(pool.tickSpacing),
      pool.hookAddress ?? family.hookAddress,
    ).toLowerCase() === String(pool.poolId).toLowerCase()) {
      pass(`TelaranaGatewayHubHook ${pool.symbol} PoolId matches PoolKey derivation`);
    } else {
      fail(`TelaranaGatewayHubHook ${pool.symbol} PoolId does not match PoolKey derivation`);
    }

    if (String(pool.poolId).toLowerCase() === String(arcPool.poolId ?? "").toLowerCase()) {
      pass(`TelaranaGatewayHubHook ${pool.symbol} poolId matches arc-testnet manifest`);
    } else {
      fail(`TelaranaGatewayHubHook ${pool.symbol} poolId does not match arc-testnet manifest`);
    }

    if (String(pool.initializeTx).toLowerCase() === String(arcPool.initTx ?? "").toLowerCase()) {
      pass(`TelaranaGatewayHubHook ${pool.symbol} init tx matches arc-testnet manifest`);
    } else {
      fail(`TelaranaGatewayHubHook ${pool.symbol} init tx does not match arc-testnet manifest`);
    }

    if (String(pool.bindGatewayRouteTx ?? "").toLowerCase() === String(arcPool.bindGatewayRouteTx ?? "").toLowerCase()) {
      pass(`TelaranaGatewayHubHook ${pool.symbol} Gateway route binding tx matches arc-testnet manifest`);
    } else {
      fail(`TelaranaGatewayHubHook ${pool.symbol} Gateway route binding tx does not match arc-testnet manifest`);
    }
  }
}

function findFamily(manifest: AnyRecord, name: string): AnyRecord | undefined {
  const family = (manifest.hookFamilies ?? []).find((entry: AnyRecord) => entry.name === name);
  if (family) return family;
  fail(`manifest missing ${name} hook family`);
  return undefined;
}

function main(): void {
  console.log("Uniswap v4 indexing readiness check");
  console.log(`root ${ROOT}`);
  console.log("");

  const manifest = readJson<AnyRecord>(MANIFEST);
  const hedgeDeployment = readJson<AnyRecord>(HEDGE_DEPLOYMENT);
  const stableDeployment = readJson<AnyRecord>(HEDGE_STABLE_DEPLOYMENT);
  const fxswapDeployment = readJson<AnyRecord>(FXSWAP_DEPLOYMENT);
  const arcDeployment = readJson<AnyRecord>(ARC_DEPLOYMENT);
  const evidenceSnapshot = readJson<AnyRecord>(EVIDENCE_SNAPSHOT);
  const multichainReadiness = readJson<AnyRecord>(MULTICHAIN_MANIFEST);

  if (manifest.network === "arc-testnet" && manifest.chainId === 5042002) {
    pass("manifest targets arc-testnet chainId 5042002");
  } else {
    fail("manifest must target arc-testnet chainId 5042002");
  }

  const oneHookPerPool = manifest.uniswapIndexerModel?.oneHookPerPool;
  if (oneHookPerPool === true) {
    pass("manifest records one hook address per v4 PoolKey");
  } else {
    fail("manifest must record that a v4 PoolKey has one hook address");
  }

  checkOfficialMainnetBlock(manifest);
  checkEvidenceCommands(manifest);
  checkOfficialMultichainBlock(manifest, multichainReadiness, evidenceSnapshot);
  checkSubmissionEvidenceSnapshot(manifest, evidenceSnapshot);

  for (const family of manifest.hookFamilies ?? []) {
    checkHookFlags(family);
  }

  checkHedgeFamily(manifest, hedgeDeployment, stableDeployment);
  checkFxSwapFamily(manifest, fxswapDeployment, arcDeployment);
  checkGatewayFamily(manifest, arcDeployment);

  console.log("");
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
