#!/usr/bin/env bun
/**
 * Tenderly label tool.
 *
 * Reads a deployment manifest JSON and POSTs every contract + the deployer
 * wallet to the Tenderly project so the dashboard shows display names.
 *
 * Tenderly's `/wallet` endpoint accepts both EOAs and contract addresses; it
 * auto-detects the type. We use it uniformly so a single script handles both.
 *
 * Usage:
 *   bun packages/sdk/scripts/tenderly-label.ts deployments/base-sepolia.json
 *
 * Required env (loaded from .env.local at repo root):
 *   TENDERLY_ACCESS_KEY
 *   TENDERLY_ACCOUNT
 *   TENDERLY_PROJECT
 */
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

type DeploymentManifest = {
  network: string;
  chainId: number;
  deployer: string;
  contracts: Record<string, string>;
  external?: Record<string, string>;
};

function loadEnv() {
  const envPath = resolve(REPO_ROOT, ".env.local");
  if (!existsSync(envPath)) throw new Error(`.env.local not found at ${envPath}`);
  const text = readFileSync(envPath, "utf8");
  const env: Record<string, string> = {};
  for (const raw of text.split("\n")) {
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

type LabelTarget = { address: string; name: string };

async function labelOne(
  account: string,
  project: string,
  accessKey: string,
  chainId: number,
  target: LabelTarget,
): Promise<{ ok: boolean; reason?: string }> {
  const url = `https://api.tenderly.co/api/v1/account/${account}/project/${project}/wallet`;
  const body = {
    address: target.address.toLowerCase(),
    network_ids: [String(chainId)],
    display_name: target.name,
  };
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "X-Access-Key": accessKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (res.status === 409) {
    // Wallet already added with same name — try a rename so a renamed deploy still updates.
    const rename = await fetch(
      `https://api.tenderly.co/api/v1/account/${account}/project/${project}/contract/${chainId}/${target.address.toLowerCase()}/rename`,
      {
        method: "POST",
        headers: { "X-Access-Key": accessKey, "Content-Type": "application/json" },
        body: JSON.stringify({ display_name: target.name }),
      },
    );
    if (rename.ok) return { ok: true, reason: "already-present, renamed" };
    return { ok: true, reason: "already-present" };
  }
  if (!res.ok) {
    const text = await res.text();
    return { ok: false, reason: `HTTP ${res.status}: ${text.slice(0, 200)}` };
  }
  return { ok: true };
}

async function main() {
  const args = process.argv.slice(2);
  const includeExternal = args.includes("--include-external");
  const manifestArg = args.find((a) => !a.startsWith("--"));
  if (!manifestArg) {
    console.error("usage: bun tenderly-label.ts <path-to-deployments-json> [--include-external]");
    console.error("       Externals (Morpho, Pyth, USDC, ...) are skipped by default to save slots");
    console.error("       on Tenderly free plan (20-address cap).");
    process.exit(1);
  }

  const manifestPath = resolve(process.cwd(), manifestArg);
  if (!existsSync(manifestPath)) {
    console.error(`manifest not found: ${manifestPath}`);
    process.exit(1);
  }
  const manifest: DeploymentManifest = JSON.parse(readFileSync(manifestPath, "utf8"));

  const env = loadEnv();
  const accessKey = env.TENDERLY_ACCESS_KEY;
  const account = env.TENDERLY_ACCOUNT;
  const project = env.TENDERLY_PROJECT;
  if (!accessKey || !account || !project) {
    throw new Error("TENDERLY_ACCESS_KEY / TENDERLY_ACCOUNT / TENDERLY_PROJECT missing from .env.local");
  }

  const networkLabel = manifest.network.replace(/[^a-z0-9]+/gi, "-");
  const chainId = manifest.chainId;

  const targets: LabelTarget[] = [];
  targets.push({ address: manifest.deployer, name: `fx-Telarana Deployer (${networkLabel})` });

  for (const [key, addr] of Object.entries(manifest.contracts ?? {})) {
    if (!addr || addr === "0x0000000000000000000000000000000000000000") continue;
    targets.push({ address: addr, name: `${key} | ${networkLabel}` });
  }
  if (includeExternal) {
    for (const [key, addr] of Object.entries(manifest.external ?? {})) {
      if (!addr || addr === "0x0000000000000000000000000000000000000000") continue;
      targets.push({ address: addr, name: `${key} (external) | ${networkLabel}` });
    }
  }

  console.log(`labeling ${targets.length} addresses on chain ${chainId} in Tenderly project ${account}/${project}`);

  let ok = 0;
  let fail = 0;
  for (const t of targets) {
    const r = await labelOne(account, project, accessKey, chainId, t);
    if (r.ok) {
      console.log(`  ok    ${t.address}  ${t.name}${r.reason ? `  (${r.reason})` : ""}`);
      ok++;
    } else {
      console.warn(`  FAIL  ${t.address}  ${t.name}  -- ${r.reason}`);
      fail++;
    }
  }

  console.log(`\ndone: ${ok} ok, ${fail} failed`);
  console.log(`Tenderly dashboard: https://dashboard.tenderly.co/${account}/${project}/contracts`);

  if (fail > 0) process.exit(2);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
