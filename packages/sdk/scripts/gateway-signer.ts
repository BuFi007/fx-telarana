#!/usr/bin/env bun
// SPDX-License-Identifier: Apache-2.0
/**
 * Telaraña Gateway signer — off-chain BurnIntent service.
 *
 * Watches `FxGatewayHook.LockedForRemote` events on both hubs (Fuji + Arc),
 * builds a BurnIntent with the remote hook as the destinationCaller (so only
 * our hook can claim the attestation), signs the intent with our deployer
 * EOA, POSTs to Circle's Gateway operator API, and emits the attestation
 * payload + signature so the destination hub can call
 * `FxGatewayHook.mintFromRemote(...)`.
 *
 * One-shot CLI modes:
 *   info                                  — Circle API /info, supported chains
 *   balances [address]                    — Gateway balance of authority (default: deployer) on both routes
 *   sign-and-attest <route-id> <amount>   — build + sign + POST one burn intent. Amount in USDC atomic units (6-dec).
 *   watch                                 — daemon: stream LockedForRemote events, sign each, append attestation to report
 *
 * Required env (load via .env.local):
 *   DEPLOYER_PRIVATE_KEY                  — EOA that signs BurnIntents (until 1271 lands mid-July)
 *
 * Optional env:
 *   FUJI_RPC_URL                          — default https://api.avax-test.network/ext/bc/C/rpc
 *   ARC_RPC_URL                           — default https://rpc.testnet.arc.network
 *   GATEWAY_SIGNER_OUT                    — path for watch-mode jsonl output, default reports/gateway-attestations.jsonl
 *   GATEWAY_API_BASE                      — override Circle's API base (default: testnet)
 *
 * Route IDs come from packages/sdk/src/gateway.ts → TELARANA_GATEWAY_HUB_ROUTES.
 */
import { readFileSync, appendFileSync, mkdirSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  pad,
  maxUint256,
  type Address,
  type Hex,
  type Log,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  buildGatewayBurnIntent,
  gatewayBurnIntentToJson,
  TELARANA_GATEWAY_HUB_ROUTES,
  GATEWAY_EIP712_DOMAIN,
  GATEWAY_EIP712_TYPES,
  CIRCLE_GATEWAY_TESTNET_API,
  type GatewayHubRouteConfig,
  type GatewayBurnIntent,
} from "../src/gateway.js";
import { ChainId } from "../src/addresses/index.js";

// ── REPO HELPERS ──────────────────────────────────────────────────────────

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

function loadHubConfig(network: "fuji" | "arc") {
  const path = resolve(REPO_ROOT, `deployments/hub-config-${network}.json`);
  return JSON.parse(readFileSync(path, "utf8")) as {
    chainId: number;
    messageReceiver: Address;
    rpcUrl: string;
    hubStack: { FxGatewayHook: Address; FxHubMessageReceiver: Address };
    external: { USDC: Address; GatewayWallet: Address; GatewayMinter: Address };
    gateway: { authority: Address };
  };
}

// ── MIN ABIS ──────────────────────────────────────────────────────────────

const FX_GATEWAY_HOOK_ABI = parseAbi([
  "event LockedForRemote(uint256 amount, address indexed authority)",
  "event MintedFromRemote(uint256 amount, address indexed forwardedTo)",
  "function HUB() view returns (address)",
  "function GATEWAY_WALLET() view returns (address)",
  "function authority() view returns (address)",
  "function gatewayBalance() view returns (uint256)",
]);

// ── ROUTE + CLIENT SETUP ──────────────────────────────────────────────────

type ChainCtx = {
  routeOut: GatewayHubRouteConfig;
  routeIn: GatewayHubRouteConfig;
  rpcUrl: string;
  client: PublicClient;
  hook: Address;
  hubReceiver: Address;
  remoteHook: Address;
};

function getRpcUrl(chainId: number): string {
  if (chainId === ChainId.AvalancheFuji) {
    return process.env.FUJI_RPC_URL ?? "https://api.avax-test.network/ext/bc/C/rpc";
  }
  if (chainId === ChainId.ArcTestnet) {
    return process.env.ARC_RPC_URL ?? "https://rpc.testnet.arc.network";
  }
  throw new Error(`No RPC url known for chainId ${chainId}`);
}

function ctxForChain(chainId: number): ChainCtx {
  const routeOut = TELARANA_GATEWAY_HUB_ROUTES.find(
    (r) => r.sourceHubChainId === chainId,
  );
  const routeIn = TELARANA_GATEWAY_HUB_ROUTES.find(
    (r) => r.destinationHubChainId === chainId,
  );
  if (!routeOut || !routeIn) {
    throw new Error(`No gateway route configured for chainId ${chainId}`);
  }

  const cfgKey = chainId === ChainId.AvalancheFuji ? "fuji" : "arc";
  const cfg = loadHubConfig(cfgKey);
  const remoteCfg = loadHubConfig(cfgKey === "fuji" ? "arc" : "fuji");

  const rpcUrl = getRpcUrl(chainId);
  const client = createPublicClient({ transport: http(rpcUrl) });

  return {
    routeOut,
    routeIn,
    rpcUrl,
    client,
    hook: cfg.hubStack.FxGatewayHook,
    hubReceiver: cfg.hubStack.FxHubMessageReceiver,
    remoteHook: remoteCfg.hubStack.FxGatewayHook,
  };
}

// ── CIRCLE API CLIENT ─────────────────────────────────────────────────────

const API_BASE = process.env.GATEWAY_API_BASE ?? CIRCLE_GATEWAY_TESTNET_API;

async function apiGet<T>(path: string): Promise<T> {
  const r = await fetch(`${API_BASE}${path}`);
  if (!r.ok) {
    throw new Error(`Gateway API ${path} failed: ${r.status} ${await r.text()}`);
  }
  return (await r.json()) as T;
}

async function apiPost<T>(path: string, body: unknown): Promise<T> {
  const r = await fetch(`${API_BASE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body, (_k, v) => (typeof v === "bigint" ? v.toString() : v)),
  });
  if (!r.ok) {
    throw new Error(`Gateway API ${path} failed: ${r.status} ${await r.text()}`);
  }
  return (await r.json()) as T;
}

// ── BURN-INTENT EIP-712 TYPED-DATA ────────────────────────────────────────

function burnIntentTypedData(intent: GatewayBurnIntent) {
  return {
    domain: GATEWAY_EIP712_DOMAIN,
    types: GATEWAY_EIP712_TYPES,
    primaryType: "BurnIntent" as const,
    message: {
      maxBlockHeight: intent.maxBlockHeight,
      maxFee: intent.maxFee,
      spec: intent.spec,
    },
  };
}

// ── INTENT BUILDERS ────────────────────────────────────────────────────────

type SignedIntentBundle = {
  routeId: string;
  intent: ReturnType<typeof gatewayBurnIntentToJson>;
  signature: Hex;
};

async function buildAndSignIntent(input: {
  routeId: "gateway-fuji-to-arc-usdc" | "gateway-arc-to-fuji-usdc";
  amountAtomic: bigint;
  signerPk: Hex;
  /// When true: destinationCaller=0 (anyone can mint) and destinationRecipient=
  /// deployer-on-dest. Used for live-testnet smoke runs that don't yet route
  /// through FxGatewayHook (because hook is hub-only and Stage 6 plumbing
  /// isn't deployed yet). Skip for production paths.
  bypassHook?: boolean;
  /// Override the destination contract for the BurnIntent. Used to target
  /// `TelaranaGatewayHubHook` (spot-FX path) instead of `FxGatewayHook`
  /// (mint-to-hub path). Sets both destinationCaller and destinationRecipient.
  /// Takes precedence over `bypassHook`.
  destinationOverride?: Address;
}): Promise<SignedIntentBundle> {
  const route = TELARANA_GATEWAY_HUB_ROUTES.find((r) => r.routeId === input.routeId);
  if (!route) throw new Error(`Unknown route: ${input.routeId}`);

  // The destination hook on the OTHER chain is who we lock the mint to.
  const destCtx = ctxForChain(route.destinationHubChainId as number);

  const account = privateKeyToAccount(input.signerPk);
  const salt = ("0x" + randomBytes(32).toString("hex")) as Hex;

  let destinationRecipient: Address;
  let destinationCaller: Address;
  if (input.destinationOverride) {
    destinationRecipient = input.destinationOverride;
    destinationCaller = input.destinationOverride;
  } else if (input.bypassHook) {
    destinationRecipient = account.address;
    destinationCaller = "0x0000000000000000000000000000000000000000" as Address;
  } else {
    destinationRecipient = destCtx.hook;
    destinationCaller = destCtx.hook;
  }

  const intent = buildGatewayBurnIntent({
    route,
    amount: input.amountAtomic,
    sourceDepositor: account.address,
    sourceSigner: account.address,
    destinationRecipient,
    destinationCaller,
    maxBlockHeight: maxUint256,
    salt,
    hookData: "0x",
  });

  const typed = burnIntentTypedData(intent);
  // viem's signTypedData rejects extra keys in `types`; manually trim to the
  // primaryType's transitive deps. GATEWAY_EIP712_TYPES already only has TransferSpec + BurnIntent.
  const signature = await account.signTypedData({
    domain: typed.domain,
    types: typed.types,
    primaryType: typed.primaryType,
    message: typed.message as never,
  });

  return {
    routeId: route.routeId,
    intent: gatewayBurnIntentToJson(intent),
    signature,
  };
}

// ── CIRCLE TRANSFER ───────────────────────────────────────────────────────

type TransferResponse =
  | { success?: true; attestation: Hex; signature: Hex }
  | { success: false; message: string };

async function requestAttestation(bundle: SignedIntentBundle): Promise<{
  attestation: Hex;
  signature: Hex;
  latencyMs: number;
}> {
  const start = performance.now();
  const body = [
    {
      burnIntent: {
        ...bundle.intent,
        maxBlockHeight: bundle.intent.maxBlockHeight,
        maxFee: bundle.intent.maxFee,
        spec: {
          ...bundle.intent.spec,
          // Wire format wants bytes32 fields padded — buildGatewayBurnIntent already pads them.
          // Value stays as a numeric string (handled by replacer in apiPost).
        },
      },
      signature: bundle.signature,
    },
  ];

  const r = await apiPost<TransferResponse>("/transfer", body);
  const latencyMs = performance.now() - start;

  if ("success" in r && r.success === false) {
    throw new Error(`Circle Gateway rejected intent: ${r.message}`);
  }
  if (!("attestation" in r) || !("signature" in r)) {
    throw new Error(`Unexpected response shape: ${JSON.stringify(r)}`);
  }
  return { attestation: r.attestation, signature: r.signature, latencyMs };
}

// ── COMMANDS ──────────────────────────────────────────────────────────────

async function cmdInfo() {
  const info = await apiGet<{
    domains: Array<{ domain: number; chain: string; network: string }>;
  }>("/info");
  console.log("Circle Gateway API:", API_BASE);
  console.log("Supported domains:");
  for (const d of info.domains) {
    console.log(`  - domain=${d.domain} ${d.chain} (${d.network})`);
  }
  console.log("\nTelaraña hub routes configured:");
  for (const r of TELARANA_GATEWAY_HUB_ROUTES) {
    console.log(`  - ${r.routeId} (domain ${r.sourceDomain} → ${r.destinationDomain})`);
  }
}

async function cmdBalances(account?: string) {
  const addr = (account ?? process.env.GATEWAY_AUTHORITY ?? "") as Address;
  if (!addr) {
    const pk = process.env.DEPLOYER_PRIVATE_KEY as Hex;
    if (!pk) throw new Error("Set DEPLOYER_PRIVATE_KEY or pass an address");
    const a = privateKeyToAccount(pk).address;
    console.log(`Resolved authority from DEPLOYER_PRIVATE_KEY: ${a}`);
    return cmdBalances(a);
  }
  console.log(`Authority: ${addr}`);
  type B = {
    balances: Array<{ domain: number; balance: string }>;
  };
  const r = await apiPost<B>("/balances", {
    token: "USDC",
    sources: TELARANA_GATEWAY_HUB_ROUTES.map((rt) => ({
      depositor: addr,
      domain: rt.sourceDomain,
    })).filter((s, i, arr) => arr.findIndex((x) => x.domain === s.domain) === i),
  });
  for (const b of r.balances ?? []) {
    console.log(`  domain=${b.domain}  ${b.balance} USDC`);
  }
}

async function cmdSignAndAttest(
  routeId: string,
  amountAtomicStr: string,
  bypass: boolean,
  destinationOverride?: Address,
) {
  const pk = (process.env.DEPLOYER_PRIVATE_KEY ?? "") as Hex;
  if (!pk) throw new Error("DEPLOYER_PRIVATE_KEY not set");
  const amountAtomic = BigInt(amountAtomicStr);

  const label = destinationOverride
    ? ` [target=${destinationOverride}]`
    : bypass
      ? " [BYPASS hook]"
      : "";
  console.log(`Building burn intent for route ${routeId}, amount ${amountAtomicStr} (atomic)${label}`);
  const bundle = await buildAndSignIntent({
    routeId: routeId as never,
    amountAtomic,
    signerPk: pk,
    bypassHook: bypass,
    destinationOverride,
  });
  console.log(`Signed by ${privateKeyToAccount(pk).address}`);
  console.log(`Signature: ${bundle.signature.slice(0, 20)}…${bundle.signature.slice(-10)}`);

  console.log(`POST /transfer to ${API_BASE} …`);
  const { attestation, signature, latencyMs } = await requestAttestation(bundle);
  console.log(`Attestation received in ${latencyMs.toFixed(0)}ms`);
  console.log(`  attestation payload (${attestation.length} chars): ${attestation.slice(0, 40)}…`);
  console.log(`  attestation signature: ${signature.slice(0, 40)}…`);
  console.log("");
  console.log("Next: on the destination hub, call");
  console.log(`  FxGatewayHook.mintFromRemote(attestationPayload, signature)`);
  console.log("(must be called BY the local hub receiver — see Stage 6 plumbing TODO).");
  console.log("");
  console.log("Full attestation payload (paste into cast):");
  console.log(attestation);
  console.log("");
  console.log("Full attestation signature:");
  console.log(signature);
}

async function cmdWatch() {
  const pk = (process.env.DEPLOYER_PRIVATE_KEY ?? "") as Hex;
  if (!pk) throw new Error("DEPLOYER_PRIVATE_KEY not set");

  const out = process.env.GATEWAY_SIGNER_OUT ?? "reports/gateway-attestations.jsonl";
  const outAbs = resolve(REPO_ROOT, out);
  mkdirSync(dirname(outAbs), { recursive: true });
  if (!existsSync(outAbs)) {
    appendFileSync(outAbs, "");
  }

  console.log(`Watch mode — appending to ${outAbs}`);
  console.log(`Signer: ${privateKeyToAccount(pk).address}`);
  console.log("");

  const fujiCtx = ctxForChain(ChainId.AvalancheFuji);
  const arcCtx = ctxForChain(ChainId.ArcTestnet);

  console.log(`Watching ${fujiCtx.hook} (Fuji hook → Arc) and ${arcCtx.hook} (Arc hook → Fuji)`);

  const startFromBlockFuji = await fujiCtx.client.getBlockNumber();
  const startFromBlockArc = await arcCtx.client.getBlockNumber();

  const handleEvent = async (sourceChainId: number, log: Log) => {
    try {
      // Decode via parseAbi
      const decoded = (log as Log & { args?: { amount?: bigint; authority?: Address } }).args;
      if (!decoded?.amount) {
        console.warn(`[watch] event with no amount: ${log.transactionHash}`);
        return;
      }
      const routeId =
        sourceChainId === ChainId.AvalancheFuji
          ? "gateway-fuji-to-arc-usdc"
          : "gateway-arc-to-fuji-usdc";
      console.log(`\n[watch] LockedForRemote on ${sourceChainId} amount=${decoded.amount} authority=${decoded.authority}`);
      console.log(`[watch] Building+signing burn intent for ${routeId} …`);
      const bundle = await buildAndSignIntent({
        routeId: routeId as never,
        amountAtomic: decoded.amount,
        signerPk: pk,
      });
      console.log(`[watch] POST /transfer …`);
      const { attestation, signature, latencyMs } = await requestAttestation(bundle);
      const record = {
        ts: new Date().toISOString(),
        sourceChainId,
        routeId,
        amount: decoded.amount.toString(),
        authority: decoded.authority,
        lockTxHash: log.transactionHash,
        attestation,
        attestationSignature: signature,
        latencyMs: Math.round(latencyMs),
      };
      appendFileSync(outAbs, JSON.stringify(record) + "\n");
      console.log(`[watch] attestation persisted (latency ${Math.round(latencyMs)}ms)`);
      console.log(`[watch] DESTINATION ACTION REQUIRED:`);
      console.log(`[watch]   call FxGatewayHook.mintFromRemote(${attestation.slice(0, 12)}…, ${signature.slice(0, 12)}…)`);
      console.log(`[watch]   on chainId ${routeId.endsWith("-to-arc-usdc") ? ChainId.ArcTestnet : ChainId.AvalancheFuji}`);
    } catch (e) {
      console.error(`[watch] error processing event ${log.transactionHash}:`, e);
    }
  };

  const watchOne = (
    label: string,
    chainId: number,
    ctx: ChainCtx,
    startBlock: bigint,
  ) => {
    console.log(`[watch] ${label} polling from block ${startBlock}`);
    return ctx.client.watchContractEvent({
      address: ctx.hook,
      abi: FX_GATEWAY_HOOK_ABI,
      eventName: "LockedForRemote",
      fromBlock: startBlock,
      pollingInterval: 4_000,
      onLogs: (logs) => {
        for (const l of logs) void handleEvent(chainId, l);
      },
      onError: (e) => console.error(`[watch] ${label} subscription error:`, e),
    });
  };

  const unsubFuji = watchOne("Fuji→Arc", ChainId.AvalancheFuji, fujiCtx, startFromBlockFuji);
  const unsubArc = watchOne("Arc→Fuji", ChainId.ArcTestnet, arcCtx, startFromBlockArc);

  // Keep alive until SIGINT
  await new Promise<void>((res) => {
    process.on("SIGINT", () => {
      console.log("\n[watch] shutting down …");
      try { unsubFuji(); } catch {}
      try { unsubArc(); } catch {}
      res();
    });
  });
}

// ── MAIN ──────────────────────────────────────────────────────────────────

async function cmdDeposit(chainName: "fuji" | "arc", amountAtomicStr: string) {
  const pk = (process.env.DEPLOYER_PRIVATE_KEY ?? "") as Hex;
  if (!pk) throw new Error("DEPLOYER_PRIVATE_KEY not set");
  const amountAtomic = BigInt(amountAtomicStr);

  const cfg = loadHubConfig(chainName);
  const account = privateKeyToAccount(pk);
  const rpcUrl = getRpcUrl(cfg.chainId);
  const pub = createPublicClient({ transport: http(rpcUrl) });
  const wallet = createWalletClient({ account, transport: http(rpcUrl) });

  console.log(`Approving GatewayWallet (${cfg.external.GatewayWallet}) for ${amountAtomicStr} USDC on ${chainName} …`);
  const approveTx = await wallet.writeContract({
    address: cfg.external.USDC,
    abi: parseAbi(["function approve(address,uint256) returns (bool)"]),
    functionName: "approve",
    args: [cfg.external.GatewayWallet, amountAtomic],
    chain: null,
  });
  await pub.waitForTransactionReceipt({ hash: approveTx });
  console.log(`  approve ok: ${approveTx}`);

  console.log(`Calling GatewayWallet.depositFor(USDC, ${account.address}, ${amountAtomicStr}) …`);
  const depositTx = await wallet.writeContract({
    address: cfg.external.GatewayWallet,
    abi: parseAbi(["function depositFor(address,address,uint256)"]),
    functionName: "depositFor",
    args: [cfg.external.USDC, account.address, amountAtomic],
    chain: null,
  });
  await pub.waitForTransactionReceipt({ hash: depositTx });
  console.log(`  depositFor ok: ${depositTx}`);
  console.log(`\nWait ~10s for Circle's operator to pick up the deposit, then run \`balances\` to confirm.`);
}

async function cmdGatewayMint(
  chainName: "fuji" | "arc",
  attestation: Hex,
  signature: Hex,
) {
  const pk = (process.env.DEPLOYER_PRIVATE_KEY ?? "") as Hex;
  if (!pk) throw new Error("DEPLOYER_PRIVATE_KEY not set");
  const cfg = loadHubConfig(chainName);
  const account = privateKeyToAccount(pk);
  const rpcUrl = getRpcUrl(cfg.chainId);
  const pub = createPublicClient({ transport: http(rpcUrl) });
  const wallet = createWalletClient({ account, transport: http(rpcUrl) });

  console.log(`Calling GatewayMinter.gatewayMint on ${chainName} (${cfg.external.GatewayMinter}) …`);
  const tx = await wallet.writeContract({
    address: cfg.external.GatewayMinter,
    abi: parseAbi(["function gatewayMint(bytes,bytes)"]),
    functionName: "gatewayMint",
    args: [attestation, signature],
    chain: null,
  });
  const rec = await pub.waitForTransactionReceipt({ hash: tx });
  console.log(`  gatewayMint ok: ${tx} (status=${rec.status}, gas=${rec.gasUsed})`);
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  if (!cmd) {
    console.error("Usage:");
    console.error("  bun packages/sdk/scripts/gateway-signer.ts info");
    console.error("  bun packages/sdk/scripts/gateway-signer.ts balances [address]");
    console.error("  bun packages/sdk/scripts/gateway-signer.ts deposit <fuji|arc> <amount-atomic>");
    console.error("  bun packages/sdk/scripts/gateway-signer.ts sign-and-attest <route-id> <amount-atomic> [--bypass]");
    console.error("  bun packages/sdk/scripts/gateway-signer.ts gateway-mint <fuji|arc> <attestation-hex> <signature-hex>");
    console.error("  bun packages/sdk/scripts/gateway-signer.ts watch");
    process.exit(1);
  }

  switch (cmd) {
    case "info":
      return cmdInfo();
    case "balances":
      return cmdBalances(args[0]);
    case "deposit": {
      const [chain, amt] = args;
      if ((chain !== "fuji" && chain !== "arc") || !amt) {
        console.error("usage: deposit <fuji|arc> <amount-atomic>");
        process.exit(1);
      }
      return cmdDeposit(chain, amt);
    }
    case "sign-and-attest": {
      const [routeId, amountAtomic] = args;
      const bypass = args.includes("--bypass");
      const destArg = args.find((a) => a.startsWith("--destination="));
      const destinationOverride = destArg
        ? (destArg.slice("--destination=".length) as Address)
        : undefined;
      if (!routeId || !amountAtomic) {
        console.error(
          "usage: sign-and-attest <gateway-fuji-to-arc-usdc|gateway-arc-to-fuji-usdc>" +
            " <amount-atomic> [--bypass] [--destination=0x<address>]",
        );
        process.exit(1);
      }
      if (destinationOverride && !/^0x[0-9a-fA-F]{40}$/.test(destinationOverride)) {
        console.error("--destination must be a 20-byte 0x-prefixed address");
        process.exit(1);
      }
      return cmdSignAndAttest(routeId, amountAtomic, bypass, destinationOverride);
    }
    case "gateway-mint": {
      const [chain, attestation, signature] = args;
      if ((chain !== "fuji" && chain !== "arc") || !attestation || !signature) {
        console.error("usage: gateway-mint <fuji|arc> <attestation-hex> <signature-hex>");
        process.exit(1);
      }
      return cmdGatewayMint(chain, attestation as Hex, signature as Hex);
    }
    case "watch":
      return cmdWatch();
    default:
      console.error(`Unknown command: ${cmd}`);
      process.exit(1);
  }
}

main().catch((e) => {
  console.error(e instanceof Error ? e.stack ?? e.message : String(e));
  process.exit(2);
});
