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
import { VnetRunner } from "./vnet-runner.js";
import { categoryA, categoryB, type TestCase, type Expect } from "./matrix.js";
import { categoryBRedeemBundle, categoryC, categoryD, fuzzer } from "./matrix-cd.js";
import { categoryE, categoryCPrimedBorrow, categoryCSweep, categoryFAdminGuards, fetchPythUpdate } from "./matrix-d4.js";
import { categoryG } from "./matrix-d6.js";
import { categoryH } from "./matrix-d8.js";
import { PERSONAS } from "./personas.js";

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

/**
 * Given the primed vnet's chainId, return the USDC address + min-balance to
 * assert during pre-flight. We look first at the hub (Base Sepolia) and
 * then at each spoke manifest. If the vnet forked a chain we don't deploy
 * onto, returns undefined and the pre-flight skips the balance check.
 */
function pickWhaleUsdcCheck(
  vnetChainId: number,
  hub: ReturnType<typeof loadHub>,
  spokes: ReturnType<typeof loadSpokes>,
): { token: `0x${string}`; account: `0x${string}`; minBalance: bigint } | undefined {
  const whale = PERSONAS.whale;
  if (Number(hub.chainId) === vnetChainId && hub.external?.USDC) {
    return { token: hub.external.USDC, account: whale.address, minBalance: 1n };
  }
  for (const s of spokes) {
    if (Number(s.chainId) === vnetChainId && s.external?.USDC) {
      return { token: s.external.USDC, account: whale.address, minBalance: 1n };
    }
  }
  return undefined;
}

type CaseResult = {
  id: string;
  pass: boolean;
  sim_status: boolean;
  gas: number;
  url: string;
  err: string;
  /** Which backend executed this case: "/simulate" or `vnet:<chainId>`. */
  backend: string;
};

/**
 * Decide whether a case should be routed through the primed vnet. A case
 * is vnet-eligible when:
 *   - a `VnetRunner` is configured, AND
 *   - every tx in the case targets the vnet's chainId.
 *
 * Bundle txs can span different chains in principle, but every shipping
 * matrix today binds a bundle to a single network_id, so the check is
 * effectively "does the case's network_id match the vnet?".
 */
function shouldUseVnet(vnet: VnetRunner | null, c: TestCase): boolean {
  if (!vnet) return false;
  if (c.bundle && c.bundle.length > 0) {
    return c.bundle.every((b) => vnet.canHandle(b.network_id));
  }
  return vnet.canHandle(c.request.network_id);
}

async function runOne(
  client: TenderlyClient,
  vnet: VnetRunner | null,
  c: TestCase,
  onFallback: (id: string, reason: string) => void,
): Promise<CaseResult> {
  const useVnet = shouldUseVnet(vnet, c);
  const backend = useVnet && vnet ? `vnet:${vnet.chainId}` : "/simulate";
  try {
    let res;
    if (useVnet && vnet) {
      if (c.bundle && c.bundle.length > 1) {
        const bundleRes = await vnet.simulateBundle(c.bundle);
        res = bundleRes[bundleRes.length - 1];
      } else {
        res = await vnet.simulate(c.request);
      }
    } else {
      if (vnet && !useVnet) {
        // Record one-line fallback notice (chainId mismatch with primed vnet).
        const targetChain = c.bundle && c.bundle.length > 0
          ? c.bundle[0].network_id
          : c.request.network_id;
        onFallback(c.id, `chain ${targetChain} not on primed vnet (chain ${vnet.chainId})`);
      }
      if (c.bundle && c.bundle.length > 1) {
        const bundleRes = await client.simulateBundle(c.bundle);
        res = bundleRes[bundleRes.length - 1];
      } else {
        res = await client.simulate(c.request);
      }
    }
    const status = !!res.simulation?.status;
    const url = res.simulation?.url ?? "";
    const gas = res.transaction?.gas_used ?? 0;
    const err = res.transaction?.error_message ?? res.simulation?.error_message ?? "";

    let pass = false;
    if (c.expect.kind === "pass") pass = status;
    else if (c.expect.kind === "revert") pass = !status;
    else pass = !status && err.toLowerCase().includes(c.expect.needle.toLowerCase());

    return { id: c.id, pass, sim_status: status, gas, url, err, backend };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { id: c.id, pass: false, sim_status: false, gas: 0, url: "", err: `EXCEPTION: ${msg.slice(0, 200)}`, backend };
  }
}

async function main() {
  const env = loadEnv();
  const client = TenderlyClient.fromEnv(env);

  // Drop 9: optional primed-vnet routing. When TENDERLY_USE_PRIMED_VNET=1
  // we route every case whose `network_id` matches the vnet's chainId
  // through `tenderly_simulateBundle` on the vnet's admin RPC instead of
  // POSTing to Tenderly's `/simulate` endpoint. Cases targeting other
  // chains fall back to `/simulate` automatically.
  const vnet = VnetRunner.fromEnv(env);
  const spokes = loadSpokes();
  const hub = loadHub();

  if (env.TENDERLY_USE_PRIMED_VNET === "1") {
    if (!vnet) {
      console.warn("[priming] TENDERLY_USE_PRIMED_VNET=1 but vnet env incomplete;");
      console.warn("[priming]   run packages/sdk/scripts/tenderly-prime-vnet.sh first.");
    } else {
      // Pre-flight: confirm vnet is on the chainId we expect and the whale
      // persona's USDC balance was actually primed. Abort otherwise so the
      // suite never silently misroutes against a stale or wrong-chain vnet.
      console.log(`[priming] vnet routing enabled (expecting chainId ${vnet.chainId})`);
      const whaleUsdc = pickWhaleUsdcCheck(vnet.chainId, hub, spokes);
      try {
        const pre = await vnet.assertReady({
          expectedChainId: vnet.chainId,
          whaleUsdc,
        });
        if (whaleUsdc) {
          console.log(
            `[priming] pre-flight ok: chainId=${pre.chainId}, whale USDC=${pre.whaleBalance?.toString() ?? "n/a"}`,
          );
        } else {
          console.warn(
            `[priming] pre-flight chainId=${pre.chainId} (no USDC contract known for this chain — skipped balance check)`,
          );
        }
      } catch (e) {
        console.error(`[priming] pre-flight FAILED: ${e instanceof Error ? e.message : String(e)}`);
        process.exit(3);
      }
    }
  }

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

  const results: CaseResult[] = [];
  let ok = 0;
  let fail = 0;
  let vnetRouted = 0;
  let simRouted = 0;
  const fallbackSeen = new Set<string>();
  const fallback = (id: string, reason: string) => {
    if (fallbackSeen.has(id)) return;
    fallbackSeen.add(id);
    console.log(`  [vnet-fallback] ${id} -> /simulate (${reason})`);
  };

  for (const c of cases) {
    const r = await runOne(client, vnet, c, fallback);
    results.push(r);
    if (r.backend.startsWith("vnet:")) vnetRouted++; else simRouted++;
    const tag = r.pass ? "ok  " : "FAIL";
    console.log(`  ${tag}  ${r.id.padEnd(48)} sim=${r.sim_status ? "✓" : "✗"} gas=${String(r.gas).padStart(8)} backend=${r.backend}`);
    if (!r.pass) {
      console.log(`        url=${r.url}`);
      if (r.err) console.log(`        err=${r.err.slice(0, 200)}`);
    }
    if (r.pass) ok++;
    else fail++;
  }

  if (vnet) {
    console.log(`\n[priming] routing summary: ${vnetRouted} cases via vnet:${vnet.chainId}, ${simRouted} via /simulate`);
  }

  console.log(`\n${ok}/${cases.length} ok, ${fail} failed\n`);

  // Write a Markdown report alongside the deployment manifests.
  mkdirSync(resolve(REPO_ROOT, "reports"), { recursive: true });
  const lines: string[] = [
    "# Simulator matrix run\n",
    `Run at: ${new Date().toISOString()}\n`,
    `Result: **${ok}/${cases.length}** pass, **${fail}** fail\n`,
  ];
  if (vnet) {
    lines.push(
      `Backend routing: **${vnetRouted}** via \`vnet:${vnet.chainId}\`, **${simRouted}** via \`/simulate\`\n`,
    );
  } else {
    lines.push(`Backend routing: all cases via \`/simulate\` (primed-vnet flag not set)\n`);
  }
  lines.push("| # | Test | Expect | Sim | Pass | Gas | Backend | Trace |");
  lines.push("|---|---|---|---|---|---|---|---|");
  cases.forEach((c, i) => {
    const r = results[i];
    const traceCell = r.backend.startsWith("vnet:")
      ? `\`${r.backend}\``
      : r.url
        ? `[link](${r.url})`
        : "-";
    lines.push(
      `| ${i + 1} | \`${c.id}\` | ${summarize(c.expect)} | ${r.sim_status ? "✓" : "✗"} | ${r.pass ? "✅" : "❌"} | ${r.gas} | \`${r.backend}\` | ${traceCell} |`,
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
