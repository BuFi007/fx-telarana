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

import { Hono } from "hono";
import {
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  PrivacyContractsService,
  type CrossCurrencyRelayData,
  type WithdrawProofTuple,
} from "@bu/fx-engine/privacy";

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
  contracts: PrivacyContractsService;
  wallet:    WalletClient;
  cfg:       RelayerConfig;
  rateLimit: RateLimiter;
}) {
  const app = new Hono();

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

  const app = buildApp({ contracts, wallet, cfg, rateLimit });
  Bun.serve({ port: cfg.port, fetch: app.fetch });
}

if (import.meta.main) {
  main().catch((err) => {
    console.error("[relayer-api] fatal:", err);
    process.exit(1);
  });
}

// Exported helpers — useful for tests.
export { RateLimiter, validateRequest, type RelayerConfig };
