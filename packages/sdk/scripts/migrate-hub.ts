#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only
/**
 * Hub migration orchestrator.
 *
 * fx-Telaraña's hub primitives (`FxHubMessageReceiver`, `FxMarketRegistry`,
 * `FxLiquidator`, `FxOracle`, `FxReceipt`s, `MorphoOracleAdapter`s, `FxSwapHook`)
 * live on a single chain. Every spoke's `FxSpoke` is **immutable** — the
 * hub receiver address + CCTP V2 domain are baked at construction. Migrating
 * the hub therefore means **redeploying every spoke** pointing at the new
 * hub.
 *
 * Migration plan: Base Sepolia → Avalanche Fuji (step 1) → Arc Testnet (step 2).
 *
 * Safety model (post Codex review):
 *   1. PREFLIGHT — for every spoke that will be redeployed: confirm the
 *      RPC is reachable (one `eth_chainId` call), confirm the deployer has
 *      nonzero native balance, confirm `DEPLOYER_PRIVATE_KEY` is set.
 *      Abort with a non-zero exit BEFORE the first broadcast on any failure.
 *   2. STATE FILE — `deployments/.hub-migration-state.json` is created on
 *      `--execute` start with one entry per spoke (`pending`/`succeeded`/
 *      `failed`). Updated after each step. Loaded on `--resume` to skip
 *      already-succeeded chains.
 *   3. TWO-PHASE MANIFEST WRITE — the new FxSpoke address is staged into
 *      the state file FIRST. We then read `HUB_RECEIVER()` and `ARC_DOMAIN()`
 *      from the freshly-deployed FxSpoke via `cast call`. ONLY when both
 *      reads match the new hub config do we overwrite
 *      `deployments/<chain>.json`. Parse failures (no `FxSpoke 0x…` line in
 *      forge stdout) hard-exit; we never write a placeholder string.
 *   4. FAIL-FAST — on any failure the offending chain is marked `failed`,
 *      the resume command is printed, and the process exits with code 2.
 *   5. RESUME — `--resume <state-file>` re-reads the state and skips chains
 *      with status `succeeded`.
 *   6. ROLLBACK — `--rollback <state-file>` re-runs the migration with the
 *      `previousHubConfig` snapshot baked into the state file at start time,
 *      pointing already-migrated spokes back at the old hub.
 *
 * Usage:
 *   bun packages/sdk/scripts/migrate-hub.ts <new-hub-config.json>            # dry run
 *   bun packages/sdk/scripts/migrate-hub.ts <new-hub-config.json> --execute
 *   bun packages/sdk/scripts/migrate-hub.ts <new-hub-config.json> --resume
 *   bun packages/sdk/scripts/migrate-hub.ts <ignored>            --rollback <state-file>
 *
 * new-hub-config.json shape:
 *   {
 *     "network": "avalanche-fuji",
 *     "chainId": 43113,
 *     "messageReceiver": "0x...",
 *     "cctpDomain": 1,
 *     "rpcUrl": "https://api.avax-test.network/ext/bc/C/rpc"
 *   }
 */
import { readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import { createPublicClient, http, type Address, type Hex } from "viem";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const STATE_PATH = process.env.HUB_MIGRATION_STATE_PATH
  ? resolve(REPO_ROOT, process.env.HUB_MIGRATION_STATE_PATH)
  : resolve(REPO_ROOT, "deployments/.hub-migration-state.json");

type HubConfig = {
  network: string;
  chainId: number;
  messageReceiver: string;
  cctpDomain: number;
  rpcUrl: string;
};

type SpokeHubBlock = {
  network: string;
  chainId: number;
  messageReceiver: string;
  cctpDomain: number;
};

type SpokeManifest = {
  network: string;
  chainId: number;
  contracts: { FxSpoke: string; [k: string]: string };
  external: { USDC: string; CctpTokenMessengerV2: string; CctpDomain: string };
  hub: SpokeHubBlock;
};

type SpokeStatus = "pending" | "succeeded" | "failed";

type SpokeStateEntry = {
  network: string;
  chainId: number;
  manifestPath: string;
  rpc: string;
  oldFxSpoke: string;
  oldHub: SpokeHubBlock;
  newFxSpoke?: string;        // staged after broadcast, before manifest write
  status: SpokeStatus;
  attempts: number;
  lastError?: string;
};

type MigrationState = {
  startedAt: string;
  newHub: HubConfig;
  previousHubConfig: HubConfig;  // snapshot of OLD hub for --rollback
  spokes: Record<string, SpokeStateEntry>; // keyed by chainId as string
};

// Public RPCs per chain — used when the spoke manifest doesn't have one.
const RPC: Record<number, string> = {
  11155111: "https://ethereum-sepolia-rpc.publicnode.com",
  11155420: "https://sepolia.optimism.io",
  421614:   "https://sepolia-rollup.arbitrum.io/rpc",
  43113:    "https://api.avax-test.network/ext/bc/C/rpc",
  80002:    "https://rpc-amoy.polygon.technology",
  59141:    "https://rpc.sepolia.linea.build",
  1301:     "https://sepolia.unichain.org",
  4801:     "https://worldchain-sepolia.g.alchemy.com/public",
  5042002:  "https://rpc.testnet.arc.network",
};

function loadSpokes(): { path: string; manifest: SpokeManifest }[] {
  const dir = resolve(REPO_ROOT, "deployments");
  const out: { path: string; manifest: SpokeManifest }[] = [];
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".json")) continue;
    if (f.startsWith("tenderly-")) continue;
    if (f.startsWith("hub-config")) continue;
    if (f.startsWith(".")) continue;
    const p = resolve(dir, f);
    const m = JSON.parse(readFileSync(p, "utf8"));
    if (!m.contracts?.FxSpoke || !m.hub?.messageReceiver) continue;
    out.push({ path: p, manifest: m });
  }
  return out;
}

function fail(msg: string, code: number = 2): never {
  console.error(`\n${msg}\n`);
  process.exit(code);
}

function printResume(): void {
  console.error(`To resume after fixing the failure:`);
  console.error(`  bun packages/sdk/scripts/migrate-hub.ts <new-hub-config.json> --resume\n`);
}

function loadState(): MigrationState | null {
  if (!existsSync(STATE_PATH)) return null;
  return JSON.parse(readFileSync(STATE_PATH, "utf8")) as MigrationState;
}

function writeState(state: MigrationState): void {
  writeFileSync(STATE_PATH, JSON.stringify(state, null, 2) + "\n");
}

// ── PREFLIGHT ──────────────────────────────────────────────────────────────
// Throws (via fail()) on the first failure so we never broadcast a single tx
// against a half-broken environment.
async function preflight(
  workItems: { path: string; manifest: SpokeManifest; rpc: string }[],
): Promise<void> {
  if (!process.env.DEPLOYER_PRIVATE_KEY) {
    fail("PREFLIGHT FAIL: DEPLOYER_PRIVATE_KEY env var is not set.", 2);
  }
  const pk = process.env.DEPLOYER_PRIVATE_KEY as string;
  // Resolve deployer address via `cast wallet address` so we don't have to
  // import a viem account from a private key here (keeps the preflight pure).
  let deployer: Address;
  try {
    deployer = execSync(`cast wallet address ${pk}`, { stdio: "pipe" })
      .toString()
      .trim() as Address;
  } catch (e) {
    fail(
      `PREFLIGHT FAIL: could not derive deployer address from DEPLOYER_PRIVATE_KEY:\n  ${
        e instanceof Error ? e.message : String(e)
      }`,
      2,
    );
  }
  console.log(`preflight deployer: ${deployer}`);

  for (const { manifest: m, rpc } of workItems) {
    process.stdout.write(`  checking ${m.network} (chain ${m.chainId}) … `);
    let pc;
    try {
      pc = createPublicClient({ transport: http(rpc) });
    } catch (e) {
      console.log("FAIL (transport)");
      fail(
        `PREFLIGHT FAIL on ${m.network}: cannot construct transport for ${rpc}\n  ${
          e instanceof Error ? e.message : String(e)
        }`,
        2,
      );
    }
    // eth_chainId
    let onchainChainId: number;
    try {
      onchainChainId = await pc.getChainId();
    } catch (e) {
      console.log("FAIL (eth_chainId)");
      fail(
        `PREFLIGHT FAIL on ${m.network}: eth_chainId call against ${rpc} failed:\n  ${
          e instanceof Error ? e.message : String(e)
        }`,
        2,
      );
    }
    if (onchainChainId !== m.chainId) {
      console.log("FAIL (chainId mismatch)");
      fail(
        `PREFLIGHT FAIL on ${m.network}: manifest chainId=${m.chainId}, RPC reports ${onchainChainId}. Refusing to broadcast.`,
        2,
      );
    }
    // getBalance
    let bal: bigint;
    try {
      bal = await pc.getBalance({ address: deployer });
    } catch (e) {
      console.log("FAIL (eth_getBalance)");
      fail(
        `PREFLIGHT FAIL on ${m.network}: eth_getBalance call failed:\n  ${
          e instanceof Error ? e.message : String(e)
        }`,
        2,
      );
    }
    if (bal === 0n) {
      console.log("FAIL (zero balance)");
      fail(
        `PREFLIGHT FAIL on ${m.network}: deployer ${deployer} has zero native balance. Fund and retry.`,
        2,
      );
    }
    console.log(`ok (balance=${bal} wei)`);
  }
  console.log("preflight: all spokes reachable, deployer funded everywhere.\n");
}

// ── ON-CHAIN VERIFICATION ──────────────────────────────────────────────────
// Reads HUB_RECEIVER() + ARC_DOMAIN() from the freshly-deployed FxSpoke via
// cast and asserts they match the new hub config. Returns null on success or
// a human-readable error string on mismatch / RPC error.
//
// Cast is more lenient about RPC response shape than viem (some testnet RPCs
// return empty-body for viem's default request shape), so we shell out. The
// gotcha is that --broadcast --slow returns as soon as receipts are mined but
// some RPCs lag a few seconds before eth_call sees the new code. We retry
// up to 6 times with 3s backoff to cover that window.
async function verifyDeployedSpoke(
  newAddr: Address,
  rpc: string,
  expectedHub: HubConfig,
): Promise<string | null> {
  function castCall(sig: string): { out?: string; err?: string } {
    try {
      const out = execSync(`cast call ${newAddr} '${sig}' --rpc-url '${rpc}' 2>&1`, {
        stdio: "pipe",
        encoding: "utf8",
      }).toString().trim();
      return { out };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      const stderr = (e as { stderr?: Buffer }).stderr?.toString() ?? "";
      const stdout = (e as { stdout?: Buffer }).stdout?.toString() ?? "";
      return { err: `${msg}\nstderr: ${stderr}\nstdout: ${stdout}` };
    }
  }

  async function castCallWithRetry(sig: string, label: string): Promise<{ out?: string; err?: string }> {
    let lastErr: string | undefined;
    for (let attempt = 1; attempt <= 6; attempt++) {
      await new Promise((r) => setTimeout(r, attempt === 1 ? 2000 : 3000));
      const r = castCall(sig);
      if (!r.err && r.out) {
        // cast prints decode errors to stdout with non-zero exit. Guard against
        // a successful execSync that still contains a decode error.
        if (r.out.toLowerCase().includes("error:")) {
          lastErr = r.out;
          console.log(`    ${label} attempt ${attempt}/6: decode error, retrying …`);
          continue;
        }
        return r;
      }
      lastErr = r.err ?? "empty result";
      console.log(`    ${label} attempt ${attempt}/6: ${lastErr.slice(0, 80)} …`);
    }
    return { err: lastErr ?? "exhausted retries" };
  }

  const recvR = await castCallWithRetry("HUB_RECEIVER()(address)", "HUB_RECEIVER");
  if (recvR.err) return `cast HUB_RECEIVER call failed: ${recvR.err.slice(0, 400)}`;
  const recv = (recvR.out ?? "").split(/\s+/)[0].toLowerCase();
  if (recv !== expectedHub.messageReceiver.toLowerCase()) {
    return `HUB_RECEIVER mismatch: expected ${expectedHub.messageReceiver}, got ${recv}`;
  }

  const domR = await castCallWithRetry("ARC_DOMAIN()(uint32)", "ARC_DOMAIN");
  if (domR.err) return `cast ARC_DOMAIN call failed: ${domR.err.slice(0, 400)}`;
  const domStr = (domR.out ?? "").split(/\s+/)[0];
  const dom = domStr.startsWith("0x") ? parseInt(domStr, 16) : parseInt(domStr, 10);
  if (!Number.isFinite(dom) || dom !== expectedHub.cctpDomain) {
    return `ARC_DOMAIN mismatch: expected ${expectedHub.cctpDomain}, got ${domStr}`;
  }
  return null;
}

// ── EXECUTE ONE SPOKE ──────────────────────────────────────────────────────
async function runOneSpoke(
  entry: SpokeStateEntry,
  state: MigrationState,
  targetHub: HubConfig,
  manifest: SpokeManifest,
): { ok: true } | { ok: false; reason: string } {
  const cmd =
    `HUB_RECEIVER=${targetHub.messageReceiver} HUB_DOMAIN=${targetHub.cctpDomain} ` +
    `forge script contracts/script/DeployFxSpoke.s.sol:DeployFxSpoke ` +
    `--rpc-url ${entry.rpc} --broadcast --slow --root contracts`;
  console.log(`  cmd: ${cmd}`);

  entry.attempts += 1;
  entry.status = "pending";
  writeState(state);

  let stdout: string;
  try {
    stdout = execSync(cmd, {
      cwd: REPO_ROOT,
      env: {
        ...process.env,
        HUB_RECEIVER: targetHub.messageReceiver,
        HUB_DOMAIN: String(targetHub.cctpDomain),
      },
      stdio: "pipe",
    }).toString();
  } catch (e) {
    const err = e as { stdout?: Buffer; stderr?: Buffer; message?: string };
    const msg =
      (err.stderr?.toString() || "") +
      (err.stdout?.toString() || "") +
      (err.message || String(e));
    return { ok: false, reason: `forge broadcast failed:\n${msg.slice(0, 1200)}` };
  }

  // Parse the deployed address from the broadcast artifact — authoritative.
  // The earlier stdout-regex approach matched an arbitrary "FxSpoke 0x..."
  // occurrence in forge's trace output (which can echo env-var addresses,
  // setup-tx labels, etc. before the actual deploy log). The broadcast
  // file records the actual CREATE tx with `contractName` + `contractAddress`.
  const broadcastPath = resolve(
    REPO_ROOT,
    `contracts/broadcast/DeployFxSpoke.s.sol/${entry.chainId}/run-latest.json`,
  );
  if (!existsSync(broadcastPath)) {
    return {
      ok: false,
      reason: `forge broadcast succeeded but artifact missing at ${broadcastPath}.`,
    };
  }
  let broadcastJson;
  try {
    broadcastJson = JSON.parse(readFileSync(broadcastPath, "utf8"));
  } catch (e) {
    return {
      ok: false,
      reason: `forge broadcast artifact unparseable: ${e instanceof Error ? e.message : String(e)}`,
    };
  }
  const txs = (broadcastJson.transactions ?? []) as Array<{
    transactionType?: string;
    contractName?: string;
    contractAddress?: string;
  }>;
  const createTx = txs.find(
    (t) => t.transactionType === "CREATE" && t.contractName === "FxSpoke",
  );
  if (!createTx?.contractAddress) {
    return {
      ok: false,
      reason:
        `forge broadcast artifact has no CREATE tx for FxSpoke. ` +
        `Refusing to corrupt the manifest with a placeholder. ` +
        `Transactions: ${JSON.stringify(txs.map((t) => ({ type: t.transactionType, name: t.contractName })))}`,
    };
  }
  const newAddr = createTx.contractAddress as Address;
  console.log(`  parsed new FxSpoke from broadcast artifact: ${newAddr}`);

  // STAGE in state file BEFORE touching the manifest.
  entry.newFxSpoke = newAddr;
  writeState(state);

  // ── ON-CHAIN VERIFICATION ─────────────────────────────────────────────
  console.log(`  verifying HUB_RECEIVER + ARC_DOMAIN on-chain via viem …`);
  const vErr = await verifyDeployedSpoke(newAddr, entry.rpc, targetHub);
  if (vErr) {
    return { ok: false, reason: `verification failed: ${vErr}` };
  }
  console.log(`  verified: HUB_RECEIVER and ARC_DOMAIN match new hub config.`);

  // ── COMMIT to manifest only after verification passes ─────────────────
  manifest.contracts.FxSpoke = newAddr;
  manifest.hub = {
    network: targetHub.network,
    chainId: targetHub.chainId,
    messageReceiver: targetHub.messageReceiver,
    cctpDomain: targetHub.cctpDomain,
  };
  writeFileSync(entry.manifestPath, JSON.stringify(manifest, null, 2) + "\n");
  console.log(`  manifest written: ${entry.manifestPath}`);

  entry.status = "succeeded";
  writeState(state);
  return { ok: true };
}

// ── BUILD WORK SET ─────────────────────────────────────────────────────────
// Returns the list of spokes that actually need migration given the target
// hub config, with the manifest path + RPC resolved.
function buildWorkSet(
  targetHub: HubConfig,
): { path: string; manifest: SpokeManifest; rpc: string }[] {
  const out: { path: string; manifest: SpokeManifest; rpc: string }[] = [];
  for (const { path: p, manifest: m } of loadSpokes()) {
    if (m.chainId === targetHub.chainId) {
      console.log(`  SKIP ${m.network} — same chain as target hub (self-loop)`);
      continue;
    }
    if (m.hub.messageReceiver.toLowerCase() === targetHub.messageReceiver.toLowerCase()) {
      console.log(`  SKIP ${m.network} — already points at target hub`);
      continue;
    }
    const rpc = RPC[m.chainId];
    if (!rpc) {
      console.log(`  SKIP ${m.network} — no public RPC mapped`);
      continue;
    }
    out.push({ path: p, manifest: m, rpc });
  }
  return out;
}

// ── ENTRY POINTS ───────────────────────────────────────────────────────────

async function runDryRun(newHub: HubConfig): Promise<void> {
  const work = buildWorkSet(newHub);
  console.log(`\n${work.length} spokes would be migrated:\n`);
  for (const { manifest: m, rpc } of work) {
    console.log(`  PLAN ${m.network}:`);
    console.log(`        chain  : ${m.chainId}`);
    console.log(`        rpc    : ${rpc}`);
    console.log(`        old FxSpoke: ${m.contracts.FxSpoke}`);
    console.log(`        old hub→     : ${m.hub.network} (domain ${m.hub.cctpDomain})`);
    console.log(`        new hub→     : ${newHub.network} (domain ${newHub.cctpDomain})`);
    const cmd =
      `HUB_RECEIVER=${newHub.messageReceiver} HUB_DOMAIN=${newHub.cctpDomain} ` +
      `forge script contracts/script/DeployFxSpoke.s.sol:DeployFxSpoke ` +
      `--rpc-url ${rpc} --broadcast --slow --root contracts`;
    console.log(`        cmd: ${cmd}\n`);
  }
  console.log("\nDRY RUN. Pass --execute to actually redeploy + update manifests.");
  console.log("Make sure DEPLOYER_PRIVATE_KEY is set and the deployer is funded on every spoke chain.");
}

async function runExecute(newHub: HubConfig, resuming: boolean): Promise<void> {
  console.log(`\nMigrating hub → ${newHub.network} (chainId ${newHub.chainId}, domain ${newHub.cctpDomain})`);
  console.log(`new HUB_RECEIVER: ${newHub.messageReceiver}\n`);

  let state: MigrationState | null = loadState();

  if (resuming) {
    if (!state) fail(`--resume passed but no state file at ${STATE_PATH}.`, 2);
    if (state.newHub.messageReceiver.toLowerCase() !== newHub.messageReceiver.toLowerCase()) {
      fail(
        `--resume hub-config mismatch:\n  state file targets ${state.newHub.messageReceiver}\n  CLI arg passed   ${newHub.messageReceiver}\nRefusing to resume against a different target.`,
        2,
      );
    }
    console.log(`resuming from state ${STATE_PATH} (started ${state.startedAt})\n`);
  } else {
    if (state) {
      fail(
        `Refusing to start a new migration: state file already exists at\n  ${STATE_PATH}\n\n` +
          `Either pass --resume to continue it, --rollback to revert it, ` +
          `or delete the file manually if you know what you're doing.`,
        2,
      );
    }
    const work = buildWorkSet(newHub);
    if (work.length === 0) {
      console.log("Nothing to do — all spokes already point at the target hub.");
      return;
    }
    // Snapshot the OLD hub (taken from the first spoke that has one) so that
    // --rollback can re-target previously-migrated spokes back at it. All
    // pre-migration spokes share the same hub block (it's the singleton
    // hub-of-record), so any of them is fine.
    const previousHub: HubConfig = {
      network: work[0].manifest.hub.network,
      chainId: work[0].manifest.hub.chainId,
      messageReceiver: work[0].manifest.hub.messageReceiver,
      cctpDomain: work[0].manifest.hub.cctpDomain,
      rpcUrl: RPC[work[0].manifest.hub.chainId] ?? "",
    };
    const spokes: Record<string, SpokeStateEntry> = {};
    for (const { path: p, manifest: m, rpc } of work) {
      spokes[String(m.chainId)] = {
        network: m.network,
        chainId: m.chainId,
        manifestPath: p,
        rpc,
        oldFxSpoke: m.contracts.FxSpoke,
        oldHub: { ...m.hub },
        status: "pending",
        attempts: 0,
      };
    }
    state = {
      startedAt: new Date().toISOString(),
      newHub,
      previousHubConfig: previousHub,
      spokes,
    };
    writeState(state);
    console.log(`state file initialized: ${STATE_PATH}\n`);
  }

  // PREFLIGHT all remaining work BEFORE any broadcast.
  const todo = Object.values(state.spokes).filter((e) => e.status !== "succeeded");
  if (todo.length === 0) {
    console.log("All spokes already succeeded according to state file. Nothing to do.");
    return;
  }
  console.log(`preflight (${todo.length} chains):`);
  await preflight(
    todo.map((e) => {
      const m = JSON.parse(readFileSync(e.manifestPath, "utf8")) as SpokeManifest;
      return { path: e.manifestPath, manifest: m, rpc: e.rpc };
    }),
  );

  // Sequential execution. Sequential is the right call here — we want to halt
  // immediately on the first failure rather than fan-out and discover N broken
  // chains at once.
  for (const entry of todo) {
    console.log(`── ${entry.network} (chain ${entry.chainId}) ──`);
    const manifest = JSON.parse(readFileSync(entry.manifestPath, "utf8")) as SpokeManifest;
    const result = await runOneSpoke(entry, state, state.newHub, manifest);
    if (!result.ok) {
      entry.status = "failed";
      entry.lastError = result.reason;
      writeState(state);
      console.error(`\n  FAIL: ${result.reason}\n`);
      console.error(`State file: ${STATE_PATH}`);
      printResume();
      process.exit(2);
    }
    console.log("");
  }

  console.log(`\nAll ${todo.length} spokes migrated successfully.`);
  console.log(`State file kept at ${STATE_PATH} for the audit trail.`);
  console.log(`Delete it manually before starting a new migration.`);
}

async function runRollback(stateFilePath: string): Promise<void> {
  const abs = resolve(process.cwd(), stateFilePath);
  if (!existsSync(abs)) fail(`--rollback: state file not found: ${abs}`, 2);
  const state = JSON.parse(readFileSync(abs, "utf8")) as MigrationState;
  const oldHub = state.previousHubConfig;
  console.log(`\nROLLBACK: re-pointing migrated spokes back at ${oldHub.network} (${oldHub.messageReceiver})`);
  console.log(`From state file: ${abs}\n`);

  // Build a synthetic rollback state in-memory but persist into the same
  // STATE_PATH so subsequent --resume / progress writes work. We overwrite
  // the canonical state file so that one rollback-or-forward path owns it.
  const rollbackSpokes: Record<string, SpokeStateEntry> = {};
  for (const [id, e] of Object.entries(state.spokes)) {
    if (e.status !== "succeeded") {
      console.log(`  SKIP ${e.network} — was ${e.status}, never migrated to new hub`);
      continue;
    }
    rollbackSpokes[id] = {
      network: e.network,
      chainId: e.chainId,
      manifestPath: e.manifestPath,
      rpc: e.rpc,
      oldFxSpoke: e.newFxSpoke ?? e.oldFxSpoke,
      oldHub: state.newHub, // for audit: where we're rolling back FROM
      status: "pending",
      attempts: 0,
    };
  }
  if (Object.keys(rollbackSpokes).length === 0) {
    console.log("\nNothing to roll back — no spokes were marked succeeded.");
    return;
  }
  const rollbackState: MigrationState = {
    startedAt: new Date().toISOString(),
    newHub: oldHub,
    previousHubConfig: state.newHub,
    spokes: rollbackSpokes,
  };
  writeState(rollbackState);
  console.log(`rollback state initialized at ${STATE_PATH}\n`);

  const todo = Object.values(rollbackSpokes);
  console.log(`preflight (${todo.length} chains):`);
  await preflight(
    todo.map((e) => {
      const m = JSON.parse(readFileSync(e.manifestPath, "utf8")) as SpokeManifest;
      return { path: e.manifestPath, manifest: m, rpc: e.rpc };
    }),
  );

  for (const entry of todo) {
    console.log(`── rollback ${entry.network} (chain ${entry.chainId}) ──`);
    const manifest = JSON.parse(readFileSync(entry.manifestPath, "utf8")) as SpokeManifest;
    const result = await runOneSpoke(entry, rollbackState, oldHub, manifest);
    if (!result.ok) {
      entry.status = "failed";
      entry.lastError = result.reason;
      writeState(rollbackState);
      console.error(`\n  ROLLBACK FAIL on ${entry.network}: ${result.reason}\n`);
      console.error(`State file: ${STATE_PATH}`);
      console.error(`To resume the rollback: re-run --rollback with the same state file.\n`);
      process.exit(2);
    }
    console.log("");
  }

  console.log(`\nRollback complete — ${todo.length} spokes now point back at ${oldHub.network}.`);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  // Parse flags first so --rollback can ignore the positional config arg.
  const execute = args.includes("--execute");
  const resume = args.includes("--resume");
  const rollbackIdx = args.indexOf("--rollback");
  const rollback = rollbackIdx !== -1;

  if (rollback) {
    const stateArg = args[rollbackIdx + 1];
    if (!stateArg) {
      console.error("usage: bun migrate-hub.ts <new-hub-config.json> --rollback <state-file>");
      process.exit(1);
    }
    await runRollback(stateArg);
    return;
  }

  const configArg = args.find((a, i) => !a.startsWith("--") && i === 0);
  if (!configArg) {
    console.error("usage: bun migrate-hub.ts <new-hub-config.json> [--execute | --resume | --rollback <state-file>]");
    process.exit(1);
  }
  const newHub: HubConfig = JSON.parse(
    readFileSync(resolve(process.cwd(), configArg), "utf8"),
  );

  if (execute || resume) {
    await runExecute(newHub, resume);
  } else {
    console.log(`\nMigrating hub → ${newHub.network} (chainId ${newHub.chainId}, domain ${newHub.cctpDomain})`);
    console.log(`new HUB_RECEIVER: ${newHub.messageReceiver}\n`);
    await runDryRun(newHub);
  }
}

main().catch((e) => {
  console.error(e instanceof Error ? e.stack ?? e.message : String(e));
  process.exit(2);
});
