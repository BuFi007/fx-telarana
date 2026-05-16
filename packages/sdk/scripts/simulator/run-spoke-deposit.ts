#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only
/**
 * Drop 1 of the simulator test suite — single happy-path deposit per spoke.
 *
 * For each deployed spoke we run ONE Tenderly simulation:
 *   - `mid` persona starts with 1,000 USDC pre-loaded via state override
 *   - persona calls `FxSpoke.enterHub(usdc, 500e6, persona, "")` with an
 *     unlimited allowance also pre-loaded.
 *   - We assert `simulation.status === true` and gas_used > 0.
 *
 * Output: one row per spoke with the Tenderly dashboard URL. Failing sims
 * exit non-zero with the trace URL so the developer can debug visually.
 *
 * Run:
 *   bun packages/sdk/scripts/simulator/run-spoke-deposit.ts
 */
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeFunctionData, parseAbi, type Address, type Hex } from "viem";
import { TenderlyClient } from "./client.js";
import { PERSONAS, personaState, type Persona } from "./personas.js";

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

type SpokeManifest = {
  network: string;
  chainId: number;
  contracts: { FxSpoke: Address };
  external: { USDC: Address };
};

function loadSpokes(): SpokeManifest[] {
  const dir = resolve(REPO_ROOT, "deployments");
  const out: SpokeManifest[] = [];
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".json")) continue;
    if (f === "base-sepolia.json" || f === "tenderly-base-sepolia.json") continue; // hub
    const m = JSON.parse(readFileSync(resolve(dir, f), "utf8"));
    if (!m.contracts?.FxSpoke || !m.external?.USDC) continue;
    out.push(m);
  }
  // Keep a stable order for reports.
  out.sort((a, b) => a.network.localeCompare(b.network));
  return out;
}

const SPOKE_ABI = parseAbi([
  "function enterHub(address token, uint256 amount, address beneficiary, bytes hubCalldata) external payable returns (bytes32)",
]);

async function main() {
  const env = loadEnv();
  const client = TenderlyClient.fromEnv(env);
  const spokes = loadSpokes();
  console.log(`simulating spoke deposit on ${spokes.length} chains\n`);

  const persona: Persona = PERSONAS.mid;
  const depositAmount = 500_000_000n; // 500 USDC
  const hubCalldata: Hex = "0x"; // empty — just bridges USDC, hub-side relayer can act on it

  let ok = 0;
  let fail = 0;
  const rows: string[] = [];

  for (const s of spokes) {
    const input = encodeFunctionData({
      abi: SPOKE_ABI,
      functionName: "enterHub",
      args: [s.external.USDC, depositAmount, persona.address, hubCalldata],
    });
    const state = personaState(persona, s.external.USDC, s.contracts.FxSpoke);

    try {
      const res = await client.simulate({
        network_id: String(s.chainId),
        from: persona.address,
        to: s.contracts.FxSpoke,
        input,
        state_objects: state,
      });
      const status = res.simulation?.status;
      const tag = status ? "ok  " : "FAIL";
      const gas = res.transaction?.gas_used ?? 0;
      console.log(`  ${tag}  ${s.network.padEnd(22)} gas=${gas.toString().padStart(8)}  ${res.simulation.url}`);
      rows.push(`| ${s.network} | ${status ? "✅" : "❌"} | ${gas} | [trace](${res.simulation.url}) |`);
      if (status) ok++;
      else {
        fail++;
        if (res.transaction?.error_message) {
          console.log(`        error: ${res.transaction.error_message}`);
        }
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.log(`  FAIL  ${s.network.padEnd(22)} EXCEPTION: ${msg.slice(0, 200)}`);
      rows.push(`| ${s.network} | ❌ | err | \`${msg.slice(0, 80)}\` |`);
      fail++;
    }
  }

  console.log(`\n${ok}/${spokes.length} ok, ${fail} failed`);
  console.log("\nMarkdown:\n| Chain | Status | Gas | Trace |");
  console.log("|---|---|---|---|");
  for (const r of rows) console.log(r);

  if (fail > 0) process.exit(2);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
