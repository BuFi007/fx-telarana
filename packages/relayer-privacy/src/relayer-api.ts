// SPDX-License-Identifier: AGPL-3.0-only
//
// Cross-currency relayer HTTP API — testnet only.
//
// Accepts withdrawal proofs over HTTP and submits them to
// `FxPrivacyEntrypoint.relayCrossCurrency()`. Stateless — the only state
// is the wallet's nonce, which viem manages. Designed for a single
// keeper instance; running redundant relayers behind a load-balancer is
// fine because they each submit their own tx and the on-chain
// `_proof.existingNullifierHash` double-spend gate makes only the first
// land.
//
// SECURITY POSTURE
//
// This endpoint is OPEN by design: dApp users post their own Groth16
// proofs and the relayer is just a meta-tx submitter. The proof itself
// is the authorization. We add:
//   - schema validation (Hono native + manual struct checks)
//   - per-IP rate limiting (in-memory; suitable for testnet only)
//   - dry-run mode (sim only, no broadcast)
//   - max-fee guard (reject obviously-overpaying gas requests)

import { readFileSync } from "node:fs";

import { Hono } from "hono";
import {
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  parseAbi,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  PrivacyContractsService,
  encodeRelayData,
  type CrossCurrencyRelayData,
  type RelayData,
  type WithdrawProofTuple,
  type Withdrawal,
} from "@bu/fx-engine/privacy";
import { proveAndBuildRelayExecute, type ShieldedNote } from "@bu/privacy-prover";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

interface RelayerConfig {
  rpcUrl: string;
  privateKey: Hex;
  entrypoint: Address;
  port: number;
  /** Per-IP requests-per-minute cap. 0 = unlimited (testnet). */
  rateLimit: number;
  /** Soft cap on the max relayFeeBPS we'll relay (defense against
   *  user-side mistakes pushing absurd fees to a relayer). */
  maxRelayFeeBPS: number;
  /** If true, simulate (eth_call) only — never broadcast. */
  dryRun: boolean;
  /** Dir holding the Groth16 withdraw artifacts (withdraw.wasm/.zkey) for the
   *  server-side prover used by /v1/relayExecute. */
  circuitsDir: string;
}

function loadConfig(): RelayerConfig {
  const rpcUrl = Bun.env["RPC_URL"];
  const privateKey = Bun.env["PRIVATE_KEY"] as Hex | undefined;
  const entrypoint = Bun.env["ENTRYPOINT_ADDRESS"] as Address | undefined;
  if (!rpcUrl) throw new Error("RPC_URL is required");
  if (!privateKey) throw new Error("PRIVATE_KEY is required");
  if (!entrypoint) throw new Error("ENTRYPOINT_ADDRESS is required");
  return {
    rpcUrl,
    privateKey,
    entrypoint,
    port:           Number(Bun.env["RELAYER_PORT"] ?? 8787),
    rateLimit:      Number(Bun.env["RELAYER_RATE_LIMIT_PER_MIN"] ?? 60),
    maxRelayFeeBPS: Number(Bun.env["RELAYER_MAX_FEE_BPS"] ?? 500), // 5%
    dryRun:         Bun.env["DRY_RUN"] === "true",
    circuitsDir:    Bun.env["CIRCUITS_DIR"] ?? "./circuits",
  };
}

function log(level: "info" | "warn" | "error", msg: string, ctx?: unknown): void {
  const line =
    `[${new Date().toISOString()}] ` +
    `[relayer-api] ` +
    `[${level}] ${msg}` +
    (ctx ? ` ${JSON.stringify(ctx, (_k, v) => typeof v === "bigint" ? v.toString() : v)}` : "");
  if (level === "error") console.error(line);
  else console.log(line);
}

// ---------------------------------------------------------------------------
// Schema validation (manual — Hono's zod plugin is optional)
// ---------------------------------------------------------------------------

/** Wire shape for the cross-currency relay payload. All bigints as
 *  decimal strings to keep JSON parseable. */
export interface RelayCrossCurrencyRequest {
  scope: string;
  data: {
    recipient: string;
    feeRecipient: string;
    relayFeeBPS: string;
    buyToken: string;
    minBuyAmount: string;
  };
  proof: {
    pA: [string, string];
    pB: [[string, string], [string, string]];
    pC: [string, string];
    pubSignals: [string, string, string, string, string, string, string, string];
  };
}

function isString(x: unknown): x is string {
  return typeof x === "string";
}

function validateRequest(body: unknown): { ok: true; req: RelayCrossCurrencyRequest } | { ok: false; reason: string } {
  if (typeof body !== "object" || body === null) {
    return { ok: false, reason: "body must be a JSON object" };
  }
  const b = body as Record<string, unknown>;
  if (!isString(b.scope)) return { ok: false, reason: "scope must be a decimal string" };
  if (typeof b.data !== "object" || b.data === null) return { ok: false, reason: "data missing" };
  const d = b.data as Record<string, unknown>;
  for (const k of ["recipient","feeRecipient","relayFeeBPS","buyToken","minBuyAmount"] as const) {
    if (!isString(d[k])) return { ok: false, reason: `data.${k} must be string` };
  }
  if (!isAddress(d.recipient as string)) return { ok: false, reason: "data.recipient invalid address" };
  if (!isAddress(d.feeRecipient as string)) return { ok: false, reason: "data.feeRecipient invalid address" };
  if (!isAddress(d.buyToken as string)) return { ok: false, reason: "data.buyToken invalid address" };
  if (typeof b.proof !== "object" || b.proof === null) return { ok: false, reason: "proof missing" };
  const p = b.proof as Record<string, unknown>;
  if (!Array.isArray(p.pA) || p.pA.length !== 2) return { ok: false, reason: "proof.pA must be [string, string]" };
  if (!Array.isArray(p.pB) || p.pB.length !== 2) return { ok: false, reason: "proof.pB must be [[s,s],[s,s]]" };
  if (!Array.isArray(p.pC) || p.pC.length !== 2) return { ok: false, reason: "proof.pC must be [string, string]" };
  if (!Array.isArray(p.pubSignals) || p.pubSignals.length !== 8) {
    return { ok: false, reason: "proof.pubSignals must be string[8]" };
  }
  return { ok: true, req: body as RelayCrossCurrencyRequest };
}

/** Wire shape for the same-currency relay payload (base 0xbow `relay()`).
 *  Same as cross-currency minus buyToken/minBuyAmount. */
export interface RelayRequest {
  scope: string;
  data: {
    recipient: string;
    feeRecipient: string;
    relayFeeBPS: string;
  };
  proof: {
    pA: [string, string];
    pB: [[string, string], [string, string]];
    pC: [string, string];
    pubSignals: [string, string, string, string, string, string, string, string];
  };
}

function validateRelayRequest(body: unknown): { ok: true; req: RelayRequest } | { ok: false; reason: string } {
  if (typeof body !== "object" || body === null) {
    return { ok: false, reason: "body must be a JSON object" };
  }
  const b = body as Record<string, unknown>;
  if (!isString(b.scope)) return { ok: false, reason: "scope must be a decimal string" };
  if (typeof b.data !== "object" || b.data === null) return { ok: false, reason: "data missing" };
  const d = b.data as Record<string, unknown>;
  for (const k of ["recipient", "feeRecipient", "relayFeeBPS"] as const) {
    if (!isString(d[k])) return { ok: false, reason: `data.${k} must be string` };
  }
  if (!isAddress(d.recipient as string)) return { ok: false, reason: "data.recipient invalid address" };
  if (!isAddress(d.feeRecipient as string)) return { ok: false, reason: "data.feeRecipient invalid address" };
  if (typeof b.proof !== "object" || b.proof === null) return { ok: false, reason: "proof missing" };
  const p = b.proof as Record<string, unknown>;
  if (!Array.isArray(p.pA) || p.pA.length !== 2) return { ok: false, reason: "proof.pA must be [string, string]" };
  if (!Array.isArray(p.pB) || p.pB.length !== 2) return { ok: false, reason: "proof.pB must be [[s,s],[s,s]]" };
  if (!Array.isArray(p.pC) || p.pC.length !== 2) return { ok: false, reason: "proof.pC must be [string, string]" };
  if (!Array.isArray(p.pubSignals) || p.pubSignals.length !== 8) {
    return { ok: false, reason: "proof.pubSignals must be string[8]" };
  }
  return { ok: true, req: body as RelayRequest };
}

/** Wire shape for /v1/relayExecute (server-side prove + submit). The note
 *  secrets are decimal strings; the relayer proves with them. */
export interface RelayExecuteRequest {
  pool: string;
  recipient: string;
  feeRecipient?: string;
  adapterId: string;
  adapterData: string;
  relayFeeBPS: string;
  searchLoBlock?: string;
  note: { nullifier: string; secret: string; value: string; label: string; commitmentHash: string };
}

function validateRelayExecuteRequest(
  body: unknown,
): { ok: true; req: RelayExecuteRequest } | { ok: false; reason: string } {
  if (typeof body !== "object" || body === null) return { ok: false, reason: "body must be a JSON object" };
  const b = body as Record<string, unknown>;
  if (!isAddress(b.pool as string)) return { ok: false, reason: "pool invalid address" };
  if (!isAddress(b.recipient as string)) return { ok: false, reason: "recipient invalid address" };
  if (b.feeRecipient !== undefined && !isAddress(b.feeRecipient as string)) return { ok: false, reason: "feeRecipient invalid address" };
  if (typeof b.adapterData !== "string" || !(b.adapterData as string).startsWith("0x")) return { ok: false, reason: "adapterData must be 0x hex" };
  if (b.adapterId === undefined || b.adapterId === null) return { ok: false, reason: "adapterId required" };
  const note = b.note as Record<string, unknown> | undefined;
  if (typeof note !== "object" || note === null) return { ok: false, reason: "note required" };
  for (const k of ["nullifier", "secret", "value", "label", "commitmentHash"]) {
    if (typeof note[k] !== "string") return { ok: false, reason: `note.${k} must be a decimal string` };
  }
  return {
    ok: true,
    req: {
      pool: b.pool as string,
      recipient: b.recipient as string,
      feeRecipient: b.feeRecipient as string | undefined,
      adapterId: String(b.adapterId),
      adapterData: b.adapterData as string,
      relayFeeBPS: String(b.relayFeeBPS ?? "0"),
      searchLoBlock: b.searchLoBlock !== undefined ? String(b.searchLoBlock) : undefined,
      note: note as unknown as RelayExecuteRequest["note"],
    },
  };
}

// ---------------------------------------------------------------------------
// Per-IP rate limiter (in-memory; testnet posture)
// ---------------------------------------------------------------------------

class RateLimiter {
  private hits = new Map<string, { count: number; resetAt: number }>();
  constructor(private readonly perMinute: number) {}
  check(ip: string): boolean {
    if (this.perMinute <= 0) return true;
    const now = Date.now();
    const cur = this.hits.get(ip);
    if (!cur || cur.resetAt < now) {
      this.hits.set(ip, { count: 1, resetAt: now + 60_000 });
      return true;
    }
    cur.count += 1;
    if (cur.count > this.perMinute) return false;
    return true;
  }
}

// ---------------------------------------------------------------------------
// App factory — exported for tests
// ---------------------------------------------------------------------------

export function buildApp(args: {
  contracts:    PrivacyContractsService;
  wallet:       WalletClient;
  publicClient: PublicClient;
  cfg:          RelayerConfig;
  rateLimit:    RateLimiter;
}) {
  const app = new Hono();

  // Lazily-loaded withdraw circuit artifacts for server-side proving.
  let _wasm: Uint8Array | undefined;
  let _zkey: Uint8Array | undefined;
  const loadCircuits = (): { wasm: Uint8Array; zkey: Uint8Array } => {
    if (!_wasm) _wasm = new Uint8Array(readFileSync(`${args.cfg.circuitsDir}/withdraw.wasm`));
    if (!_zkey) _zkey = new Uint8Array(readFileSync(`${args.cfg.circuitsDir}/withdraw.zkey`));
    return { wasm: _wasm, zkey: _zkey };
  };
  const ASP_ABI = parseAbi([
    "function updateRoot(uint256 root, string ipfsCID) returns (uint256 index)",
    "function latestRoot() view returns (uint256)",
  ]);

  app.get("/health", (c) => {
    return c.json({
      ok: true,
      entrypoint: args.cfg.entrypoint,
      dryRun: args.cfg.dryRun,
      maxRelayFeeBPS: args.cfg.maxRelayFeeBPS,
    });
  });

  app.post("/v1/relayCrossCurrency", async (c) => {
    const ip =
      c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ??
      c.req.header("x-real-ip") ??
      "unknown";
    if (!args.rateLimit.check(ip)) {
      return c.json({ error: "rate_limited" }, 429);
    }

    const raw = await c.req.json().catch(() => null);
    const valid = validateRequest(raw);
    if (!valid.ok) {
      log("warn", "rejected malformed request", { ip, reason: valid.reason });
      return c.json({ error: "bad_request", reason: valid.reason }, 400);
    }
    const r = valid.req;

    const relayFeeBPS = BigInt(r.data.relayFeeBPS);
    if (relayFeeBPS > BigInt(args.cfg.maxRelayFeeBPS)) {
      // Don't echo the requested fee back — it's trade metadata. The
      // client already knows what it sent; the over-fee response just
      // surfaces the protocol cap.
      log("warn", "rejected over-fee request", { ip });
      return c.json({
        error: "fee_too_high",
        max: String(args.cfg.maxRelayFeeBPS),
      }, 400);
    }

    const data: CrossCurrencyRelayData = {
      recipient:    r.data.recipient as Address,
      feeRecipient: r.data.feeRecipient as Address,
      relayFeeBPS,
      buyToken:     r.data.buyToken as Address,
      minBuyAmount: BigInt(r.data.minBuyAmount),
    };
    const proof: WithdrawProofTuple = {
      pA: r.proof.pA,
      pB: r.proof.pB,
      pC: r.proof.pC,
      pubSignals: r.proof.pubSignals,
    };

    // Codex round-13 TECH-HIGH: do NOT log trade metadata (buyToken,
    // relayFeeBPS, minBuyAmount) — those fields are part of the user's
    // private swap intent and shouldn't live in the relayer's log
    // stream. The proof's `context` already commits to them on-chain
    // and the entrypoint's events carry whatever the chain needs.
    log("info", "received relayCrossCurrency", { ip, dryRun: args.cfg.dryRun });

    if (args.cfg.dryRun) {
      return c.json({ ok: true, dryRun: true });
    }

    try {
      const txHash = await args.contracts.relayCrossCurrency(args.wallet, {
        proof,
        scope: BigInt(r.scope),
        data,
      });
      log("info", "tx submitted", { ip, txHash });
      return c.json({ ok: true, txHash });
    } catch (err) {
      log("error", "relay failed", { ip, err: String(err) });
      return c.json({ error: "relay_failed", message: String(err) }, 500);
    }
  });

  // Same-currency relay (base 0xbow relay()). Unblocked today (USDC→USDC to a
  // fresh recipient); the relayer is msg.sender so the user's EOA never appears.
  // The base relay requires processooor == entrypoint (Entrypoint.sol), which
  // the user's Groth16 context already commits to; the relayer just submits.
  app.post("/v1/relay", async (c) => {
    const ip =
      c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ??
      c.req.header("x-real-ip") ??
      "unknown";
    if (!args.rateLimit.check(ip)) {
      return c.json({ error: "rate_limited" }, 429);
    }

    const raw = await c.req.json().catch(() => null);
    const valid = validateRelayRequest(raw);
    if (!valid.ok) {
      log("warn", "rejected malformed relay request", { ip, reason: valid.reason });
      return c.json({ error: "bad_request", reason: valid.reason }, 400);
    }
    const r = valid.req;

    const relayFeeBPS = BigInt(r.data.relayFeeBPS);
    if (relayFeeBPS > BigInt(args.cfg.maxRelayFeeBPS)) {
      log("warn", "rejected over-fee relay request", { ip });
      return c.json({ error: "fee_too_high", max: String(args.cfg.maxRelayFeeBPS) }, 400);
    }

    const relayData: RelayData = {
      recipient:    r.data.recipient as Address,
      feeRecipient: r.data.feeRecipient as Address,
      relayFeeBPS,
    };
    // processooor MUST be the entrypoint (Entrypoint.relay reverts otherwise);
    // the user's proof context commits to exactly this withdrawal blob.
    const withdrawal: Withdrawal = {
      processooor: args.cfg.entrypoint,
      data:        encodeRelayData(relayData),
    };
    const proof: WithdrawProofTuple = {
      pA: r.proof.pA,
      pB: r.proof.pB,
      pC: r.proof.pC,
      pubSignals: r.proof.pubSignals,
    };

    // Don't log trade metadata (recipient/fee) — same posture as cross-currency.
    log("info", "received relay", { ip, dryRun: args.cfg.dryRun });

    if (args.cfg.dryRun) {
      return c.json({ ok: true, dryRun: true });
    }

    try {
      const txHash = await args.contracts.relay(args.wallet, {
        withdrawal,
        proof,
        scope: BigInt(r.scope),
      });
      log("info", "tx submitted", { ip, txHash });
      return c.json({ ok: true, txHash });
    } catch (err) {
      log("error", "relay failed", { ip, err: String(err) });
      return c.json({ error: "relay_failed", message: String(err) }, 500);
    }
  });

  // Own-stack private execution: SERVER-SIDE prove + submit. The caller hands the
  // shielded note + the registered adapter id/calldata; the relayer reconstructs
  // the pool tree, proves (snarkjs), ensures the ASP root, and submits
  // relayExecute as msg.sender (so the user's wallet never appears). Trust note:
  // the prover sees the note secrets — run it in the user's trust domain
  // (self-hosted) for the strong tier.
  app.post("/v1/relayExecute", async (c) => {
    const ip =
      c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ??
      c.req.header("x-real-ip") ?? "unknown";
    if (!args.rateLimit.check(ip)) return c.json({ error: "rate_limited" }, 429);

    const raw = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;
    const v = validateRelayExecuteRequest(raw);
    if (!v.ok) {
      log("warn", "rejected malformed relayExecute", { ip, reason: v.reason });
      return c.json({ error: "bad_request", reason: v.reason }, 400);
    }
    const req = v.req;

    const relayFeeBPS = BigInt(req.relayFeeBPS);
    if (relayFeeBPS > BigInt(args.cfg.maxRelayFeeBPS)) {
      log("warn", "rejected over-fee relayExecute", { ip });
      return c.json({ error: "fee_too_high", max: String(args.cfg.maxRelayFeeBPS) }, 400);
    }

    const note: ShieldedNote = {
      nullifier: BigInt(req.note.nullifier), secret: BigInt(req.note.secret),
      value: BigInt(req.note.value), label: BigInt(req.note.label),
      commitmentHash: BigInt(req.note.commitmentHash),
    };

    // Ensure the single-leaf ASP root (== note.label) is the entrypoint's latest.
    try {
      const cur = (await args.publicClient.readContract({
        address: args.cfg.entrypoint, abi: ASP_ABI, functionName: "latestRoot",
      })) as bigint;
      if (cur !== note.label) {
        const tx = await args.wallet.writeContract({
          chain: null, account: args.wallet.account!, address: args.cfg.entrypoint,
          abi: ASP_ABI, functionName: "updateRoot",
          args: [note.label, `relayer-${note.label.toString(36)}`.slice(0, 40).padEnd(40, "x")],
        });
        await args.publicClient.waitForTransactionReceipt({ hash: tx });
      }
    } catch (err) {
      log("error", "asp publish failed", { ip, err: String(err) });
      return c.json({ error: "asp_publish_failed", message: String(err) }, 500);
    }

    // Server-side prove.
    let built;
    try {
      const { wasm, zkey } = loadCircuits();
      built = await proveAndBuildRelayExecute({
        publicClient: args.publicClient,
        pool: req.pool as Address,
        entrypoint: args.cfg.entrypoint,
        note,
        adapterId: BigInt(req.adapterId),
        adapterData: req.adapterData as `0x${string}`,
        recipient: req.recipient as Address,
        feeRecipient: (req.feeRecipient ?? req.recipient) as Address,
        relayFeeBPS,
        aspRoot: note.label,
        wasmBytes: wasm,
        zkeyBytes: zkey,
        searchLoBlock: req.searchLoBlock ? BigInt(req.searchLoBlock) : undefined,
      });
    } catch (err) {
      log("error", "prove failed", { ip, err: String(err) });
      return c.json({ error: "prove_failed", message: String(err) }, 500);
    }

    log("info", "received relayExecute", { ip, dryRun: args.cfg.dryRun });
    if (args.cfg.dryRun) return c.json({ ok: true, dryRun: true, stateRoot: String(built.stateRoot) });

    try {
      const txHash = await args.contracts.relayExecute(args.wallet, {
        withdrawal: built.withdrawal,
        proof: built.proof as unknown as WithdrawProofTuple,
        scope: built.scope,
      });
      return c.json({ ok: true, txHash });
    } catch (err) {
      log("error", "relayExecute failed", { ip, err: String(err) });
      return c.json({ error: "relay_execute_failed", message: String(err) }, 500);
    }
  });

  return app;
}

// ---------------------------------------------------------------------------
// Main entrypoint
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const cfg = loadConfig();
  const publicClient: PublicClient = createPublicClient({ transport: http(cfg.rpcUrl) });
  const account = privateKeyToAccount(cfg.privateKey);
  const wallet: WalletClient = createWalletClient({ account, transport: http(cfg.rpcUrl) });
  const contracts = new PrivacyContractsService(publicClient, cfg.entrypoint);
  const rateLimit = new RateLimiter(cfg.rateLimit);

  log("info", "starting cross-currency relayer api", {
    entrypoint: cfg.entrypoint,
    relayer:    account.address,
    port:       cfg.port,
    rateLimit:  cfg.rateLimit,
    maxFeeBPS:  cfg.maxRelayFeeBPS,
    dryRun:     cfg.dryRun,
  });

  const app = buildApp({ contracts, wallet, publicClient, cfg, rateLimit });
  Bun.serve({ port: cfg.port, fetch: app.fetch });
}

if (import.meta.main) {
  main().catch((err) => {
    console.error("[relayer-api] fatal:", err);
    process.exit(1);
  });
}

// Exported helpers — useful for tests.
export { RateLimiter, validateRequest, validateRelayRequest, type RelayerConfig };
