// SPDX-License-Identifier: AGPL-3.0-only
//
// Runs the current no-broadcast Uniswap v4 indexing evidence suite and emits a
// compact reviewer-facing summary. This is intentionally an execution audit,
// not another manifest-only check: it re-runs the live docs freshness gate,
// Arc receipt verifier, and local V4Quoter diagnostics.

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";

type AnyRecord = Record<string, any>;

type AuditCheck = {
  key: string;
  label: string;
};

type ParsedResult = {
  pass: number | null;
  warn: number;
  fail: number | null;
  note: string;
};

const ROOT = resolve(import.meta.dir, "..");
const MANIFEST = "deployments/uniswap-v4-indexing-readiness-5042002.json";

const CHECKS: AuditCheck[] = [
  { key: "officialMultichainDocsFreshness", label: "official Uniswap deployments freshness" },
  { key: "officialMultichainDocsFreshnessSelfTest", label: "official deployments freshness self-test" },
  { key: "officialArcReadiness", label: "official Arc readiness" },
  { key: "officialArcMigrationPlan", label: "official Arc migration plan" },
  { key: "officialArcHookRedeployPlan", label: "official Arc hook redeploy plan" },
  { key: "officialArcDeploymentInputGenerate", label: "official Arc deployment input generator" },
  { key: "officialArcDeploymentInputCheck", label: "official Arc deployment input" },
  { key: "officialArcDeploymentInputSelfTest", label: "official Arc deployment input self-test" },
  { key: "officialArcDeploymentInputGenerateSelfTest", label: "official Arc deployment input generator self-test" },
  { key: "officialArcPoolPublicationCheck", label: "official Arc pool publication" },
  { key: "officialArcPoolPublicationPlan", label: "official Arc pool-publication fill plan" },
  { key: "officialArcPoolPublicationSelfTest", label: "official Arc pool publication self-test" },
  { key: "officialArcStateViewReadiness", label: "official StateView readiness" },
  { key: "subgraphReadiness", label: "official subgraph readiness" },
  { key: "officialMultichainReadiness", label: "official multichain readiness" },
  { key: "officialMultichainDeploymentInputCheck", label: "official multichain deployment input" },
  { key: "officialMultichainDeploymentInputGenerate", label: "official multichain deployment input generator" },
  { key: "officialMultichainDeploymentInputGenerateSelfTest", label: "official multichain deployment input generator self-test" },
  { key: "officialMultichainPoolPublication", label: "official multichain pool publication" },
  { key: "officialMultichainPoolPublicationSelfTest", label: "official multichain pool publication self-test" },
  { key: "pendingHedgePoolsPlan", label: "live FxHedgeHook stable pool storage verifier" },
  { key: "hedgeHookLiquidityVerifier", label: "FxHedgeHook liquidity readiness" },
  { key: "hedgeHookLiquiditySeedPlan", label: "FxHedgeHook liquidity seed plan" },
  { key: "onchainReceiptVerifier", label: "Arc testnet PoolManager receipt verifier" },
  { key: "hedgeHookV4QuoterDiagnostic", label: "FxHedgeHook official V4Quoter diagnostic" },
  { key: "fxSwapHookV4QuoterDiagnostic", label: "FxSwapHook V4Quoter diagnostic" },
  { key: "submissionEvidenceFreshness", label: "indexing evidence snapshot freshness" },
];

function readJson(relativePath: string): AnyRecord {
  return JSON.parse(readFileSync(join(ROOT, relativePath), "utf-8"));
}

function tail(text: string, maxChars = 5000): string {
  if (text.length <= maxChars) return text;
  return text.slice(text.length - maxChars);
}

function parseResult(output: string): ParsedResult {
  const summary = output.match(/summary\s+PASS=(\d+)(?:\s+WARN=(\d+))?\s+FAIL=(\d+)/);
  if (summary) {
    const pass = Number(summary[1]);
    const warn = Number(summary[2] ?? "0");
    const fail = Number(summary[3]);
    return { pass, warn, fail, note: `PASS=${pass} WARN=${warn} FAIL=${fail}` };
  }

  const forge = output.match(/(\d+)\s+tests?\s+passed,\s+0\s+failed/i)
    ?? output.match(/Suite result:\s+ok\.\s+(\d+)\s+passed;\s+0\s+failed/i);
  if (forge) {
    const pass = Number(forge[1]);
    return { pass, warn: 0, fail: 0, note: `${pass} forge tests passed` };
  }

  if (output.includes("is fresh")) {
    return { pass: 1, warn: 0, fail: 0, note: "snapshot fresh" };
  }

  return { pass: null, warn: 0, fail: null, note: "command exited 0" };
}

function commandFor(manifest: AnyRecord, key: string): string {
  const command = manifest.evidenceCommands?.[key];
  if (typeof command !== "string" || command.trim() === "") {
    throw new Error(`missing evidenceCommands.${key}`);
  }
  return command;
}

function runShell(command: string): { exitCode: number; output: string } {
  const proc = Bun.spawnSync({
    cmd: ["bash", "-lc", command],
    cwd: ROOT,
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });

  const stdout = proc.stdout.toString();
  const stderr = proc.stderr.toString();
  return {
    exitCode: proc.exitCode ?? 1,
    output: `${stdout}${stderr ? `\n${stderr}` : ""}`,
  };
}

function main(): void {
  const manifest = readJson(MANIFEST);
  let passedChecks = 0;
  let warningCount = 0;
  let failedChecks = 0;

  console.log("Uniswap v4 indexing submission audit");
  console.log(`root ${ROOT}`);
  console.log("mode read-only/no-broadcast");
  console.log("");

  for (const check of CHECKS) {
    const command = commandFor(manifest, check.key);
    const result = runShell(command);
    const parsed = parseResult(result.output);
    const hasParsedFailures = parsed.fail != null && parsed.fail > 0;
    const ok = result.exitCode === 0 && !hasParsedFailures;

    warningCount += parsed.warn;
    if (ok) {
      passedChecks += 1;
      console.log(`PASS ${check.label}: ${parsed.note}`);
      continue;
    }

    failedChecks += 1;
    console.log(`FAIL ${check.label}: ${command}`);
    console.log(tail(result.output));
  }

  console.log("");
  console.log(`summary CHECKS=${CHECKS.length} PASS=${passedChecks} WARN=${warningCount} FAIL=${failedChecks}`);
  process.exit(failedChecks > 0 ? 1 : 0);
}

main();
