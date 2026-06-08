// SPDX-License-Identifier: AGPL-3.0-only
//
// Audits the original Uniswap v4 indexing goal without redefining completion
// around local rehearsal evidence. This command is read-only and intentionally
// reports "not-complete" while official Arc mainnet contracts or official pool
// publication evidence are still missing.

import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;
type Severity = "PASS" | "WARN" | "FAIL";

const ROOT = resolve(import.meta.dir, "..");
const READINESS = "deployments/uniswap-v4-indexing-readiness-5042002.json";
const EVIDENCE = "deployments/uniswap-v4-indexing-evidence-5042002.json";
const HANDOFF = "deployments/uniswap-v4-indexing-handoff-5042002.md";
const MULTICHAIN = "deployments/uniswap-v4-official-multichain-readiness.json";

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
  const path = join(ROOT, relativePath);
  if (!existsSync(path)) {
    fail(`missing ${relativePath}`);
    return {};
  }

  return JSON.parse(readFileSync(path, "utf-8"));
}

function targetByNetwork(multichain: AnyRecord, network: string): AnyRecord {
  return (multichain.targets ?? []).find((target: AnyRecord) => target.network === network) ?? {};
}

function hasFailZero(result: unknown): boolean {
  return typeof result === "string" && result.includes("FAIL=0");
}

function hasAddress(value: unknown): boolean {
  return typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value);
}

function main(): void {
  const readiness = readJson(READINESS);
  const evidence = readJson(EVIDENCE);
  const multichain = readJson(MULTICHAIN);
  const doNotClaim = readiness.submissionPackage?.doNotClaimYet ?? [];
  const pools = evidence.pools ?? [];
  const hedgePools = pools.filter((pool: AnyRecord) => pool.family === "FxHedgeHook");
  const completionStatus = readiness.submissionPackage?.completionStatus ?? "not-complete";

  console.log("Uniswap v4 indexing completion audit");
  console.log(`root ${ROOT}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  if (readiness.network === "arc-testnet" && readiness.chainId === 5_042_002) {
    pass("readiness manifest targets Arc testnet chainId 5042002");
  } else {
    fail("readiness manifest must target Arc testnet chainId 5042002");
  }

  if (evidence.generatedFrom === READINESS && pools.length === 11) {
    pass("evidence snapshot derives from readiness manifest and carries 11 pool records");
  } else {
    fail("evidence snapshot must derive from readiness manifest and carry 11 pool records");
  }

  if (hedgePools.length === 6 && hedgePools.every((pool: AnyRecord) => pool.status === "live")) {
    pass("all six FxHedgeHook Arc testnet hedge pools are live in evidence");
  } else {
    fail("all six FxHedgeHook hedge pools must be live in Arc testnet evidence");
  }

  if (existsSync(join(ROOT, HANDOFF))) {
    pass("generated Uniswap indexing handoff packet exists");
  } else {
    fail("generated Uniswap indexing handoff packet is missing");
  }

  if (hasFailZero(readiness.submissionPackage?.currentHandoffResult)) {
    pass("handoff packet freshness result records FAIL=0");
  } else {
    fail("handoff packet freshness result must record FAIL=0");
  }

  if (hasFailZero(readiness.submissionPackage?.currentSubmissionAuditResult)) {
    pass("submission audit result records FAIL=0");
  } else {
    fail("submission audit result must record FAIL=0");
  }

  if (hasFailZero(readiness.officialMultichain?.sourceFreshness?.currentResult)) {
    pass("official Uniswap deployment docs freshness result records FAIL=0");
  } else {
    fail("official Uniswap deployment docs freshness result must record FAIL=0");
  }

  const avalanche = targetByNetwork(multichain, "avalanche");
  if (
    avalanche.status === "official-uniswap-v4-addresses-published"
    && hasAddress(avalanche.contracts?.PoolManager)
    && hasAddress(avalanche.contracts?.Quoter)
    && hasAddress(avalanche.contracts?.StateView)
  ) {
    pass("Avalanche official v4 PoolManager, Quoter, and StateView are tracked");
  } else {
    fail("Avalanche official v4 PoolManager, Quoter, and StateView must be tracked");
  }

  const arbitrum = targetByNetwork(multichain, "arbitrum-one");
  if (
    arbitrum.status === "official-uniswap-v4-addresses-published"
    && hasAddress(arbitrum.contracts?.PoolManager)
    && hasAddress(arbitrum.contracts?.Quoter)
    && hasAddress(arbitrum.contracts?.StateView)
  ) {
    pass("Arbitrum One official v4 PoolManager, Quoter, and StateView are tracked");
  } else {
    fail("Arbitrum One official v4 PoolManager, Quoter, and StateView must be tracked");
  }

  if (doNotClaim.some((entry: unknown) => typeof entry === "string" && entry.includes("Official Uniswap Arc mainnet indexing"))) {
    pass("do-not-claim caveat covers official Arc mainnet indexing");
  } else {
    fail("do-not-claim caveat must cover official Arc mainnet indexing");
  }

  if (doNotClaim.some((entry: unknown) => typeof entry === "string" && entry.includes("Avalanche Fuji indexing"))) {
    pass("do-not-claim caveat covers official Avalanche Fuji indexing");
  } else {
    fail("do-not-claim caveat must cover official Avalanche Fuji indexing");
  }

  if (doNotClaim.some((entry: unknown) => typeof entry === "string" && entry.includes("Avalanche or Arbitrum"))) {
    pass("do-not-claim caveat covers Avalanche/Arbitrum hook pool publication");
  } else {
    fail("do-not-claim caveat must cover Avalanche/Arbitrum hook pool publication");
  }

  const arc = targetByNetwork(multichain, "arc-mainnet");
  if (arc.status === "pending-official-uniswap-v4-addresses") {
    warn("completion remains pending: official Arc mainnet v4 contracts are not published");
  } else if (arc.status === "official-uniswap-v4-addresses-published") {
    pass("official Arc mainnet v4 contracts are published in the multichain manifest");
  } else {
    fail("Arc mainnet official v4 status is not recognized");
  }

  const fuji = targetByNetwork(multichain, "avalanche-fuji");
  if (fuji.status === "pending-official-uniswap-v4-addresses") {
    warn("completion remains pending for Fuji: official Fuji v4 contracts are not published");
  } else if (fuji.status === "official-uniswap-v4-addresses-published") {
    pass("official Fuji v4 contracts are published in the multichain manifest");
  } else {
    fail("Avalanche Fuji official v4 status is not recognized");
  }

  const officialArcPools = readiness.officialArcMainnet?.poolPublication?.officialPools ?? [];
  if (officialArcPools.length === 0) {
    warn("completion remains pending: no official Arc PoolManager pool publication records exist yet");
  } else {
    pass("official Arc PoolManager pool publication records exist");
  }

  const hedgeLiquidity = readiness.hookFamilies
    ?.find((family: AnyRecord) => family.name === "FxHedgeHook")
    ?.liquidityReadiness;
  if (hedgeLiquidity?.status === "pending-first-liquidity") {
    warn("router-active hedge market claims remain pending first liquidity");
  } else if (hedgeLiquidity?.status) {
    pass("FxHedgeHook liquidity readiness is no longer pending first liquidity");
  } else {
    fail("FxHedgeHook liquidity readiness status is missing");
  }

  if (completionStatus === "not-complete") {
    pass("submission package correctly records completionStatus=not-complete");
  } else if (counts.WARN === 0 && completionStatus === "complete") {
    pass("submission package records completionStatus=complete with no pending warnings");
  } else {
    fail("submission package completionStatus does not match current evidence");
  }

  console.log("");
  console.log(`completionStatus ${completionStatus}`);
  console.log(`summary PASS=${counts.PASS} WARN=${counts.WARN} FAIL=${counts.FAIL}`);
  process.exit(counts.FAIL > 0 ? 1 : 0);
}

main();
