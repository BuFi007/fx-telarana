#!/usr/bin/env bun
/**
 * Drop 2 of the simulator test suite — full category A (8 spokes × 4
 * personas × 2 deposit sizes = 64 cases) plus an initial category B mint
 * + redeem matrix on the hub (4 personas × 4 flows = 16 cases).
 *
 * Each case has an `expect: pass | revert` clause; the runner asserts.
 *
 * Run:
 *   bun packages/sdk/scripts/simulator/run-matrix.ts
 */
import { readFileSync, existsSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { TenderlyClient } from "./client.js";
import { categoryA, categoryB, type TestCase, type Expect } from "./matrix.js";
import { categoryBRedeemBundle, categoryC, categoryD, fuzzer } from "./matrix-cd.js";
import { categoryE, categoryCPrimedBorrow, categoryCSweep, categoryFAdminGuards, fetchPythUpdate } from "./matrix-d4.js";
import { categoryG } from "./matrix-d6.js";
import { categoryH } from "./matrix-d8.js";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../../..");

function loadEnv(): Record<string, string> {
  const path = resolve(REPO_ROOT, ".env.local");
  if (!existsSync(path)) throw new Error(`.env.local missing at ${path}`);
  const env: Record<string, string> = {};
  for (const raw of readFileSync(path, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const k = line.slice(0, eq).trim();
    let v = line.slice(eq + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    env[k] = v;
  }
  return env;
}

function loadSpokes() {
  const dir = resolve(REPO_ROOT, "deployments");
  const out: any[] = [];
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".json")) continue;
    if (f === "base-sepolia.json" || f === "tenderly-base-sepolia.json") continue;
    const m = JSON.parse(readFileSync(resolve(dir, f), "utf8"));
    if (!m.contracts?.FxSpoke || !m.external?.USDC) continue;
    out.push(m);
  }
  out.sort((a, b) => a.network.localeCompare(b.network));
  return out;
}

function loadHub() {
  const m = JSON.parse(readFileSync(resolve(REPO_ROOT, "deployments/base-sepolia.json"), "utf8"));
  return m;
}

function summarize(exp: Expect): string {
  if (exp.kind === "pass") return "pass";
  if (exp.kind === "revert") return "revert";
  return `revert~"${exp.needle}"`;
}

async function runOne(client: TenderlyClient, c: TestCase) {
  try {
    let res;
    if (c.bundle && c.bundle.length > 1) {
      const bundleRes = await client.simulateBundle(c.bundle);
      res = bundleRes[bundleRes.length - 1];
    } else {
      res = await client.simulate(c.request);
    }
    const status = !!res.simulation?.status;
    const url = res.simulation?.url ?? "";
    const gas = res.transaction?.gas_used ?? 0;
    const err = res.transaction?.error_message ?? res.simulation?.error_message ?? "";

    let pass = false;
    if (c.expect.kind === "pass") pass = status;
    else if (c.expect.kind === "revert") pass = !status;
    else pass = !status && err.toLowerCase().includes(c.expect.needle.toLowerCase());

    return { id: c.id, pass, sim_status: status, gas, url, err };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { id: c.id, pass: false, sim_status: false, gas: 0, url: "", err: `EXCEPTION: ${msg.slice(0, 200)}` };
  }
}

async function main() {
  const env = loadEnv();
  const client = TenderlyClient.fromEnv(env);

  // Drop 9: optional primed-vnet routing. When TENDERLY_USE_PRIMED_VNET=1
  // and the env has TENDERLY_PRIMED_VNET_PUBLIC_RPC set (populated by
  // `packages/sdk/scripts/tenderly-prime-vnet.sh`), future iterations of
  // this runner can send simulations to the vnet's RPC instead of the
  // /simulate endpoint, dropping per-case state_objects. We surface the
  // hint today so the workflow is discoverable.
  if (env.TENDERLY_USE_PRIMED_VNET === "1") {
    if (env.TENDERLY_PRIMED_VNET_PUBLIC_RPC) {
      console.log("[priming] would route sims through primed vnet: <redacted>");
      console.log("[priming] migration to vnet-RPC sims is queued for the next runner refactor;");
      console.log("[priming] current run still uses /simulate. Pattern is wired in priming.ts.");
    } else {
      console.warn("[priming] TENDERLY_USE_PRIMED_VNET=1 but no primed vnet env detected;");
      console.warn("[priming] run scripts/tenderly-prime-vnet.sh first.");
    }
  }

  const spokes = loadSpokes();
  const hub = loadHub();

  const hubManifest = {
    network: hub.network,
    chainId: hub.chainId,
    contracts: {
      FxOracle: hub.contracts.FxOracle,
      FxMarketRegistry: hub.contracts.FxMarketRegistry,
      FxReceiptUSDC: hub.contracts.FxReceiptUSDC,
      FxReceiptEURC: hub.contracts.FxReceiptEURC,
      FxLiquidator: hub.contracts.FxLiquidator,
      FxHubMessageReceiver: hub.contracts.FxHubMessageReceiver,
      FxSwapHook: hub.contracts.FxSwapHook,
      MorphoOracleAdapterM1: hub.contracts.MorphoOracleAdapterM1,
      MorphoOracleAdapterM2: hub.contracts.MorphoOracleAdapterM2,
    },
    external: {
      USDC: hub.external.USDC,
      EURC: hub.external.EURC,
      MorphoBlue: hub.external.MorphoBlue,
      Pyth: hub.external.Pyth,
    },
  };

  console.log("fetching fresh Pyth Hermes payload...");
  const pythUpdate = await fetchPythUpdate();
  console.log(`  got ${pythUpdate.length} VAA(s), total ${pythUpdate[0].length - 2} hex chars`);

  const cases: TestCase[] = [
    ...categoryA(spokes),
    ...categoryB({
      network: hub.network,
      chainId: hub.chainId,
      contracts: {
        FxOracle: hub.contracts.FxOracle,
        FxMarketRegistry: hub.contracts.FxMarketRegistry,
        FxReceiptUSDC: hub.contracts.FxReceiptUSDC,
        FxReceiptEURC: hub.contracts.FxReceiptEURC,
      },
      external: { USDC: hub.external.USDC, EURC: hub.external.EURC },
    }),
    ...categoryBRedeemBundle(hubManifest),
    ...categoryC(hubManifest),
    ...categoryD(hubManifest),
    ...categoryE(hubManifest, pythUpdate),
    ...categoryCPrimedBorrow(hubManifest, pythUpdate),
    ...categoryCSweep(hubManifest),
    ...categoryFAdminGuards(hubManifest),
    ...categoryG({
      chainId: hub.chainId,
      contracts: {
        FxMarketRegistry: hub.contracts.FxMarketRegistry,
        FxHubMessageReceiver: hub.contracts.FxHubMessageReceiver,
      },
      external: { USDC: hub.external.USDC },
    }),
    ...(await categoryH({
      chainId: hub.chainId,
      contracts: { FxSwapHook: hub.contracts.FxSwapHook },
      external: { USDC: hub.external.USDC, EURC: hub.external.EURC, Pyth: hub.external.Pyth },
    })),
    ...fuzzer(spokes, hubManifest, 0xdeadbeef, 20),
  ];

  console.log(`running ${cases.length} cases (Drop 2: A=64 + B=16)\n`);

  const results: Array<Awaited<ReturnType<typeof runOne>>> = [];
  let ok = 0;
  let fail = 0;

  for (const c of cases) {
    const r = await runOne(client, c);
    results.push(r);
    const tag = r.pass ? "ok  " : "FAIL";
    console.log(`  ${tag}  ${r.id.padEnd(48)} sim=${r.sim_status ? "✓" : "✗"} gas=${String(r.gas).padStart(8)}`);
    if (!r.pass) {
      console.log(`        url=${r.url}`);
      if (r.err) console.log(`        err=${r.err.slice(0, 200)}`);
    }
    if (r.pass) ok++;
    else fail++;
  }

  console.log(`\n${ok}/${cases.length} ok, ${fail} failed\n`);

  // Write a Markdown report alongside the deployment manifests.
  mkdirSync(resolve(REPO_ROOT, "reports"), { recursive: true });
  const lines: string[] = [
    "# Simulator matrix run\n",
    `Run at: ${new Date().toISOString()}\n`,
    `Result: **${ok}/${cases.length}** pass, **${fail}** fail\n`,
    "| # | Test | Expect | Sim | Pass | Gas | Trace |",
    "|---|---|---|---|---|---|---|",
  ];
  cases.forEach((c, i) => {
    const r = results[i];
    lines.push(
      `| ${i + 1} | \`${c.id}\` | ${summarize(c.expect)} | ${r.sim_status ? "✓" : "✗"} | ${r.pass ? "✅" : "❌"} | ${r.gas} | ${r.url ? `[link](${r.url})` : "-"} |`,
    );
  });
  writeFileSync(resolve(REPO_ROOT, "reports/sim-matrix-latest.md"), lines.join("\n") + "\n");
  console.log("wrote reports/sim-matrix-latest.md");

  if (fail > 0) process.exit(2);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
