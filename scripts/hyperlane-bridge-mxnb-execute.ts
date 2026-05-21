// Wave M2 (retry) — reproduce the Fuji→Arc MXNB warp bridge end-to-end.
//
// Usage:
//   KEEPER_PRIVATE_KEY=0x... bun scripts/hyperlane-bridge-mxnb-execute.ts \
//     --amount 1000000 \
//     --recipient 0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69
//
// Does:
//   1. approve(<amount>) on the Fuji TestnetFiatToken MXNB clone
//   2. transferRemote(arcDomain, recipientBytes32, <amount>) on the Fuji
//      collateral warp router, paying the quoted IGP fee
//   3. parses the Mailbox Dispatch event from the receipt to recover the
//      raw message bytes + Hyperlane message ID
//   4. submits mailbox.process(0x, message) on Arc with the same key (the
//      keeper is the configured trustedRelayerIsm relayer, so the public
//      Hyperlane relayer cannot deliver)
//   5. verifies the keeper synthetic balance on Arc post-delivery
//
// Pure read+broadcast — uses viem directly so it doesn't depend on
// rebuilding the contracts package.

import { parseAbiItem, createPublicClient, createWalletClient, http, encodeAbiParameters, decodeAbiParameters, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { avalancheFuji } from "viem/chains";

const FUJI_RPC = process.env.FUJI_RPC_URL ?? "https://api.avax-test.network/ext/bc/C/rpc";
const ARC_RPC  = process.env.ARC_RPC_URL  ?? "https://rpc.testnet.arc.network";

const FUJI_TOKEN  = "0xBA3C09A0E506B3eE25849FC48b13f45F796826eB" as const;
const FUJI_ROUTER = "0x23AB8992585Ff2E40833198f661374a070398876" as const;
const ARC_ROUTER  = "0xE0659b200352Be519e8A77561a5FdfcAa6f81308" as const;
const FUJI_MAILBOX = "0x5b6CFf85442B851A8e6eaBd2A4E4507B5135B3B0" as const;
const ARC_MAILBOX  = "0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9" as const;

const ARC_DOMAIN = 5042002;

function arg(name: string, fallback?: string): string {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx !== -1 && process.argv[idx + 1]) return process.argv[idx + 1]!;
  if (fallback !== undefined) return fallback;
  throw new Error(`missing --${name}`);
}

function pad32(addr: string): Hex {
  const a = addr.toLowerCase().replace(/^0x/, "");
  return ("0x" + a.padStart(64, "0")) as Hex;
}

async function main() {
  const pk = (process.env.KEEPER_PRIVATE_KEY ?? process.env.HYP_KEY) as Hex | undefined;
  if (!pk) throw new Error("KEEPER_PRIVATE_KEY (or HYP_KEY) required");
  const account = privateKeyToAccount(pk);

  const amount = BigInt(arg("amount", "1000000"));
  const recipient = arg("recipient", account.address) as Hex;
  const recipientBytes32 = pad32(recipient);

  const fuji = createPublicClient({ chain: avalancheFuji, transport: http(FUJI_RPC) });
  const arc  = createPublicClient({ transport: http(ARC_RPC) });
  const wallet = createWalletClient({ account, transport: http(FUJI_RPC), chain: avalancheFuji });
  const arcWallet = createWalletClient({ account, transport: http(ARC_RPC) });

  // 1. approve
  console.log("approve", amount.toString(), "tMXNB →", FUJI_ROUTER);
  const approveHash = await wallet.writeContract({
    address: FUJI_TOKEN,
    abi: [parseAbiItem("function approve(address,uint256) external returns (bool)")],
    functionName: "approve",
    args: [FUJI_ROUTER, amount],
  });
  await fuji.waitForTransactionReceipt({ hash: approveHash });
  console.log("approve tx:", approveHash);

  // 2. quote + transferRemote
  const quote = await fuji.readContract({
    address: FUJI_ROUTER,
    abi: [parseAbiItem("function quoteGasPayment(uint32) view returns (uint256)")],
    functionName: "quoteGasPayment",
    args: [ARC_DOMAIN],
  }) as bigint;

  console.log("dispatching", amount.toString(), "tMXNB →", ARC_DOMAIN, "fee=", quote.toString());
  const dispatchHash = await wallet.writeContract({
    address: FUJI_ROUTER,
    abi: [parseAbiItem("function transferRemote(uint32,bytes32,uint256) payable returns (bytes32)")],
    functionName: "transferRemote",
    args: [ARC_DOMAIN, recipientBytes32, amount],
    value: quote,
  });
  const dispatchReceipt = await fuji.waitForTransactionReceipt({ hash: dispatchHash });
  console.log("Fuji dispatch tx:", dispatchHash, "block:", dispatchReceipt.blockNumber);

  // 3. parse the Mailbox Dispatch event for raw message bytes + ID.
  // Dispatch(address indexed sender, uint32 indexed dst, bytes32 indexed recipient, bytes message)
  const dispatchTopic = "0x769f711d20c679153d382254f59892613b58a97cc876b249134ac25c80f9c814";
  // DispatchId(bytes32 indexed messageId)
  const dispatchIdTopic = "0x788dbc1b7152732178210e7f4d9d010ef016f9eafbe66786bd7169f56e0c353a";

  const mailboxLogs = dispatchReceipt.logs.filter(l => l.address.toLowerCase() === FUJI_MAILBOX.toLowerCase());
  const dispatchLog = mailboxLogs.find(l => l.topics[0] === dispatchTopic);
  const dispatchIdLog = mailboxLogs.find(l => l.topics[0] === dispatchIdTopic);
  if (!dispatchLog || !dispatchIdLog) throw new Error("Could not locate Dispatch / DispatchId logs");

  const [message] = decodeAbiParameters([{ type: "bytes" }], dispatchLog.data);
  const messageId = dispatchIdLog.topics[1]!;
  console.log("Hyperlane message ID:", messageId);
  console.log("explorer:", `https://explorer.hyperlane.xyz/message/${messageId}`);

  // 4. self-relay on Arc (trustedRelayerIsm permits keeper).
  console.log("submitting Arc mailbox.process(...)");
  const arcHash = await arcWallet.writeContract({
    chain: undefined,
    address: ARC_MAILBOX,
    abi: [parseAbiItem("function process(bytes,bytes) external payable")],
    functionName: "process",
    args: ["0x", message as Hex],
  });
  const arcReceipt = await arc.waitForTransactionReceipt({ hash: arcHash });
  console.log("Arc delivery tx:", arcHash, "block:", arcReceipt.blockNumber);

  // 5. verify
  const delivered = await arc.readContract({
    address: ARC_MAILBOX,
    abi: [parseAbiItem("function delivered(bytes32) view returns (bool)")],
    functionName: "delivered",
    args: [messageId],
  });
  const bal = await arc.readContract({
    address: ARC_ROUTER,
    abi: [parseAbiItem("function balanceOf(address) view returns (uint256)")],
    functionName: "balanceOf",
    args: [recipient],
  });
  console.log("delivered?", delivered, "  recipient Arc MXNB balance:", bal.toString());
}

main().catch(e => { console.error(e); process.exit(1); });
