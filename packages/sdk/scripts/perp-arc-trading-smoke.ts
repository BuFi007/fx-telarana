#!/usr/bin/env bun
// SPDX-License-Identifier: Apache-2.0

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  concatHex,
  defineChain,
  http,
  isHex,
  keccak256,
  parseAbi,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createPublicClient, createWalletClient } from "viem";

import {
  ChainId,
  getAddresses,
  getFxPerpMarket,
} from "../src/index.js";
import {
  assertFxPerpLiveReadiness,
  loadFxPerpRuntimeConfig,
} from "../src/perps-runtime.js";
import { writeWithRedstone } from "../src/perps-keeper.js";

const ARC_RPC_URL = process.env.ARC_RPC_URL ?? "https://rpc.drpc.testnet.arc.network";
const DEPLOYER_PRIVATE_KEY = normalizePrivateKey(process.env.DEPLOYER_PRIVATE_KEY);
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const PERP_CONFIG_PATH =
  process.env.ARC_PERP_CONFIG_PATH ?? resolve(REPO_ROOT, "deployments/perps-config-5042002.json");

const arcTestnet = defineChain({
  id: 5_042_002,
  name: "Arc Testnet",
  nativeCurrency: { name: "Arc Testnet Gas", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [ARC_RPC_URL] } },
});

const perpRuntime = loadFxPerpRuntimeConfig({
  configPath: PERP_CONFIG_PATH,
  contractAddressesJson: process.env.CONTRACT_ADDRESSES_JSON,
});
const perpConfig = perpRuntime.manifest!;
const eurcMarket = getFxPerpMarket(perpConfig, "EURC_USDC");
const arcAddresses = getAddresses(ChainId.ArcTestnet);

const ADDR = {
  usdc: perpConfig.usdc,
  eurc: eurcMarket.baseToken,
  pyth: requireAddress(arcAddresses.pyth, "Arc Pyth"),
  oracle: perpConfig.fxOracle,
  clearinghouse: perpConfig.addresses.clearinghouse,
  margin: perpConfig.addresses.marginAccount,
  funding: perpConfig.addresses.fundingEngine,
  health: perpConfig.addresses.healthChecker,
  liquidation: perpConfig.addresses.liquidationEngine,
  settlement: perpConfig.addresses.orderSettlement,
};

const FEEDS = {
  usdc: strip0x(requireHex(arcAddresses.pythFeedUSDC, "Arc Pyth USDC feed")),
  eurc: strip0x(requireHex(arcAddresses.pythFeedEURC, "Arc Pyth EURC feed")),
};

const MARKET_ID = eurcMarket.marketId;
const SIZE_E18 = 10_000_000_000_000_000n; // 0.01 EURC
const HEALTHY_MARGIN = 250_000n; // 0.25 USDC
const LIQUIDATION_MARGIN = 100_000n; // 0.10 USDC
const ORDER_TYPE_LIMIT = 1;
const FLAG_POST_ONLY = 2;
const HERMES_TIMEOUT_MS = 10_000;

const erc20Abi = parseAbi([
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
]);

const pythAbi = parseAbi([
  "function getUpdateFee(bytes[] updateData) view returns (uint256)",
]);

const oracleAbi = parseAbi([
  "function getMidWithUpdatePyth(address base, address quote, bytes[] pythUpdate) payable returns (uint256,uint256)",
  "function getMid(address base, address quote) view returns (uint256,uint256)",
  "function redstoneFeedOf(address token) view returns (bytes32)",
]);

const marginAbi = parseAbi([
  "function depositMargin(address trader, uint256 amount)",
  "function marginOf(address trader) view returns (uint256)",
  "function reservedMarginOf(address trader) view returns (uint256)",
  "function protocolLiquidity() view returns (uint256)",
]);

const clearinghouseAbi = parseAbi([
  "function quoteFee(bytes32 marketId, address trader, int256 sizeDeltaE18) view returns (uint256 feeAmount, uint256 priceE18)",
  "function position(bytes32 marketId, address trader) view returns ((int256 sizeE18,uint256 entryPriceE18,uint256 marginReserved,uint64 lastFundingVersion))",
  "function openInterestLong(bytes32 marketId) view returns (uint256)",
  "function openInterestShort(bytes32 marketId) view returns (uint256)",
]);

const settlementAbi = parseAbi([
  "function hashOrder((address trader,bytes32 marketId,int256 sizeDeltaE18,uint256 priceE18,uint256 maxFee,uint8 orderType,uint8 flags,uint64 nonce,uint64 deadline) order) view returns (bytes32)",
  "function settleMatch((address trader,bytes32 marketId,int256 sizeDeltaE18,uint256 priceE18,uint256 maxFee,uint8 orderType,uint8 flags,uint64 nonce,uint64 deadline) maker, bytes makerSig, (address trader,bytes32 marketId,int256 sizeDeltaE18,uint256 priceE18,uint256 maxFee,uint8 orderType,uint8 flags,uint64 nonce,uint64 deadline) taker, bytes takerSig, uint256 fillSizeE18, uint256 fillPriceE18)",
]);

const fundingAbi = parseAbi([
  "function pokeFundingRate(bytes32 marketId)",
  "function fundingState(bytes32 marketId) view returns (uint64 currentVersion,uint256 lastUpdate,int256 currentRateE18PerSecond,int256 cumulativeFundingE18)",
]);

const healthAbi = parseAbi([
  "function healthFactor(bytes32 marketId, address trader) view returns (uint256)",
  "function isLiquidatable(bytes32 marketId, address trader) view returns (bool)",
]);

const liquidationAbi = parseAbi([
  "function flagAccount(bytes32 marketId, address trader)",
  "function liquidate(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18) returns (uint256 liquidatorReward,int256 socializedLoss)",
  "function liquidationConfig() view returns (uint16 bountyBps, uint256 bountyCap, uint256 flagDelay)",
]);

const signedOrderTypes = {
  SignedOrder: [
    { name: "trader", type: "address" },
    { name: "marketId", type: "bytes32" },
    { name: "sizeDeltaE18", type: "int256" },
    { name: "priceE18", type: "uint256" },
    { name: "maxFee", type: "uint256" },
    { name: "orderType", type: "uint8" },
    { name: "flags", type: "uint8" },
    { name: "nonce", type: "uint64" },
    { name: "deadline", type: "uint64" },
  ],
} as const;

type SignedOrder = {
  trader: Address;
  marketId: Hex;
  sizeDeltaE18: bigint;
  priceE18: bigint;
  maxFee: bigint;
  orderType: number;
  flags: number;
  nonce: bigint;
  deadline: bigint;
};

const deployer = privateKeyToAccount(DEPLOYER_PRIVATE_KEY);
const taker = privateKeyToAccount(derivePrivateKey("arc-perp-smoke:taker"));
const victim = privateKeyToAccount(derivePrivateKey("arc-perp-smoke:victim"));
const hedge = privateKeyToAccount(derivePrivateKey("arc-perp-smoke:hedge"));

const publicClient = createPublicClient({ chain: arcTestnet, transport: http(ARC_RPC_URL) });
const walletClient = createWalletClient({ account: deployer, chain: arcTestnet, transport: http(ARC_RPC_URL) });

async function main() {
  const chainId = await publicClient.getChainId();
  if (chainId !== arcTestnet.id) throw new Error(`wrong chain: ${chainId}`);

  console.log(`admin=${deployer.address}`);
  console.log(`taker=${taker.address}`);
  console.log(`victim=${victim.address}`);
  console.log(`hedge=${hedge.address}`);
  console.log(`perpConfig=${PERP_CONFIG_PATH}`);
  console.log(`perpConfigBlock=${perpConfig.exportedBlockNumber}`);
  console.log(`market=${eurcMarket.key} marketId=${MARKET_ID}`);

  const readiness = await assertFxPerpLiveReadiness(publicClient, perpRuntime);
  console.log(
    `readinessGate=passed contracts=${readiness.checkedContracts.length} markets=${readiness.checkedMarkets.length} protocolLiquidity=${readiness.protocolLiquidity}`,
  );

  await refreshPyth();
  const [midE18] = await publicClient.readContract({
    address: ADDR.oracle,
    abi: oracleAbi,
    functionName: "getMid",
    args: [ADDR.eurc, ADDR.usdc],
  });
  console.log(`oracleMidE18=${midE18}`);

  const [feeAmount, quotePrice] = await publicClient.readContract({
    address: ADDR.clearinghouse,
    abi: clearinghouseAbi,
    functionName: "quoteFee",
    args: [MARKET_ID, deployer.address, SIZE_E18],
  });
  console.log(`quoteFee fee=${feeAmount} priceE18=${quotePrice}`);

  await approveIfNeeded(ADDR.margin, HEALTHY_MARGIN * 2n + LIQUIDATION_MARGIN * 2n);
  await depositMargin(deployer.address, HEALTHY_MARGIN);
  await depositMargin(taker.address, HEALTHY_MARGIN);
  await depositMargin(victim.address, LIQUIDATION_MARGIN);
  await depositMargin(hedge.address, LIQUIDATION_MARGIN);

  const now = BigInt(Math.floor(Date.now() / 1000));
  const deadline = now + 3600n;
  const nonceBase = BigInt(Date.now());

  const makerOrder = order(deployer.address, SIZE_E18, quotePrice, feeAmount, nonceBase + 1n, deadline, FLAG_POST_ONLY);
  const takerOrder = order(taker.address, -SIZE_E18, quotePrice, feeAmount, nonceBase + 2n, deadline, 0);
  const makerSig = await signOrder(deployer, makerOrder);
  const takerSig = await signOrder(taker, takerOrder);
  console.log(`makerDigest=${await hashOrder(makerOrder)}`);
  console.log(`takerDigest=${await hashOrder(takerOrder)}`);
  const healthySettle = await walletClient.writeContract({
    address: ADDR.settlement,
    abi: settlementAbi,
    functionName: "settleMatch",
    args: [makerOrder, makerSig, takerOrder, takerSig, SIZE_E18, quotePrice],
  });
  await wait("healthy settleMatch", healthySettle);

  const fundingPoke = await walletClient.writeContract({
    address: ADDR.funding,
    abi: fundingAbi,
    functionName: "pokeFundingRate",
    args: [MARKET_ID],
  });
  await wait("pokeFundingRate", fundingPoke);
  const fundingState = await publicClient.readContract({
    address: ADDR.funding,
    abi: fundingAbi,
    functionName: "fundingState",
    args: [MARKET_ID],
  });
  console.log(
    `fundingState version=${fundingState[0]} rate=${fundingState[2]} cumulative=${fundingState[3]}`,
  );

  const liquidationEntryPrice = quotePrice * 50n;
  const liquidationMaxFee = feeAmount * 50n + 10_000n;
  const victimOrder =
    order(victim.address, SIZE_E18, liquidationEntryPrice, liquidationMaxFee, nonceBase + 3n, deadline, FLAG_POST_ONLY);
  const hedgeOrder =
    order(hedge.address, -SIZE_E18, liquidationEntryPrice, liquidationMaxFee, nonceBase + 4n, deadline, 0);
  const victimSig = await signOrder(victim, victimOrder);
  const hedgeSig = await signOrder(hedge, hedgeOrder);
  console.log(`victimDigest=${await hashOrder(victimOrder)}`);
  console.log(`hedgeDigest=${await hashOrder(hedgeOrder)}`);
  const liquidationSettle = await walletClient.writeContract({
    address: ADDR.settlement,
    abi: settlementAbi,
    functionName: "settleMatch",
    args: [victimOrder, victimSig, hedgeOrder, hedgeSig, SIZE_E18, liquidationEntryPrice],
  });
  await wait("liquidation-candidate settleMatch", liquidationSettle);

  await refreshPyth();
  const healthFactor = await publicClient.readContract({
    address: ADDR.health,
    abi: healthAbi,
    functionName: "healthFactor",
    args: [MARKET_ID, victim.address],
  });
  const liquidatable = await publicClient.readContract({
    address: ADDR.health,
    abi: healthAbi,
    functionName: "isLiquidatable",
    args: [MARKET_ID, victim.address],
  });
  console.log(`liquidationScanner victimHealthFactorBps=${healthFactor} liquidatable=${liquidatable}`);
  if (!liquidatable) throw new Error("liquidation scanner did not find the intentional candidate");

  await liquidateVictimPass("liquidate");
  let victimPosition = await readPosition(victim.address);
  for (let i = 0; i < 3 && victimPosition.sizeE18 !== 0n; i++) {
    await refreshPyth();
    const stillLiquidatable = await publicClient.readContract({
      address: ADDR.health,
      abi: healthAbi,
      functionName: "isLiquidatable",
      args: [MARKET_ID, victim.address],
    });
    if (!stillLiquidatable) break;
    console.log(`cleanupLiquidationPass=${i + 1} remainingSize=${victimPosition.sizeE18}`);
    await liquidateVictimPass(`cleanup liquidate ${i + 1}`);
    victimPosition = await readPosition(victim.address);
  }
  const longOi = await publicClient.readContract({
    address: ADDR.clearinghouse,
    abi: clearinghouseAbi,
    functionName: "openInterestLong",
    args: [MARKET_ID],
  });
  const shortOi = await publicClient.readContract({
    address: ADDR.clearinghouse,
    abi: clearinghouseAbi,
    functionName: "openInterestShort",
    args: [MARKET_ID],
  });
  const protocolLiquidity = await publicClient.readContract({
    address: ADDR.margin,
    abi: marginAbi,
    functionName: "protocolLiquidity",
  });
  console.log(`victimPositionAfter size=${victimPosition.sizeE18} reserved=${victimPosition.marginReserved}`);
  console.log(`openInterest long=${longOi} short=${shortOi}`);
  console.log(`protocolLiquidity=${protocolLiquidity}`);
}

async function refreshPyth() {
  const updateData = await fetchPythUpdate();
  const fee = await publicClient.readContract({
    address: ADDR.pyth,
    abi: pythAbi,
    functionName: "getUpdateFee",
    args: [updateData],
  });
  const hash = await walletClient.writeContract({
    address: ADDR.oracle,
    abi: oracleAbi,
    functionName: "getMidWithUpdatePyth",
    args: [ADDR.eurc, ADDR.usdc, updateData],
    value: fee,
  });
  await wait("oracle.getMidWithUpdatePyth", hash);
}

async function fetchPythUpdate(): Promise<Hex[]> {
  const url =
    `https://hermes.pyth.network/v2/updates/price/latest?ids[]=${FEEDS.usdc}&ids[]=${FEEDS.eurc}`;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), HERMES_TIMEOUT_MS);
  let response: Response;
  try {
    response = await fetch(url, { signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
  if (!response.ok) throw new Error(`pyth hermes ${response.status}: ${await response.text()}`);
  return parsePythUpdateBody(await response.json());
}

async function approveIfNeeded(spender: Address, amount: bigint) {
  const allowance = await publicClient.readContract({
    address: ADDR.usdc,
    abi: erc20Abi,
    functionName: "allowance",
    args: [deployer.address, spender],
  });
  if (allowance >= amount) return;
  const hash = await walletClient.writeContract({
    address: ADDR.usdc,
    abi: erc20Abi,
    functionName: "approve",
    args: [spender, amount],
  });
  await wait("USDC.approve margin", hash);
}

async function depositMargin(trader: Address, amount: bigint) {
  const hash = await walletClient.writeContract({
    address: ADDR.margin,
    abi: marginAbi,
    functionName: "depositMargin",
    args: [trader, amount],
  });
  await wait(`depositMargin ${trader}`, hash);
  const margin = await publicClient.readContract({
    address: ADDR.margin,
    abi: marginAbi,
    functionName: "marginOf",
    args: [trader],
  });
  const reserved = await publicClient.readContract({
    address: ADDR.margin,
    abi: marginAbi,
    functionName: "reservedMarginOf",
    args: [trader],
  });
  console.log(`margin trader=${trader} balance=${margin} reserved=${reserved}`);
}

async function liquidateVictimPass(label: string) {
  const position = await readPosition(victim.address);
  const maxClose = abs(position.sizeE18);
  if (maxClose === 0n) return;
  const redstoneFeeds = await redstoneFeedsForEurcMarket();

  const flagHash = await writeWithRedstone(walletClient, {
    address: ADDR.liquidation,
    abi: liquidationAbi,
    functionName: "flagAccount",
    args: [MARKET_ID, victim.address],
  }, redstoneFeeds);
  await wait(`${label} flagAccount`, flagHash);

  // Sprint-1 sets flagDelay >= 60s. Wait the configured delay (with a small
  // buffer) before issuing the liquidate, otherwise the engine reverts
  // FlagDelayPending. Reads the live config so it tracks future tunings.
  const liquidationConfig = (await publicClient.readContract({
    address: ADDR.liquidation,
    abi: liquidationAbi,
    functionName: "liquidationConfig",
  })) as readonly [number, bigint, bigint];
  const flagDelaySec = Number(liquidationConfig[2]);
  if (flagDelaySec > 0) {
    const waitMs = (flagDelaySec + 5) * 1000;
    console.log(`waiting ${waitMs / 1000}s for flagDelay to mature before liquidate`);
    await new Promise((resolve) => setTimeout(resolve, waitMs));
  }

  await refreshPyth();
  const liquidationHash = await writeWithRedstone(walletClient, {
    address: ADDR.liquidation,
    abi: liquidationAbi,
    functionName: "liquidate",
    args: [MARKET_ID, victim.address, maxClose],
  }, redstoneFeeds);
  await wait(label, liquidationHash);
}

async function redstoneFeedsForEurcMarket(): Promise<string[]> {
  const baseFeed = await publicClient.readContract({
    address: ADDR.oracle,
    abi: oracleAbi,
    functionName: "redstoneFeedOf",
    args: [ADDR.eurc],
  });
  const quoteFeed = await publicClient.readContract({
    address: ADDR.oracle,
    abi: oracleAbi,
    functionName: "redstoneFeedOf",
    args: [ADDR.usdc],
  });
  return uniqueStrings([redstoneFeedIdFromBytes32(baseFeed), redstoneFeedIdFromBytes32(quoteFeed)]);
}

async function readPosition(trader: Address) {
  return publicClient.readContract({
    address: ADDR.clearinghouse,
    abi: clearinghouseAbi,
    functionName: "position",
    args: [MARKET_ID, trader],
  });
}

function abs(value: bigint): bigint {
  return value < 0n ? -value : value;
}

function order(
  trader: Address,
  sizeDeltaE18: bigint,
  priceE18: bigint,
  maxFee: bigint,
  nonce: bigint,
  deadline: bigint,
  flags: number,
): SignedOrder {
  return {
    trader,
    marketId: MARKET_ID,
    sizeDeltaE18,
    priceE18,
    maxFee,
    orderType: ORDER_TYPE_LIMIT,
    flags,
    nonce,
    deadline,
  };
}

async function signOrder(account: typeof deployer, signedOrder: SignedOrder): Promise<Hex> {
  return account.signTypedData({
    domain: {
      name: "TelaranaFxOrderSettlement",
      version: "1",
      chainId: arcTestnet.id,
      verifyingContract: ADDR.settlement,
    },
    types: signedOrderTypes,
    primaryType: "SignedOrder",
    message: signedOrder,
  });
}

async function hashOrder(signedOrder: SignedOrder): Promise<Hex> {
  return publicClient.readContract({
    address: ADDR.settlement,
    abi: settlementAbi,
    functionName: "hashOrder",
    args: [signedOrder],
  });
}

async function wait(label: string, hash: Hex) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} reverted: ${hash}`);
  console.log(`${label} tx=${hash}`);
}

function derivePrivateKey(label: string): Hex {
  return keccak256(concatHex([DEPLOYER_PRIVATE_KEY, toHex(label)]));
}

function normalizePrivateKey(value: string | undefined): Hex {
  if (!value) throw new Error("DEPLOYER_PRIVATE_KEY is required");
  const normalized = value.startsWith("0x") ? value : `0x${value}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(normalized)) {
    throw new Error("DEPLOYER_PRIVATE_KEY must be a 32-byte hex string");
  }
  return normalized as Hex;
}

function parsePythUpdateBody(body: unknown): Hex[] {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new Error("pyth hermes response must be an object");
  }
  const binary = (body as Record<string, unknown>).binary;
  if (!binary || typeof binary !== "object" || Array.isArray(binary)) {
    throw new Error("pyth hermes response missing binary object");
  }
  const data = (binary as Record<string, unknown>).data;
  if (!Array.isArray(data) || data.length === 0) {
    throw new Error("pyth hermes returned no update data");
  }
  return data.map((item, index) => {
    if (typeof item !== "string") throw new Error(`pyth hermes update ${index} must be a string`);
    const normalized = item.startsWith("0x") ? item : `0x${item}`;
    if (normalized.length <= 2 || normalized.length % 2 !== 0 || !isHex(normalized, { strict: true })) {
      throw new Error(`pyth hermes update ${index} must be hex`);
    }
    return normalized as Hex;
  });
}

function requireAddress(value: Address | undefined, label: string): Address {
  if (!value) throw new Error(`${label} missing from SDK address registry`);
  return value;
}

function requireHex(value: Hex | undefined, label: string): Hex {
  if (!value) throw new Error(`${label} missing from SDK address registry`);
  return value;
}

function redstoneFeedIdFromBytes32(feedId: Hex): string {
  const hex = strip0x(feedId);
  const chars: string[] = [];
  for (let i = 0; i < hex.length; i += 2) {
    const byte = hex.slice(i, i + 2);
    if (byte === "00") break;
    chars.push(String.fromCharCode(Number.parseInt(byte, 16)));
  }
  const feed = chars.join("");
  if (!feed) throw new Error(`FxOracle returned empty RedStone feed id ${feedId}`);
  return feed;
}

function uniqueStrings(values: readonly string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    if (seen.has(value)) continue;
    seen.add(value);
    result.push(value);
  }
  return result;
}

function strip0x(value: Hex): string {
  return value.startsWith("0x") ? value.slice(2) : value;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
