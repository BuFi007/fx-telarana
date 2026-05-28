#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only

/**
 * Hyperlane MXNB bridge — Fuji → Arc Testnet.
 *
 * PR-H3 / Wave L1 (BUFI bucket-analysis 2026-05-21, B11: 55→75).
 *
 * Why this exists
 * ───────────────
 * MXNB is a non-USDC stable (Bitso-issued, 6-decimal ERC-20) we want to
 * round-trip Fuji → Arc Testnet via Hyperlane — the lane already wired
 * by hyperlane/{arc-testnet,fuji,registry}/ + the existing
 * hyperlane:fuji:test-message smoke. CCTP only carries USDC/EURC, so a
 * Circle-controlled path is not an option for MXNB; Hyperlane is.
 *
 * Hyperlane MXNB needs two pieces of warp-route plumbing that DO NOT
 * exist yet in this repo:
 *
 *   1. Fuji  side: HypERC20Collateral(mailbox=fuji.mailbox, token=MXNB_fuji)
 *      — locks user MXNB and dispatches a Hyperlane message.
 *   2. Arc   side: HypERC20(mailbox=arc.mailbox, decimals=6, name="MXNB")
 *      — receives the message and mints a representation token.
 *      Then HypERC20Collateral.enrollRemoteRouter(arcDomain, arcHypERC20)
 *      and HypERC20.enrollRemoteRouter(fujiDomain, fujiHypERC20Collateral)
 *      to close the loop.
 *
 * Until those are deployed, a *real* MXNB bridge is blocked. This script
 * does the next best thing on the demo path:
 *
 *   ─ Preflight: env, signer, balances, configured mailbox + MXNB
 *     addresses (cross-checked against the Hyperlane agent-config.json
 *     committed in this repo).
 *   ─ Dispatch-only mode (DEFAULT): encodes an MXNB-shaped transfer
 *     payload (recipient bytes32 + amount uint256) and calls
 *     fuji.mailbox.dispatch(arctestnet, testRecipient_arc, body). This
 *     is what hyperlane:fuji:test-message does under the hood — the
 *     repo's existing self-relay smoke. Proves the Hyperlane lane is
 *     hot for MXNB-shaped messages, even though no MXNB actually moves
 *     because no warp router on either side knows about MXNB yet.
 *   ─ Full mode (--full or ARC_MXNB_WARP_ROUTER set): approves MXNB to
 *     the Fuji HypERC20Collateral router, calls transferRemote, polls
 *     Arc until the Arc-side HypERC20 mints to recipient. Aborts up
 *     front if FUJI_MXNB_WARP_ROUTER + ARC_MXNB_WARP_ROUTER are not
 *     both provided.
 *
 * Output
 * ──────
 * deployments/hyperlane-mxnb-fuji-arc.json — single artefact, overwritten
 *   each run. Shape carries Fuji dispatch + Arc delivery tx hashes,
 *   amount, MXNB token addresses on each side, the Hyperlane mailbox
 *   addresses used, and a `status` field that is one of:
 *     "blocked"                 — preflight failed (missing env etc.)
 *     "scaffold-dispatch-only"  — Fuji dispatched, Arc not minted
 *                                  (no warp router deployed yet)
 *     "delivered"               — Arc HypERC20 minted, full round-trip
 *     "error"                   — runtime failure mid-flow
 *
 * Required env
 * ────────────
 *   HYPERLANE_RELAYER_PRIVATE_KEY   32-byte hex. The relayer/keeper EOA
 *                                   that owns the Hyperlane core
 *                                   deployment (must match
 *                                   hyperlane/arc-testnet/core-config.yaml
 *                                   owner = 0x0646...EC69 to keep the
 *                                   trustedRelayerIsm path open). NEVER
 *                                   echoed.
 *
 * Tunable env
 * ───────────
 *   FUJI_RPC_URL                    default api.avax-test.network ext/bc/C/rpc
 *   ARC_RPC_URL                     default rpc.drpc.testnet.arc.network
 *   MXNB_BRIDGE_AMOUNT              human MXNB, default "1.0" (= 1_000_000 raw, 6dp)
 *   MXNB_RECIPIENT                  Arc recipient address; default = relayer
 *   FUJI_MXNB_WARP_ROUTER           HypERC20Collateral on Fuji (full mode only)
 *   ARC_MXNB_WARP_ROUTER            HypERC20 on Arc (full mode only)
 *   ARC_DELIVERY_TIMEOUT_MS         default 600_000 (10 min)
 *   ARC_DELIVERY_POLL_MS            default 5_000
 *
 * Run
 * ───
 *   bun scripts/hyperlane-bridge-mxnb.ts            # dispatch-only mode
 *   bun scripts/hyperlane-bridge-mxnb.ts --full     # requires warp routers
 *
 * @see hyperlane/arc-testnet/core-config.yaml
 * @see hyperlane/arc-testnet/agent-config.json
 * @see deployments/hyperlane-arc-testnet.json
 * @see contracts/src/hub/FxHyperlaneHubReceiver.sol
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  defineChain,
  encodeAbiParameters,
  formatUnits,
  http,
  pad,
  parseAbi,
  parseUnits,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { avalancheFuji } from "viem/chains";

// ───────────────────────────── paths ──────────────────────────────────────

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const AGENT_CONFIG_PATH = resolve(REPO_ROOT, "hyperlane/arc-testnet/agent-config.json");
const FUJI_DEPLOYMENT_PATH = resolve(REPO_ROOT, "deployments/avalanche-fuji.json");
const ARC_DEPLOYMENT_PATH = resolve(REPO_ROOT, "deployments/arc-testnet.json");
const OUTPUT_PATH = resolve(REPO_ROOT, "deployments/hyperlane-mxnb-fuji-arc.json");

// ───────────────────────────── env ────────────────────────────────────────

const FULL_MODE = process.argv.includes("--full");

const FUJI_RPC_URL =
  process.env.FUJI_RPC_URL ?? "https://api.avax-test.network/ext/bc/C/rpc";
const ARC_RPC_URL = process.env.ARC_RPC_URL ?? "https://rpc.drpc.testnet.arc.network";

const AMOUNT_HUMAN = process.env.MXNB_BRIDGE_AMOUNT ?? "1.0";

const FUJI_DOMAIN = 43113 as const;
const ARC_DOMAIN = 5042002 as const;

const DELIVERY_TIMEOUT_MS = Number(
  process.env.ARC_DELIVERY_TIMEOUT_MS ?? 600_000,
);
const DELIVERY_POLL_MS = Number(process.env.ARC_DELIVERY_POLL_MS ?? 5_000);

// ───────────────────────────── chains ─────────────────────────────────────

const arcTestnet = defineChain({
  id: ARC_DOMAIN,
  name: "Arc Testnet",
  nativeCurrency: { decimals: 18, name: "USDC", symbol: "USDC" },
  rpcUrls: { default: { http: [ARC_RPC_URL] } },
});

// ───────────────────────────── ABIs ───────────────────────────────────────

const ERC20_ABI = parseAbi([
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
]);

const MAILBOX_ABI = parseAbi([
  "function dispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody) payable returns (bytes32 messageId)",
  "function quoteDispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody) view returns (uint256 fee)",
  "event Dispatch(address indexed sender, uint32 indexed destination, bytes32 indexed recipient, bytes message)",
  "event DispatchId(bytes32 indexed messageId)",
  "event Process(uint32 indexed origin, bytes32 indexed sender, address indexed recipient)",
  "event ProcessId(bytes32 indexed messageId)",
]);

const WARP_ROUTER_ABI = parseAbi([
  "function transferRemote(uint32 destinationDomain, bytes32 recipient, uint256 amount) payable returns (bytes32 messageId)",
  "function quoteGasPayment(uint32 destinationDomain) view returns (uint256)",
  "event SentTransferRemote(uint32 indexed destination, bytes32 indexed recipient, uint256 amount)",
  "event ReceivedTransferRemote(uint32 indexed origin, bytes32 indexed recipient, uint256 amount)",
]);

// ───────────────────────────── types ──────────────────────────────────────

type Status =
  | "blocked"
  | "scaffold-dispatch-only"
  | "delivered"
  | "error";

interface OutputArtefact {
  date: string;
  ranAt: string;
  status: Status;
  mode: "dispatch-only" | "full";
  blocker?: string;
  amount: { human: string; raw: string; decimals: number };
  token: {
    fuji: Address | null;
    arc: Address | null;
  };
  recipient: Address;
  hyperlane: {
    fujiDomain: number;
    arcDomain: number;
    fujiMailbox: Address;
    arcMailbox: Address;
    arcRecipient: Address;
    fujiWarpRouter: Address | null;
    arcWarpRouter: Address | null;
  };
  fuji: {
    txHash: Hex | null;
    blockNumber: string | null;
    messageId: Hex | null;
  };
  arc: {
    txHash: Hex | null;
    blockNumber: string | null;
    messageId: Hex | null;
  };
  notes: string[];
}

// ───────────────────────────── helpers ────────────────────────────────────

function requirePk(envName: string): Hex {
  const v = process.env[envName];
  if (!v || !/^0x[a-fA-F0-9]{64}$/.test(v)) {
    throw new Error(
      `${envName} must be set to a 32-byte hex private key (no quotes)`,
    );
  }
  return v as Hex;
}

function readJson<T = unknown>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

function addressToBytes32(addr: Address): Hex {
  return pad(addr, { size: 32 });
}

function writeOutput(out: OutputArtefact): void {
  mkdirSync(dirname(OUTPUT_PATH), { recursive: true });
  writeFileSync(OUTPUT_PATH, JSON.stringify(out, null, 2) + "\n", "utf8");
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

interface AgentConfig {
  chains: {
    fuji: { mailbox: Address; chainId: number; domainId: number };
    arctestnet: {
      mailbox: Address;
      chainId: number;
      domainId: number;
      testRecipient: Address;
    };
  };
}

interface FujiDeployment {
  contracts: { MXNB?: Address; [k: string]: Address | string | undefined };
  [k: string]: unknown;
}

// ─────────────────────── encode MXNB warp body ────────────────────────────
//
// Hyperlane's canonical HypERC20 message body is:
//
//     abi.encode(bytes32 recipient, uint256 amount, bytes metadata)
//
// with metadata = "" for vanilla HypERC20. We mirror that exact shape so
// the dispatch-only scaffold is bit-identical to what a real warp route
// would emit. When the Arc-side HypERC20 is deployed and enrolls Fuji's
// router as a trusted remote, the same body will be accepted by its
// _handle without modification.
//
// Spec reference: https://docs.hyperlane.xyz/docs/reference/warp-routes
function encodeWarpBody(recipient: Address, amountRaw: bigint): Hex {
  return encodeAbiParameters(
    [
      { name: "recipient", type: "bytes32" },
      { name: "amount", type: "uint256" },
      { name: "metadata", type: "bytes" },
    ],
    [addressToBytes32(recipient), amountRaw, "0x"],
  );
}

// ─────────────────────── ABI: extract messageId ───────────────────────────

function extractDispatchId(receipt: {
  logs: ReadonlyArray<{
    address: Address;
    topics: readonly Hex[];
    data: Hex;
  }>;
}): Hex | null {
  for (const log of receipt.logs) {
    try {
      const decoded = decodeEventLog({
        abi: MAILBOX_ABI,
        topics: log.topics as [Hex, ...Hex[]],
        data: log.data,
      }) as { eventName: string; args: { messageId?: Hex } };
      if (decoded.eventName === "DispatchId" && decoded.args.messageId) {
        return decoded.args.messageId;
      }
    } catch {
      // not a DispatchId log; keep scanning
    }
  }
  return null;
}

function extractProcessId(receipt: {
  logs: ReadonlyArray<{
    address: Address;
    topics: readonly Hex[];
    data: Hex;
  }>;
}): Hex | null {
  for (const log of receipt.logs) {
    try {
      const decoded = decodeEventLog({
        abi: MAILBOX_ABI,
        topics: log.topics as [Hex, ...Hex[]],
        data: log.data,
      }) as { eventName: string; args: { messageId?: Hex } };
      if (decoded.eventName === "ProcessId" && decoded.args.messageId) {
        return decoded.args.messageId;
      }
    } catch {
      // not a ProcessId log
    }
  }
  return null;
}

// ─────────────────────── poll Arc delivery ────────────────────────────────
//
// Watches arcMailbox for a Process(_, _, recipient) whose messageId matches
// the dispatched id. Returns the matching log's tx hash + block number.

interface ArcDelivery {
  status: "delivered" | "timeout";
  txHash?: Hex;
  blockNumber?: bigint;
  reason?: string;
}

async function pollArcDelivery(
  arc: PublicClient,
  arcMailbox: Address,
  expectedMessageId: Hex,
  searchFromBlock: bigint,
): Promise<ArcDelivery> {
  const deadline = Date.now() + DELIVERY_TIMEOUT_MS;
  let lastReason = "no ProcessId match seen";
  let cursor = searchFromBlock;
  while (Date.now() < deadline) {
    try {
      const head = await arc.getBlockNumber();
      if (head >= cursor) {
        const logs = await arc.getLogs({
          address: arcMailbox,
          event: {
            type: "event",
            name: "ProcessId",
            inputs: [{ indexed: true, name: "messageId", type: "bytes32" }],
          },
          args: { messageId: expectedMessageId },
          fromBlock: cursor,
          toBlock: head,
        });
        if (logs.length > 0) {
          const hit = logs[0]!;
          return {
            status: "delivered",
            txHash: hit.transactionHash as Hex,
            blockNumber: hit.blockNumber,
          };
        }
        cursor = head + 1n;
      }
    } catch (e) {
      lastReason = `arc log scan error: ${(e as Error).message}`;
    }
    await sleep(DELIVERY_POLL_MS);
  }
  return { status: "timeout", reason: lastReason };
}

// ─────────────────────────── main ─────────────────────────────────────────

async function main(): Promise<void> {
  const ranAt = new Date().toISOString();
  const today = ranAt.slice(0, 10);

  // 1. Load configured Hyperlane addresses + MXNB token from committed
  //    artefacts. These are the source of truth — script never invents.
  const agent = readJson<AgentConfig>(AGENT_CONFIG_PATH);
  const fujiDeployment = readJson<FujiDeployment>(FUJI_DEPLOYMENT_PATH);
  const arcDeployment = readJson<{ contracts?: Record<string, Address> }>(ARC_DEPLOYMENT_PATH);

  const fujiMailbox = agent.chains.fuji.mailbox;
  const arcMailbox = agent.chains.arctestnet.mailbox;
  const arcTestRecipient = agent.chains.arctestnet.testRecipient;

  // MXNB on Fuji is real. MXNB on Arc is NOT deployed in this repo's
  // deployments/arc-testnet.json today — confirmed against
  // defi-web-app/packages/location/src/deployments.ts (chainId 5042002
  // entry has only USDC, EURC, AUDF; no MXNB). We surface that gap
  // explicitly rather than half-shipping a fake address.
  const fujiMxnb = fujiDeployment.contracts?.MXNB as Address | undefined;
  const arcMxnb = (arcDeployment.contracts?.MXNB ?? null) as Address | null;

  const fujiWarpRouter =
    (process.env.FUJI_MXNB_WARP_ROUTER as Address | undefined) ?? null;
  const arcWarpRouter =
    (process.env.ARC_MXNB_WARP_ROUTER as Address | undefined) ?? null;

  const notes: string[] = [];
  const out: OutputArtefact = {
    date: today,
    ranAt,
    status: "error",
    mode: FULL_MODE ? "full" : "dispatch-only",
    amount: { human: AMOUNT_HUMAN, raw: "0", decimals: 6 },
    token: { fuji: fujiMxnb ?? null, arc: arcMxnb },
    recipient: "0x0000000000000000000000000000000000000000" as Address,
    hyperlane: {
      fujiDomain: FUJI_DOMAIN,
      arcDomain: ARC_DOMAIN,
      fujiMailbox,
      arcMailbox,
      arcRecipient: arcTestRecipient,
      fujiWarpRouter,
      arcWarpRouter,
    },
    fuji: { txHash: null, blockNumber: null, messageId: null },
    arc: { txHash: null, blockNumber: null, messageId: null },
    notes,
  };

  // 2. Preflight — fail fast with a precise reason.
  let signerPk: Hex;
  try {
    signerPk = requirePk("HYPERLANE_RELAYER_PRIVATE_KEY");
  } catch (e) {
    out.status = "blocked";
    out.blocker = (e as Error).message;
    notes.push(
      "Provide HYPERLANE_RELAYER_PRIVATE_KEY for the demo keeper EOA " +
        "0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69. It must match the " +
        "owner / trustedRelayerIsm relayer in hyperlane/arc-testnet/core-config.yaml.",
    );
    writeOutput(out);
    console.error(`blocked: ${out.blocker}`);
    process.exit(2);
  }

  if (!fujiMxnb) {
    out.status = "blocked";
    out.blocker =
      "deployments/avalanche-fuji.json has no contracts.MXNB entry — cannot bridge an undeployed token.";
    writeOutput(out);
    console.error(`blocked: ${out.blocker}`);
    process.exit(2);
  }

  const signer = privateKeyToAccount(signerPk);
  const recipient = (process.env.MXNB_RECIPIENT as Address | undefined) ?? signer.address;
  out.recipient = recipient;

  // 3. Build clients.
  const fujiPublic = createPublicClient({ chain: avalancheFuji, transport: http(FUJI_RPC_URL) });
  const arcPublic = createPublicClient({ chain: arcTestnet, transport: http(ARC_RPC_URL) });
  const fujiWallet = createWalletClient({
    account: signer,
    chain: avalancheFuji,
    transport: http(FUJI_RPC_URL),
  });

  // 4. Inspect MXNB token to lock in decimals + balance.
  let amountRaw: bigint;
  let mxnbDecimals = 6;
  try {
    mxnbDecimals = Number(
      await fujiPublic.readContract({
        address: fujiMxnb,
        abi: ERC20_ABI,
        functionName: "decimals",
      }),
    );
  } catch (e) {
    notes.push(`decimals() read failed — assuming 6: ${(e as Error).message}`);
  }
  amountRaw = parseUnits(AMOUNT_HUMAN, mxnbDecimals);
  out.amount = { human: AMOUNT_HUMAN, raw: amountRaw.toString(), decimals: mxnbDecimals };

  const fujiMxnbBalance = (await fujiPublic.readContract({
    address: fujiMxnb,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [signer.address],
  })) as bigint;

  console.log(
    `signer=${signer.address}\n` +
      `mxnb(fuji)=${fujiMxnb} balance=${formatUnits(fujiMxnbBalance, mxnbDecimals)}\n` +
      `recipient(arc)=${recipient} amount=${AMOUNT_HUMAN} mode=${out.mode}`,
  );

  try {
    if (FULL_MODE) {
      await runFullMode({
        fujiPublic,
        arcPublic,
        fujiWallet,
        signer: signer.address,
        recipient,
        fujiMxnb,
        amountRaw,
        fujiWarpRouter,
        arcWarpRouter,
        arcMailbox,
        out,
        notes,
      });
    } else {
      await runDispatchOnlyMode({
        fujiPublic,
        fujiWallet,
        signer: signer.address,
        recipient,
        amountRaw,
        fujiMailbox,
        arcRecipient: arcTestRecipient,
        arcMxnb,
        out,
        notes,
      });
    }
  } catch (e) {
    out.status = "error";
    out.blocker = (e as Error).message;
    notes.push(`runtime error: ${(e as Error).message}`);
    writeOutput(out);
    console.error(`error: ${out.blocker}`);
    process.exit(1);
  }

  writeOutput(out);
  console.log(`status=${out.status}`);
  if (out.fuji.txHash) console.log(`fuji.dispatch=${out.fuji.txHash}`);
  if (out.arc.txHash) console.log(`arc.delivery=${out.arc.txHash}`);
  if (out.blocker) console.log(`blocker=${out.blocker}`);
}

// ─────────────────── dispatch-only (DEFAULT mode) ─────────────────────────
//
// Calls fuji.mailbox.dispatch(arcDomain, arcTestRecipient, warpBody) — same
// shape an HypERC20Collateral would produce — and writes the resulting
// dispatch tx + messageId to the artefact. No MXNB is actually moved
// because no warp router exists on either side yet. This is honest
// scaffolding: the lane works, the encoded body is canonical, but the
// settlement layer is the documented blocker.

async function runDispatchOnlyMode(args: {
  fujiPublic: PublicClient;
  fujiWallet: ReturnType<typeof createWalletClient>;
  signer: Address;
  recipient: Address;
  amountRaw: bigint;
  fujiMailbox: Address;
  arcRecipient: Address;
  arcMxnb: Address | null;
  out: OutputArtefact;
  notes: string[];
}): Promise<void> {
  const {
    fujiPublic,
    fujiWallet,
    signer,
    recipient,
    amountRaw,
    fujiMailbox,
    arcRecipient,
    arcMxnb,
    out,
    notes,
  } = args;

  notes.push(
    "Dispatch-only mode: encoded a canonical HypERC20 warp body " +
      "(bytes32 recipient | uint256 amount | bytes metadata) and dispatched " +
      "via fuji.mailbox to arctestnet.testRecipient. No MXNB ERC-20 actually " +
      "transfers because no HypERC20Collateral / HypERC20 warp routers are " +
      "deployed for MXNB on either side yet.",
  );
  if (!arcMxnb) {
    notes.push(
      "BLOCKER: MXNB is not deployed on Arc Testnet. Verified against " +
        "deployments/arc-testnet.json AND defi-web-app/packages/location/src/" +
        "deployments.ts (chainId 5042002 carries USDC + EURC + AUDF only). " +
        "Full round-trip requires either (a) deploying a HypERC20 named MXNB " +
        "on Arc and enrolling it as the remote router for the Fuji-side " +
        "HypERC20Collateral, OR (b) bridging MXNB indirectly through an " +
        "existing token that is liquid on both chains (out of scope for PR-H3).",
    );
  }

  const body = encodeWarpBody(recipient, amountRaw);
  const arcRecipientBytes32 = addressToBytes32(arcRecipient);

  // Quote the Hyperlane dispatch fee. With merkleTreeHook as defaultHook
  // and protocolFee=0 from core-config.yaml, this is typically 0.
  const fee = (await fujiPublic.readContract({
    address: fujiMailbox,
    abi: MAILBOX_ABI,
    functionName: "quoteDispatch",
    args: [ARC_DOMAIN, arcRecipientBytes32, body],
  })) as bigint;

  console.log(`fuji.mailbox.quoteDispatch fee=${fee.toString()} wei`);

  const hash = await fujiWallet.writeContract({
    address: fujiMailbox,
    abi: MAILBOX_ABI,
    functionName: "dispatch",
    args: [ARC_DOMAIN, arcRecipientBytes32, body],
    value: fee,
    chain: avalancheFuji,
    account: signer,
  });
  const receipt = await fujiPublic.waitForTransactionReceipt({ hash });
  const messageId = extractDispatchId(receipt);

  out.fuji.txHash = hash;
  out.fuji.blockNumber = receipt.blockNumber.toString();
  out.fuji.messageId = messageId;
  out.status = "scaffold-dispatch-only";

  notes.push(
    "Arc-side delivery NOT polled — testRecipient does not implement the " +
      "MXNB mint side of a warp route, so even if the relayer processes the " +
      "message, no MXNB will be minted on Arc. Use --full once warp routers " +
      "are deployed.",
  );
}

// ─────────────────── full mode (REQUIRES warp routers) ────────────────────

async function runFullMode(args: {
  fujiPublic: PublicClient;
  arcPublic: PublicClient;
  fujiWallet: ReturnType<typeof createWalletClient>;
  signer: Address;
  recipient: Address;
  fujiMxnb: Address;
  amountRaw: bigint;
  fujiWarpRouter: Address | null;
  arcWarpRouter: Address | null;
  arcMailbox: Address;
  out: OutputArtefact;
  notes: string[];
}): Promise<void> {
  const {
    fujiPublic,
    arcPublic,
    fujiWallet,
    signer,
    recipient,
    fujiMxnb,
    amountRaw,
    fujiWarpRouter,
    arcWarpRouter,
    arcMailbox,
    out,
    notes,
  } = args;

  if (!fujiWarpRouter || !arcWarpRouter) {
    out.status = "blocked";
    out.blocker =
      "--full requires FUJI_MXNB_WARP_ROUTER (HypERC20Collateral on Fuji) and ARC_MXNB_WARP_ROUTER (HypERC20 on Arc). Neither is deployed in this repo today.";
    notes.push(
      "Deploy a HypERC20Collateral on Fuji (token = MXNB_fuji, mailbox = " +
        "0x5b6CFf85442B851A8e6eaBd2A4E4507B5135B3B0) and a HypERC20 on Arc " +
        "(mailbox = 0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9, decimals = 6), " +
        "then cross-enroll them as remote routers. Then re-run with " +
        "FUJI_MXNB_WARP_ROUTER + ARC_MXNB_WARP_ROUTER set.",
    );
    return;
  }

  // Approve the Fuji warp router to pull MXNB.
  const currentAllowance = (await fujiPublic.readContract({
    address: fujiMxnb,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: [signer, fujiWarpRouter],
  })) as bigint;
  if (currentAllowance < amountRaw) {
    const approveHash = await fujiWallet.writeContract({
      address: fujiMxnb,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [fujiWarpRouter, amountRaw],
      chain: avalancheFuji,
      account: signer,
    });
    await fujiPublic.waitForTransactionReceipt({ hash: approveHash });
    notes.push(`MXNB approve(fujiWarpRouter, ${amountRaw}) tx=${approveHash}`);
  }

  // Quote interchain gas (HypERC20Collateral.quoteGasPayment).
  let gasPayment = 0n;
  try {
    gasPayment = (await fujiPublic.readContract({
      address: fujiWarpRouter,
      abi: WARP_ROUTER_ABI,
      functionName: "quoteGasPayment",
      args: [ARC_DOMAIN],
    })) as bigint;
  } catch (e) {
    notes.push(
      `quoteGasPayment failed — sending with value=0: ${(e as Error).message}`,
    );
  }

  // Capture Arc head BEFORE dispatch so the delivery scan window is precise.
  const arcSearchFrom = await arcPublic.getBlockNumber();

  const dispatchHash = await fujiWallet.writeContract({
    address: fujiWarpRouter,
    abi: WARP_ROUTER_ABI,
    functionName: "transferRemote",
    args: [ARC_DOMAIN, addressToBytes32(recipient), amountRaw],
    value: gasPayment,
    chain: avalancheFuji,
    account: signer,
  });
  const dispatchReceipt = await fujiPublic.waitForTransactionReceipt({
    hash: dispatchHash,
  });
  const messageId = extractDispatchId(dispatchReceipt);

  out.fuji.txHash = dispatchHash;
  out.fuji.blockNumber = dispatchReceipt.blockNumber.toString();
  out.fuji.messageId = messageId;

  if (!messageId) {
    out.status = "scaffold-dispatch-only";
    notes.push(
      "transferRemote receipt did not carry a DispatchId log — cannot " +
        "correlate to Arc delivery. Check that the Fuji warp router shares " +
        "the configured Hyperlane mailbox.",
    );
    return;
  }

  console.log(
    `fuji.transferRemote tx=${dispatchHash} messageId=${messageId}\n` +
      `polling arc.mailbox=${arcMailbox} from block ${arcSearchFrom}...`,
  );

  const delivery = await pollArcDelivery(arcPublic, arcMailbox, messageId, arcSearchFrom);
  if (delivery.status === "delivered") {
    out.arc.txHash = delivery.txHash!;
    out.arc.blockNumber = delivery.blockNumber!.toString();
    out.arc.messageId = messageId;
    out.status = "delivered";
    notes.push("Full Fuji → Arc MXNB warp round-trip succeeded.");
  } else {
    out.status = "scaffold-dispatch-only";
    notes.push(
      `Arc delivery timeout after ${DELIVERY_TIMEOUT_MS}ms — relayer may be ` +
        `offline or under-funded on Arc (gas is USDC there). Reason: ${delivery.reason}`,
    );
  }
}

await main();
