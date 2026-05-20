// SPDX-License-Identifier: Apache-2.0
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import {
  concatHex,
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  defineChain,
  encodeFunctionData,
  http,
  isAddress,
  isHex,
  keccak256,
  parseAbi,
  parseAbiItem,
  parseEventLogs,
  stringToHex,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

import { ChainId, getAddresses } from "./addresses/index.js";
import {
  ALL_FX_PERP_MARKET_KEYS,
  FX_PERP_MARKET_KEYS,
  getFxPerpMarket,
  type FxPerpConfigManifest,
  type FxPerpMarketKey,
} from "./perps.js";
import {
  assertFxPerpLiveReadiness,
  loadFxPerpRuntimeConfig,
  type FxPerpRuntimeConfig,
} from "./perps-runtime.js";

export const DEFAULT_ARC_RPC_URL = "https://rpc.testnet.arc.network";
export const DEFAULT_KEEPER_STATE_PATH = ".keeper/perps-5042002-state.json";
export const DEFAULT_KEEPER_INTERVAL_MS = 30_000;
export const DEFAULT_FUNDING_MIN_INTERVAL_SECONDS = 60;
export const DEFAULT_SCAN_BLOCK_RANGE = 2_000n;
export const DEFAULT_CANARY_SIZE_E18 = 10_000_000_000_000_000n;

export const FX_PERP_KEEPER_COMPONENTS = ["matcher", "funding", "liquidation", "canary"] as const;
export type FxPerpKeeperComponent = (typeof FX_PERP_KEEPER_COMPONENTS)[number];

export type FxPerpLogLevel = "debug" | "info" | "warn" | "error";

export interface FxPerpStructuredLog {
  ts: string;
  level: FxPerpLogLevel;
  component: string;
  event: string;
  chainId?: number;
  [key: string]: unknown;
}

export interface FxPerpJsonLogger {
  debug(event: string, fields?: Record<string, unknown>): void;
  info(event: string, fields?: Record<string, unknown>): void;
  warn(event: string, fields?: Record<string, unknown>): void;
  error(event: string, fields?: Record<string, unknown>): void;
}

export interface FxPerpKeeperState {
  processedMatches: Record<string, FxPerpProcessedMatch>;
  liquidationScanFromBlock?: string;
}

export interface FxPerpProcessedMatch {
  status: "settled" | "skipped";
  txHash?: Hex;
  updatedAt: string;
}

export interface FxPerpSignedOrder {
  trader: Address;
  marketId: Hex;
  sizeDeltaE18: bigint;
  priceE18: bigint;
  maxFee: bigint;
  orderType: number;
  flags: number;
  nonce: bigint;
  deadline: bigint;
}

export interface FxPerpSignedOrderEnvelope {
  order: FxPerpSignedOrder;
  signature: Hex;
}

export interface FxPerpMatchIntent {
  id: Hex;
  maker: FxPerpSignedOrderEnvelope;
  taker: FxPerpSignedOrderEnvelope;
  fillSizeE18: bigint;
  fillPriceE18: bigint;
}

export interface FxPerpCandidateSet {
  [marketKey: string]: Address[];
}

export interface FxPerpKeeperContext {
  runtime: FxPerpRuntimeConfig;
  manifest: FxPerpConfigManifest;
  publicClient: PublicClient;
  walletClient?: WalletClient;
  account?: PrivateKeyAccount;
  logger: FxPerpJsonLogger;
  state: FxPerpKeeperState;
  statePath?: string;
  dryRun: boolean;
}

export interface CreateFxPerpKeeperContextOptions {
  arcRpcUrl?: string;
  configPath?: string;
  contractAddressesJson?: string;
  privateKey?: string;
  statePath?: string;
  dryRun?: boolean;
  logger?: FxPerpJsonLogger;
}

export interface FxPerpKeeperLoopOptions extends CreateFxPerpKeeperContextOptions {
  components?: readonly FxPerpKeeperComponent[];
  intervalMs?: number;
  once?: boolean;
  failOnError?: boolean;
  maxIterations?: number;
  fundingMinIntervalSeconds?: number;
  scanFromBlock?: bigint;
  scanBlockRange?: bigint;
  liquidationCandidates?: FxPerpCandidateSet;
  matches?: FxPerpMatchIntent[];
  matchFile?: string;
  matchJson?: string;
  canaryMarkets?: readonly FxPerpMarketKey[];
  canarySizeE18?: bigint;
  canaryRefreshPyth?: boolean;
  canaryRequireQuote?: boolean;
  signal?: AbortSignal;
}

export interface FxPerpFundingPokeResult {
  marketKey: FxPerpMarketKey;
  marketId: Hex;
  status: "poked" | "skipped";
  lastUpdate: bigint;
  currentVersion: bigint;
  txHash?: Hex;
}

export interface FxPerpLiquidationResult {
  marketKey: FxPerpMarketKey;
  marketId: Hex;
  trader: Address;
  /// `auto_rescinded` is the codex-r1 LOW path: keeper read lenient health,
  /// fired liquidate(), but the on-chain strict verified path said the
  /// position recovered. The contract emits `AccountFlagRescinded(auto_=true)`
  /// and returns early without liquidating. Ops dashboards MUST treat this
  /// as a non-liquidation (no bounty paid, no socialized loss) instead of
  /// classifying it as a successful liquidation.
  status:
    | "healthy"
    | "flagged"
    | "rescinded"
    | "liquidated"
    | "auto_rescinded"
    | "waiting_flag_delay"
    | "empty";
  healthFactor?: bigint;
  flaggedAt?: bigint;
  txHash?: Hex;
}

export interface FxPerpCanaryResult {
  marketKey: FxPerpMarketKey;
  marketId: Hex;
  quoteOk: boolean;
  feeAmount?: bigint;
  priceE18?: bigint;
  quoteError?: string;
  fundingVersion: bigint;
  openInterestLong: bigint;
  openInterestShort: bigint;
}

const arcTestnet = defineChain({
  id: ChainId.ArcTestnet,
  name: "Arc Testnet",
  nativeCurrency: { name: "Arc Testnet Gas", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [DEFAULT_ARC_RPC_URL] } },
});

const clearinghouseAbi = parseAbi([
  "function quoteFee(bytes32 marketId, address trader, int256 sizeDeltaE18) view returns (uint256 feeAmount, uint256 priceE18)",
  "function position(bytes32 marketId, address trader) view returns ((int256 sizeE18,uint256 entryPriceE18,uint256 marginReserved,uint64 lastFundingVersion))",
  "function openInterestLong(bytes32 marketId) view returns (uint256)",
  "function openInterestShort(bytes32 marketId) view returns (uint256)",
]);

const oracleAbi = parseAbi([
  "function getMidWithUpdatePyth(address base, address quote, bytes[] pythUpdate) payable returns (uint256 midE18,uint256 publishedAt)",
  "function redstoneFeedOf(address token) view returns (bytes32)",
]);

const pythAbi = parseAbi([
  "function getUpdateFee(bytes[] updateData) view returns (uint256)",
]);

const orderSettlementAbi = parseAbi([
  "function nonceBitmap(address trader, uint256 wordPos) view returns (uint256)",
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
  "function rescindFlag(bytes32 marketId, address trader)",
  "function flaggedAt(bytes32 marketId, address trader) view returns (uint256)",
  "function liquidate(bytes32 marketId, address trader, uint256 maxSizeToCloseAbsE18) returns (uint256 liquidatorReward,int256 socializedLoss)",
  "event AccountLiquidated(bytes32 indexed marketId, address indexed trader, address indexed liquidator, uint256 reward, int256 socializedLoss)",
  "event AccountFlagRescinded(bytes32 indexed marketId, address indexed trader, address indexed caller, bool auto_)",
]);

/// Selector strings used to classify a liquidate() receipt. The contract
/// emits AccountFlagRescinded(auto_=true) when the strict verified-oracle
/// path showed the position recovered between flag and trigger — the call
/// returns (0, 0) and does NOT revert, so we MUST inspect the logs rather
/// than treat tx success as a liquidation. Codex sprint-1 round 1 LOW.
const accountLiquidatedEvent = parseAbiItem(
  "event AccountLiquidated(bytes32 indexed marketId, address indexed trader, address indexed liquidator, uint256 reward, int256 socializedLoss)",
);
const accountFlagRescindedEvent = parseAbiItem(
  "event AccountFlagRescinded(bytes32 indexed marketId, address indexed trader, address indexed caller, bool auto_)",
);

const positionIncreasedEvent = parseAbiItem(
  "event PositionIncreased(bytes32 indexed marketId,address indexed trader,int256 sizeDeltaE18,int256 resultingSizeE18,uint256 entryPriceE18,uint256 marginReserved,uint256 fee)",
);
const positionDecreasedEvent = parseAbiItem(
  "event PositionDecreased(bytes32 indexed marketId,address indexed trader,int256 sizeDeltaE18,int256 resultingSizeE18,uint256 priceE18,uint256 marginReleased,int256 pnl,uint256 badDebt)",
);
const positionEventsAbi = [positionIncreasedEvent, positionDecreasedEvent] as const;
const REDSTONE_DATA_SERVICE_ID = "redstone-primary-prod";
const REDSTONE_UNIQUE_SIGNERS_COUNT = 3;
const REDSTONE_EVM_CONNECTOR_PACKAGE = "@redstone-finance/evm-connector";
const REDSTONE_SDK_PACKAGE = "@redstone-finance/sdk";
const PRIMARY_PROD_SIGNERS = [
  "0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774",
  "0xdEB22f54738d54976C4c0fe5ce6d408E40d88499",
  "0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202",
  "0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE",
  "0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de",
] as const;

export interface RedstoneWriteContractInput {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
}

type RedstoneDataServiceWrapper = {
  getBytesDataForAppending(): Promise<unknown>;
};

type RedstoneDataServiceWrapperConstructor = new (input: {
  dataServiceId: string;
  dataPackagesIds: readonly string[];
  uniqueSignersCount: number;
  authorizedSigners: readonly string[];
}) => RedstoneDataServiceWrapper;

export function createJsonLogger(component: string, sink: (line: string) => void = console.log): FxPerpJsonLogger {
  const write = (level: FxPerpLogLevel, event: string, fields: Record<string, unknown> = {}) => {
    const line: FxPerpStructuredLog = {
      ts: new Date().toISOString(),
      level,
      ...fields,
      component,
      event,
    };
    sink(JSON.stringify(line, jsonReplacer));
  };
  return {
    debug: (event, fields) => write("debug", event, fields),
    info: (event, fields) => write("info", event, fields),
    warn: (event, fields) => write("warn", event, fields),
    error: (event, fields) => write("error", event, fields),
  };
}

export async function writeWithRedstone(
  wallet: WalletClient,
  input: RedstoneWriteContractInput,
  feeds: readonly string[],
): Promise<Hex> {
  const encode = encodeFunctionData as (parameters: RedstoneWriteContractInput) => Hex;
  const data = encode(input);
  const payload = await fetchRedstonePayloadForFeeds(feeds);
  return (wallet as unknown as { sendTransaction(input: { to: Address; data: Hex }): Promise<Hex> }).sendTransaction({
    to: input.address,
    data: concatHex([data, payload]),
  });
}

export function keeperComponentsFromString(value: string | undefined): FxPerpKeeperComponent[] {
  const raw = value?.trim() ? value : "all";
  if (raw === "all") return [...FX_PERP_KEEPER_COMPONENTS];
  const components = raw.split(",").map((item) => item.trim()).filter(Boolean);
  if (components.length === 0) throw new Error("At least one keeper component is required");
  return components.map((component) => {
    if (!isFxPerpKeeperComponent(component)) throw new Error(`Unknown keeper component ${component}`);
    return component;
  });
}

export function marketKeysFromString(
  value: string | undefined,
  defaultKeys: readonly FxPerpMarketKey[],
): FxPerpMarketKey[] {
  if (!value?.trim()) return [...defaultKeys];
  if (value.trim() === "all") return [...FX_PERP_MARKET_KEYS];
  const keys = value.split(",").map((item) => item.trim()).filter(Boolean);
  if (keys.length === 0) return [...defaultKeys];
  return keys.map((key) => {
    if (!isFxPerpMarketKey(key)) throw new Error(`Unknown perp market key ${key}`);
    return key;
  });
}

export async function createFxPerpKeeperContext(
  options: CreateFxPerpKeeperContextOptions = {},
): Promise<FxPerpKeeperContext> {
  const arcRpcUrl = options.arcRpcUrl ?? DEFAULT_ARC_RPC_URL;
  const chain = {
    ...arcTestnet,
    rpcUrls: { default: { http: [arcRpcUrl] } },
  };
  const publicClient = createPublicClient({ chain, transport: http(arcRpcUrl) });
  const privateKey = options.privateKey ? normalizePrivateKey(options.privateKey) : undefined;
  const account = privateKey ? privateKeyToAccount(privateKey) : undefined;
  const walletClient = account ? createWalletClient({ account, chain, transport: http(arcRpcUrl) }) : undefined;
  const runtime = loadFxPerpRuntimeConfig({
    configPath: options.configPath,
    contractAddressesJson: options.contractAddressesJson,
  });
  if (!runtime.manifest) {
    throw new Error("Perp keeper requires deployments/perps-config-5042002.json, not address-only config");
  }

  const logger = options.logger ?? createJsonLogger("perp-keeper");
  const readiness = await assertFxPerpLiveReadiness(publicClient, runtime);
  logger.info("readiness_gate_passed", {
    chainId: readiness.chainId,
    checkedContracts: readiness.checkedContracts.length,
    checkedMarkets: readiness.checkedMarkets,
    protocolLiquidity: readiness.protocolLiquidity,
    totalAccountMargin: readiness.totalAccountMargin,
    marginUsdcBalance: readiness.marginUsdcBalance,
  });

  return {
    runtime,
    manifest: runtime.manifest,
    publicClient,
    walletClient,
    account,
    logger,
    state: loadKeeperState(options.statePath),
    statePath: options.statePath,
    dryRun: options.dryRun ?? false,
  };
}

export async function runFxPerpKeeperLoop(options: FxPerpKeeperLoopOptions = {}): Promise<void> {
  const components = options.components?.length
    ? [...options.components]
    : keeperComponentsFromString(process.env.PERP_KEEPER_COMPONENTS);
  const context = await createFxPerpKeeperContext(options);
  const intervalMs = options.intervalMs ?? DEFAULT_KEEPER_INTERVAL_MS;
  const once = options.once ?? false;
  const maxIterations = options.maxIterations;
  const failOnError = options.failOnError ?? once;
  let iteration = 0;

  context.logger.info("keeper_loop_started", {
    components,
    intervalMs,
    once,
    dryRun: context.dryRun,
    account: context.account?.address,
  });

  while (!options.signal?.aborted) {
    iteration += 1;
    await runFxPerpKeeperOnce(context, { ...options, components, failOnError, iteration });
    if (once || (maxIterations !== undefined && iteration >= maxIterations)) break;
    await sleep(intervalMs, options.signal);
  }

  context.logger.info("keeper_loop_stopped", { components, iterations: iteration });
}

export async function runFxPerpKeeperOnce(
  context: FxPerpKeeperContext,
  options: FxPerpKeeperLoopOptions & { iteration?: number } = {},
): Promise<void> {
  const components = options.components?.length
    ? [...options.components]
    : keeperComponentsFromString(process.env.PERP_KEEPER_COMPONENTS);
  context.logger.info("keeper_tick_started", { iteration: options.iteration, components });
  const errors: string[] = [];
  for (const component of components) {
    try {
      if (component === "matcher") {
        await settlePendingMatches(context, {
          matches: options.matches,
          matchFile: options.matchFile,
          matchJson: options.matchJson,
        });
      } else if (component === "funding") {
        await pokeDueFundingMarkets(context, {
          minIntervalSeconds: options.fundingMinIntervalSeconds ?? DEFAULT_FUNDING_MIN_INTERVAL_SECONDS,
        });
      } else if (component === "liquidation") {
        await runLiquidationScanner(context, {
          candidates: options.liquidationCandidates,
          fromBlock: options.scanFromBlock,
          blockRange: options.scanBlockRange ?? DEFAULT_SCAN_BLOCK_RANGE,
        });
      } else {
        await runCanarySmoke(context, {
          marketKeys: options.canaryMarkets,
          sizeE18: options.canarySizeE18 ?? DEFAULT_CANARY_SIZE_E18,
          refreshPyth: options.canaryRefreshPyth,
          requireQuote: options.canaryRequireQuote,
        });
      }
    } catch (error) {
      errors.push(`${component}: ${errorMessage(error)}`);
      context.logger.error("keeper_component_failed", {
        component,
        message: errorMessage(error),
      });
    }
  }
  saveKeeperState(context.statePath, context.state);
  context.logger.info("keeper_tick_finished", { iteration: options.iteration, components });
  if (errors.length !== 0 && options.failOnError) {
    throw new Error(`Keeper tick failed: ${errors.join("; ")}`);
  }
}

export async function settlePendingMatches(
  context: FxPerpKeeperContext,
  options: { matches?: FxPerpMatchIntent[]; matchFile?: string; matchJson?: string } = {},
): Promise<void> {
  const wallet = requireWallet(context, "matcher");
  const matches = options.matches ?? loadMatchIntents(options.matchJson, options.matchFile);
  if (matches.length === 0) {
    context.logger.info("matcher_no_matches");
    return;
  }

  for (const match of matches) {
    if (context.state.processedMatches[match.id]?.status === "settled") {
      context.logger.info("matcher_match_skipped", { matchId: match.id, reason: "state_already_settled" });
      continue;
    }
    const makerNonceUsed = await isNonceUsed(context, match.maker.order.trader, match.maker.order.nonce);
    const takerNonceUsed = await isNonceUsed(context, match.taker.order.trader, match.taker.order.nonce);
    if (makerNonceUsed || takerNonceUsed) {
      context.state.processedMatches[match.id] = { status: "skipped", updatedAt: new Date().toISOString() };
      context.logger.warn("matcher_match_skipped", {
        matchId: match.id,
        reason: "nonce_already_used",
        makerNonceUsed,
        takerNonceUsed,
      });
      continue;
    }

    context.logger.info("matcher_match_ready", {
      matchId: match.id,
      marketId: match.maker.order.marketId,
      maker: match.maker.order.trader,
      taker: match.taker.order.trader,
      fillSizeE18: match.fillSizeE18,
      fillPriceE18: match.fillPriceE18,
    });
    if (context.dryRun) continue;

    const hash = await write(wallet, {
      address: context.manifest.addresses.orderSettlement,
      abi: orderSettlementAbi,
      functionName: "settleMatch",
      args: [
        match.maker.order,
        match.maker.signature,
        match.taker.order,
        match.taker.signature,
        match.fillSizeE18,
        match.fillPriceE18,
      ],
    });
    await waitForSuccess(context, "matcher_settle_match", hash);
    context.state.processedMatches[match.id] = {
      status: "settled",
      txHash: hash,
      updatedAt: new Date().toISOString(),
    };
    context.logger.info("matcher_match_settled", { matchId: match.id, txHash: hash });
  }
}

export async function pokeDueFundingMarkets(
  context: FxPerpKeeperContext,
  options: { minIntervalSeconds?: number } = {},
): Promise<FxPerpFundingPokeResult[]> {
  const wallet = requireWallet(context, "funding");
  const minIntervalSeconds = BigInt(options.minIntervalSeconds ?? DEFAULT_FUNDING_MIN_INTERVAL_SECONDS);
  const latestBlock = await context.publicClient.getBlock();
  const nowTs = latestBlock.timestamp;
  const results: FxPerpFundingPokeResult[] = [];

  for (const marketKey of context.manifest.marketKeys) {
    const market = getFxPerpMarket(context.manifest, marketKey);
    const state = await readFundingState(context, market.marketId);
    const elapsed = nowTs > state.lastUpdate ? nowTs - state.lastUpdate : 0n;
    if (elapsed < minIntervalSeconds) {
      const skipped = {
        marketKey,
        marketId: market.marketId,
        status: "skipped" as const,
        lastUpdate: state.lastUpdate,
        currentVersion: state.currentVersion,
      };
      results.push(skipped);
      context.logger.info("funding_poke_skipped", { ...skipped, elapsed, minIntervalSeconds });
      continue;
    }

    context.logger.info("funding_poke_ready", {
      marketKey,
      marketId: market.marketId,
      elapsed,
      lastUpdate: state.lastUpdate,
      currentVersion: state.currentVersion,
    });
    if (context.dryRun) {
      results.push({
        marketKey,
        marketId: market.marketId,
        status: "skipped",
        lastUpdate: state.lastUpdate,
        currentVersion: state.currentVersion,
      });
      continue;
    }

    const hash = await write(wallet, {
      address: context.manifest.addresses.fundingEngine,
      abi: fundingAbi,
      functionName: "pokeFundingRate",
      args: [market.marketId],
    });
    await waitForSuccess(context, "funding_poke", hash);
    const after = await readFundingState(context, market.marketId);
    const result = {
      marketKey,
      marketId: market.marketId,
      status: "poked" as const,
      lastUpdate: after.lastUpdate,
      currentVersion: after.currentVersion,
      txHash: hash,
    };
    results.push(result);
    context.logger.info("funding_poked", result);
  }

  return results;
}

export async function runLiquidationScanner(
  context: FxPerpKeeperContext,
  options: { candidates?: FxPerpCandidateSet; fromBlock?: bigint; blockRange?: bigint } = {},
): Promise<FxPerpLiquidationResult[]> {
  const wallet = requireWallet(context, "liquidation");
  const candidates = mergeCandidateSets(
    options.candidates ?? parseLiquidationCandidates(process.env.PERP_LIQUIDATION_CANDIDATES),
    await scanPositionEventCandidates(context, options.fromBlock, options.blockRange ?? DEFAULT_SCAN_BLOCK_RANGE),
  );
  const results: FxPerpLiquidationResult[] = [];
  const latestBlock = await context.publicClient.getBlock();

  for (const marketKey of context.manifest.marketKeys) {
    const market = getFxPerpMarket(context.manifest, marketKey);
    for (const trader of uniqueAddresses(candidates[marketKey] ?? [])) {
      const position = await readPosition(context, market.marketId, trader);
      if (position.sizeE18 === 0n) {
        const empty = { marketKey, marketId: market.marketId, trader, status: "empty" as const };
        results.push(empty);
        context.logger.info("liquidation_candidate_empty", empty);
        continue;
      }

      const healthFactor = await readBigint(context.publicClient, context.manifest.addresses.healthChecker, healthAbi, "healthFactor", [
        market.marketId,
        trader,
      ]);
      const liquidatable = await readBool(context.publicClient, context.manifest.addresses.healthChecker, healthAbi, "isLiquidatable", [
        market.marketId,
        trader,
      ]);
      if (!liquidatable) {
        const flaggedAt = await readBigint(
          context.publicClient,
          context.manifest.addresses.liquidationEngine,
          liquidationAbi,
          "flaggedAt",
          [market.marketId, trader],
        );
        if (flaggedAt !== 0n && !context.dryRun) {
          const redstoneFeeds = await redstoneFeedsForMarket(context, market);
          const rescindHash = await writeWithRedstone(wallet, {
            address: context.manifest.addresses.liquidationEngine,
            abi: liquidationAbi,
            functionName: "rescindFlag",
            args: [market.marketId, trader],
          }, redstoneFeeds);
          await waitForSuccess(context, "liquidation_rescind_flag", rescindHash);
          const rescinded = { marketKey, marketId: market.marketId, trader, status: "rescinded" as const, healthFactor, flaggedAt: 0n, txHash: rescindHash };
          results.push(rescinded);
          context.logger.info("liquidation_flag_rescinded", { marketKey, marketId: market.marketId, trader, txHash: rescindHash });
        } else {
          const healthy = { marketKey, marketId: market.marketId, trader, status: "healthy" as const, healthFactor, flaggedAt };
          results.push(healthy);
          context.logger.info("liquidation_candidate_healthy", healthy);
        }
        continue;
      }

      let flaggedAt = await readBigint(
        context.publicClient,
        context.manifest.addresses.liquidationEngine,
        liquidationAbi,
        "flaggedAt",
        [market.marketId, trader],
      );
      if (flaggedAt === 0n) {
        context.logger.warn("liquidation_candidate_flag_ready", { marketKey, marketId: market.marketId, trader, healthFactor });
        if (!context.dryRun) {
          const redstoneFeeds = await redstoneFeedsForMarket(context, market);
          const flagHash = await writeWithRedstone(wallet, {
            address: context.manifest.addresses.liquidationEngine,
            abi: liquidationAbi,
            functionName: "flagAccount",
            args: [market.marketId, trader],
          }, redstoneFeeds);
          await waitForSuccess(context, "liquidation_flag", flagHash);
          flaggedAt = latestBlock.timestamp;
          results.push({ marketKey, marketId: market.marketId, trader, status: "flagged", healthFactor, flaggedAt, txHash: flagHash });
          context.logger.warn("liquidation_candidate_flagged", { marketKey, marketId: market.marketId, trader, txHash: flagHash });
        }
      }

      const readyAt = flaggedAt + context.manifest.liquidation.flagDelay;
      if (flaggedAt === 0n || latestBlock.timestamp < readyAt) {
        const waiting = { marketKey, marketId: market.marketId, trader, status: "waiting_flag_delay" as const, healthFactor, flaggedAt };
        results.push(waiting);
        context.logger.info("liquidation_waiting_flag_delay", { ...waiting, readyAt, nowTs: latestBlock.timestamp });
        continue;
      }

      const maxClose = abs(position.sizeE18);
      context.logger.warn("liquidation_ready", { marketKey, marketId: market.marketId, trader, healthFactor, maxClose });
      if (context.dryRun) {
        results.push({ marketKey, marketId: market.marketId, trader, status: "waiting_flag_delay", healthFactor, flaggedAt });
        continue;
      }
      const redstoneFeeds = await redstoneFeedsForMarket(context, market);
      const liquidationHash = await writeWithRedstone(wallet, {
        address: context.manifest.addresses.liquidationEngine,
        abi: liquidationAbi,
        functionName: "liquidate",
        args: [market.marketId, trader, maxClose],
      }, redstoneFeeds);
      const receipt = await waitForSuccess(context, "liquidation_execute", liquidationHash);
      // Codex sprint-1 round 1 LOW: the contract may auto-rescind a stale
      // flag instead of liquidating when the strict verified-oracle path
      // shows the position recovered. tx still succeeds, but no funds
      // moved. Classify by which event fired.
      const liquidationEngine = context.manifest.addresses.liquidationEngine.toLowerCase();
      const matchingLogs = receipt.logs.filter(
        (log) => log.address.toLowerCase() === liquidationEngine,
      );
      let autoRescinded = false;
      let trulyLiquidated = false;
      for (const log of matchingLogs) {
        try {
          const decoded = decodeEventLog({
            abi: [accountLiquidatedEvent, accountFlagRescindedEvent],
            data: log.data,
            topics: log.topics,
          });
          if (decoded.eventName === "AccountLiquidated") {
            trulyLiquidated = true;
          } else if (decoded.eventName === "AccountFlagRescinded" && decoded.args.auto_ === true) {
            autoRescinded = true;
          }
        } catch {
          // unrelated log on the engine address — skip silently.
        }
      }

      if (autoRescinded && !trulyLiquidated) {
        const rescinded = {
          marketKey,
          marketId: market.marketId,
          trader,
          status: "auto_rescinded" as const,
          healthFactor,
          flaggedAt: 0n, // contract cleared the flag in-tx
          txHash: liquidationHash,
        };
        results.push(rescinded);
        context.logger.warn("liquidation_auto_rescinded", rescinded);
        continue;
      }
      if (!trulyLiquidated) {
        // tx succeeded, neither event fired — abnormal. Surface loudly.
        throw new Error(
          `liquidate tx ${liquidationHash} succeeded without AccountLiquidated or AccountFlagRescinded`,
        );
      }
      const liquidated = {
        marketKey,
        marketId: market.marketId,
        trader,
        status: "liquidated" as const,
        healthFactor,
        flaggedAt,
        txHash: liquidationHash,
      };
      results.push(liquidated);
      context.logger.warn("liquidation_executed", liquidated);
    }
  }

  return results;
}

export async function runCanarySmoke(
  context: FxPerpKeeperContext,
  options: {
    marketKeys?: readonly FxPerpMarketKey[];
    sizeE18?: bigint;
    refreshPyth?: boolean;
    requireQuote?: boolean;
  } = {},
): Promise<FxPerpCanaryResult[]> {
  const readiness = await assertFxPerpLiveReadiness(context.publicClient, context.runtime);
  const sizeE18 = options.sizeE18 ?? DEFAULT_CANARY_SIZE_E18;
  const marketKeys = options.marketKeys?.length ? [...options.marketKeys] : ["EURC_USDC" as const];
  const results: FxPerpCanaryResult[] = [];
  let quoteFailures = 0;
  for (const marketKey of marketKeys) {
    const market = getFxPerpMarket(context.manifest, marketKey);
    if (options.refreshPyth) await refreshPythForMarket(context, marketKey);
    let quoteOk = false;
    let feeAmount: bigint | undefined;
    let priceE18: bigint | undefined;
    let quoteError: string | undefined;
    try {
      const quote = await readTuple(context.publicClient, context.manifest.addresses.clearinghouse, clearinghouseAbi, "quoteFee", [
        market.marketId,
        context.account?.address ?? context.manifest.keeper,
        sizeE18,
      ]);
      feeAmount = tupleBigint(quote, "feeAmount", 0);
      priceE18 = tupleBigint(quote, "priceE18", 1);
      quoteOk = true;
    } catch (error) {
      quoteFailures += 1;
      quoteError = errorSummary(error);
      context.logger.warn("canary_quote_unavailable", { marketKey, marketId: market.marketId, quoteError });
      if (options.requireQuote) throw error;
    }
    const fundingState = await readFundingState(context, market.marketId);
    const openInterestLong = await readBigint(
      context.publicClient,
      context.manifest.addresses.clearinghouse,
      clearinghouseAbi,
      "openInterestLong",
      [market.marketId],
    );
    const openInterestShort = await readBigint(
      context.publicClient,
      context.manifest.addresses.clearinghouse,
      clearinghouseAbi,
      "openInterestShort",
      [market.marketId],
    );
    const result = {
      marketKey,
      marketId: market.marketId,
      quoteOk,
      feeAmount,
      priceE18,
      quoteError,
      fundingVersion: fundingState.currentVersion,
      openInterestLong,
      openInterestShort,
    };
    results.push(result);
    context.logger.info("canary_market_checked", result);
  }
  context.logger.info("canary_smoke_finished", {
    chainId: readiness.chainId,
    protocolLiquidity: readiness.protocolLiquidity,
    totalAccountMargin: readiness.totalAccountMargin,
    marginUsdcBalance: readiness.marginUsdcBalance,
    markets: results.length,
    quoteFailures,
  });
  return results;
}

export function loadMatchIntents(matchJson?: string, matchFile?: string): FxPerpMatchIntent[] {
  const raw = matchJson ?? process.env.PERP_MATCHES_JSON ?? readOptionalMatchFile(matchFile ?? process.env.PERP_MATCHES_FILE);
  if (!raw?.trim()) return [];
  const records = raw.trim().startsWith("[")
    ? parseJsonArray(JSON.parse(raw) as unknown, "PERP_MATCHES_JSON")
    : raw.split(/\r?\n/).filter((line) => line.trim()).map((line) => JSON.parse(line) as unknown);
  return records.map(parseMatchIntent);
}

export function parseMatchIntent(input: unknown): FxPerpMatchIntent {
  const source = objectInput(input, "match");
  const maker = parseOrderEnvelope(source.maker, "maker");
  const taker = parseOrderEnvelope(source.taker, "taker");
  const fillSizeE18 = bigintInput(source.fillSizeE18, "fillSizeE18");
  const fillPriceE18 = bigintInput(source.fillPriceE18, "fillPriceE18");
  if (fillSizeE18 <= 0n) throw new Error("fillSizeE18 must be positive");
  if (fillPriceE18 <= 0n) throw new Error("fillPriceE18 must be positive");
  const id = source.id === undefined ? buildMatchId(maker, taker, fillSizeE18, fillPriceE18) : hexInput(source.id, "id", 32);
  return { id, maker, taker, fillSizeE18, fillPriceE18 };
}

export function parseLiquidationCandidates(raw: string | undefined): FxPerpCandidateSet {
  if (!raw?.trim()) return {};
  const parsed = JSON.parse(raw) as unknown;
  if (Array.isArray(parsed)) {
    return Object.fromEntries(ALL_FX_PERP_MARKET_KEYS.map((key) => [key, addressArray(parsed, key)]));
  }
  const source = objectInput(parsed, "PERP_LIQUIDATION_CANDIDATES");
  const candidates: FxPerpCandidateSet = {};
  for (const key of ALL_FX_PERP_MARKET_KEYS) {
    const value = source[key];
    if (value !== undefined) candidates[key] = addressArray(value, key);
  }
  return candidates;
}

export function loadKeeperState(path: string | undefined): FxPerpKeeperState {
  if (!path || !existsSync(path)) return { processedMatches: {} };
  const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
  const source = objectInput(parsed, "keeper state");
  const processedMatches = source.processedMatches && typeof source.processedMatches === "object" && !Array.isArray(source.processedMatches)
    ? (source.processedMatches as Record<string, FxPerpProcessedMatch>)
    : {};
  const liquidationScanFromBlock = typeof source.liquidationScanFromBlock === "string"
    ? source.liquidationScanFromBlock
    : undefined;
  return { processedMatches, liquidationScanFromBlock };
}

export function saveKeeperState(path: string | undefined, state: FxPerpKeeperState): void {
  if (!path) return;
  mkdirSync(dirname(path), { recursive: true });
  const tmpPath = `${path}.tmp`;
  writeFileSync(tmpPath, `${JSON.stringify(state, jsonReplacer, 2)}\n`);
  renameSync(tmpPath, path);
}

export function keeperOptionsFromEnv(env: Record<string, string | undefined> = process.env): FxPerpKeeperLoopOptions {
  const statePath = env.PERP_KEEPER_STATE_PATH ?? resolve(process.cwd(), DEFAULT_KEEPER_STATE_PATH);
  return {
    arcRpcUrl: env.ARC_RPC_URL ?? DEFAULT_ARC_RPC_URL,
    configPath: env.ARC_PERP_CONFIG_PATH,
    contractAddressesJson: env.CONTRACT_ADDRESSES_JSON,
    privateKey: env.PERP_KEEPER_PRIVATE_KEY ?? env.DEPLOYER_PRIVATE_KEY,
    statePath,
    dryRun: parseBoolean(env.PERP_DRY_RUN),
    intervalMs: parseOptionalNumber(env.PERP_KEEPER_INTERVAL_MS),
    once: parseBoolean(env.PERP_KEEPER_ONCE),
    maxIterations: parseOptionalNumber(env.PERP_KEEPER_MAX_ITERATIONS),
    fundingMinIntervalSeconds: parseOptionalNumber(env.PERP_FUNDING_MIN_INTERVAL_SECONDS),
    scanFromBlock: parseOptionalBigint(env.PERP_LIQUIDATION_SCAN_FROM_BLOCK),
    scanBlockRange: parseOptionalBigint(env.PERP_LIQUIDATION_SCAN_BLOCK_RANGE),
    liquidationCandidates: parseLiquidationCandidates(env.PERP_LIQUIDATION_CANDIDATES),
    matchFile: env.PERP_MATCHES_FILE,
    matchJson: env.PERP_MATCHES_JSON,
    canaryMarkets: marketKeysFromString(env.PERP_CANARY_MARKETS, ["EURC_USDC"]),
    canarySizeE18: parseOptionalBigint(env.PERP_CANARY_SIZE_E18),
    canaryRefreshPyth: parseBoolean(env.PERP_CANARY_REFRESH_PYTH),
    canaryRequireQuote: parseBoolean(env.PERP_CANARY_REQUIRE_QUOTE),
  };
}

async function refreshPythForMarket(context: FxPerpKeeperContext, marketKey: FxPerpMarketKey): Promise<void> {
  const wallet = requireWallet(context, "canary pyth refresh");
  const arc = getAddresses(ChainId.ArcTestnet);
  const pyth = arc.pyth;
  if (!pyth) throw new Error("Arc Pyth address missing from SDK registry");
  const baseFeed = pythFeedForMarket(arc, marketKey);
  const quoteFeed = arc.pythFeedUSDC;
  if (!baseFeed || !quoteFeed) throw new Error(`Pyth feed missing for ${marketKey}`);
  const updateData = await fetchPythUpdate([baseFeed, quoteFeed]);
  const fee = await readBigint(context.publicClient, pyth, pythAbi, "getUpdateFee", [updateData]);
  const market = getFxPerpMarket(context.manifest, marketKey);
  const hash = await write(wallet, {
    address: context.manifest.fxOracle,
    abi: oracleAbi,
    functionName: "getMidWithUpdatePyth",
    args: [market.baseToken, context.manifest.usdc, updateData],
    value: fee,
  });
  await waitForSuccess(context, "canary_pyth_refresh", hash);
  context.logger.info("canary_pyth_refreshed", { marketKey, txHash: hash, fee });
}

async function fetchPythUpdate(feedIds: readonly Hex[]): Promise<Hex[]> {
  const ids = feedIds.map((feed) => `ids[]=${strip0x(feed)}`).join("&");
  const response = await fetch(`https://hermes.pyth.network/v2/updates/price/latest?${ids}`);
  if (!response.ok) throw new Error(`pyth hermes ${response.status}: ${await response.text()}`);
  return parsePythUpdateBody(await response.json());
}

function pythFeedForMarket(arc: ReturnType<typeof getAddresses>, marketKey: FxPerpMarketKey): Hex | undefined {
  if (marketKey === "EURC_USDC") return arc.pythFeedEURC;
  if (marketKey === "TJPYC_USDC") return arc.stablecoinBasket?.jpyc.pythFeedId;
  if (marketKey === "TMXNB_USDC" || marketKey === "MXNB_USDC") return arc.stablecoinBasket?.mxnb.pythFeedId;
  return arc.stablecoinBasket?.zchf.pythFeedId;
}

function parsePythUpdateBody(body: unknown): Hex[] {
  const source = objectInput(body, "pyth hermes response");
  const binary = objectInput(source.binary, "pyth hermes binary");
  const data = binary.data;
  if (!Array.isArray(data) || data.length === 0) throw new Error("pyth hermes returned no update data");
  return data.map((item, index) => hexInput(item, `pyth update ${index}`));
}

async function scanPositionEventCandidates(
  context: FxPerpKeeperContext,
  fromBlockOption: bigint | undefined,
  blockRange: bigint,
): Promise<FxPerpCandidateSet> {
  const latest = await context.publicClient.getBlockNumber();
  const stateFrom = context.state.liquidationScanFromBlock ? BigInt(context.state.liquidationScanFromBlock) : undefined;
  const fromBlock = fromBlockOption ?? stateFrom ?? context.manifest.exportedBlockNumber;
  if (fromBlock > latest) return {};
  const toBlock = minBigint(latest, fromBlock + blockRange);
  const logs = await context.publicClient.getLogs({
    address: context.manifest.addresses.clearinghouse,
    fromBlock,
    toBlock,
  });
  context.state.liquidationScanFromBlock = (toBlock + 1n).toString();
  const parsed = parseEventLogs({
    abi: positionEventsAbi,
    logs,
    strict: false,
  });
  const candidates: FxPerpCandidateSet = {};
  for (const event of parsed) {
    const args = event.args;
    if (!args || typeof args !== "object") continue;
    const marketId = (args as Record<string, unknown>).marketId;
    const trader = (args as Record<string, unknown>).trader;
    if (typeof marketId !== "string" || typeof trader !== "string" || !isAddress(trader)) continue;
    const marketKey = marketKeyFromId(context.manifest, marketId as Hex);
    if (!marketKey) continue;
    candidates[marketKey] = [...(candidates[marketKey] ?? []), trader as Address];
  }
  context.logger.info("liquidation_event_scan_finished", { fromBlock, toBlock, logs: logs.length });
  return candidates;
}

async function readFundingState(context: FxPerpKeeperContext, marketId: Hex) {
  const tuple = await readTuple(context.publicClient, context.manifest.addresses.fundingEngine, fundingAbi, "fundingState", [marketId]);
  return {
    currentVersion: tupleBigint(tuple, "currentVersion", 0),
    lastUpdate: tupleBigint(tuple, "lastUpdate", 1),
    currentRateE18PerSecond: tupleBigint(tuple, "currentRateE18PerSecond", 2),
    cumulativeFundingE18: tupleBigint(tuple, "cumulativeFundingE18", 3),
  };
}

async function readPosition(context: FxPerpKeeperContext, marketId: Hex, trader: Address) {
  const tuple = await readTuple(context.publicClient, context.manifest.addresses.clearinghouse, clearinghouseAbi, "position", [
    marketId,
    trader,
  ]);
  return {
    sizeE18: tupleBigint(tuple, "sizeE18", 0),
    entryPriceE18: tupleBigint(tuple, "entryPriceE18", 1),
    marginReserved: tupleBigint(tuple, "marginReserved", 2),
    lastFundingVersion: tupleBigint(tuple, "lastFundingVersion", 3),
  };
}

async function isNonceUsed(context: FxPerpKeeperContext, trader: Address, nonce: bigint): Promise<boolean> {
  const wordPos = nonce >> 8n;
  const bit = 1n << (nonce & 255n);
  const bitmap = await readBigint(
    context.publicClient,
    context.manifest.addresses.orderSettlement,
    orderSettlementAbi,
    "nonceBitmap",
    [trader, wordPos],
  );
  return (bitmap & bit) !== 0n;
}

function parseOrderEnvelope(input: unknown, label: string): FxPerpSignedOrderEnvelope {
  const source = objectInput(input, label);
  return {
    order: parseSignedOrder(source.order, `${label}.order`),
    signature: hexInput(source.signature, `${label}.signature`),
  };
}

function parseSignedOrder(input: unknown, label: string): FxPerpSignedOrder {
  const source = objectInput(input, label);
  return {
    trader: addressInput(source.trader, `${label}.trader`),
    marketId: hexInput(source.marketId, `${label}.marketId`, 32),
    sizeDeltaE18: bigintInput(source.sizeDeltaE18, `${label}.sizeDeltaE18`),
    priceE18: bigintInput(source.priceE18, `${label}.priceE18`),
    maxFee: bigintInput(source.maxFee, `${label}.maxFee`),
    orderType: numberInput(source.orderType, `${label}.orderType`),
    flags: numberInput(source.flags, `${label}.flags`),
    nonce: bigintInput(source.nonce, `${label}.nonce`),
    deadline: bigintInput(source.deadline, `${label}.deadline`),
  };
}

function buildMatchId(
  maker: FxPerpSignedOrderEnvelope,
  taker: FxPerpSignedOrderEnvelope,
  fillSizeE18: bigint,
  fillPriceE18: bigint,
): Hex {
  return keccak256(stringToHex(JSON.stringify({ maker, taker, fillSizeE18, fillPriceE18 }, jsonReplacer)));
}

function mergeCandidateSets(a: FxPerpCandidateSet, b: FxPerpCandidateSet): FxPerpCandidateSet {
  const merged: FxPerpCandidateSet = {};
  for (const key of ALL_FX_PERP_MARKET_KEYS) {
    merged[key] = uniqueAddresses([...(a[key] ?? []), ...(b[key] ?? [])]);
  }
  return merged;
}

function uniqueAddresses(addresses: readonly Address[]): Address[] {
  const seen = new Set<string>();
  const result: Address[] = [];
  for (const address of addresses) {
    const key = address.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(address);
  }
  return result;
}

function marketKeyFromId(manifest: FxPerpConfigManifest, marketId: Hex): FxPerpMarketKey | undefined {
  return manifest.marketKeys.find((key) => getFxPerpMarket(manifest, key).marketId.toLowerCase() === marketId.toLowerCase());
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

function requireWallet(context: FxPerpKeeperContext, component: string): WalletClient {
  if (!context.walletClient) {
    throw new Error(`${component} requires PERP_KEEPER_PRIVATE_KEY or DEPLOYER_PRIVATE_KEY`);
  }
  return context.walletClient;
}

async function waitForSuccess(
  context: FxPerpKeeperContext,
  label: string,
  hash: Hex,
): Promise<Awaited<ReturnType<PublicClient["waitForTransactionReceipt"]>>> {
  const receipt = await context.publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} reverted: ${hash}`);
  context.logger.info("tx_confirmed", { label, txHash: hash, blockNumber: receipt.blockNumber });
  return receipt;
}

export async function redstoneFeedsForMarket(
  context: Pick<FxPerpKeeperContext, "publicClient" | "manifest">,
  market: Pick<FxPerpMarketManifestLike, "baseToken">,
): Promise<string[]> {
  const baseFeed = await readHex(context.publicClient, context.manifest.fxOracle, oracleAbi, "redstoneFeedOf", [
    market.baseToken,
  ]);
  const quoteFeed = await readHex(context.publicClient, context.manifest.fxOracle, oracleAbi, "redstoneFeedOf", [
    context.manifest.usdc,
  ]);
  return uniqueStrings([redstoneFeedIdFromBytes32(baseFeed), redstoneFeedIdFromBytes32(quoteFeed)]);
}

export async function fetchRedstonePayloadForFeeds(feeds: readonly string[]): Promise<Hex> {
  const dataPackagesIds = uniqueStrings(feeds.map((feed) => feed.trim()).filter(Boolean));
  if (dataPackagesIds.length === 0) throw new Error("RedStone payload requires at least one feed");

  const dataServiceId = process.env.REDSTONE_DATA_SERVICE_ID ?? REDSTONE_DATA_SERVICE_ID;
  const uniqueSignersCount = parseOptionalNumber(process.env.REDSTONE_UNIQUE_SIGNERS_COUNT) ?? REDSTONE_UNIQUE_SIGNERS_COUNT;
  const authorizedSigners = await redstoneAuthorizedSigners(dataServiceId);

  const connector = await importRedstoneModule(REDSTONE_EVM_CONNECTOR_PACKAGE);
  const wrapperConstructor = connector.DataServiceWrapper;
  if (typeof wrapperConstructor !== "function") {
    throw new Error("@redstone-finance/evm-connector does not export DataServiceWrapper");
  }

  const DataServiceWrapper = wrapperConstructor as RedstoneDataServiceWrapperConstructor;
  const wrapper = new DataServiceWrapper({
    dataServiceId,
    dataPackagesIds,
    uniqueSignersCount,
    authorizedSigners,
  });
  const payload = await wrapper.getBytesDataForAppending();
  if (typeof payload !== "string") throw new Error("RedStone SDK returned a non-string payload");
  return hexInput(payload, "RedStone payload");
}

async function redstoneAuthorizedSigners(dataServiceId: string): Promise<string[]> {
  const fromEnv = process.env.REDSTONE_AUTHORIZED_SIGNERS;
  if (fromEnv?.trim()) {
    return fromEnv.split(",").map((item) => item.trim()).filter(Boolean);
  }
  try {
    const sdk = await importRedstoneModule(REDSTONE_SDK_PACKAGE);
    const getSignersForDataServiceId = sdk.getSignersForDataServiceId;
    if (typeof getSignersForDataServiceId === "function") {
      return getSignersForDataServiceId(dataServiceId);
    }
  } catch (error) {
    if (dataServiceId !== REDSTONE_DATA_SERVICE_ID) throw error;
  }
  if (dataServiceId === REDSTONE_DATA_SERVICE_ID) return [...PRIMARY_PROD_SIGNERS];
  throw new Error(`RedStone SDK missing signer registry for ${dataServiceId}`);
}

async function importRedstoneModule(packageName: string): Promise<Record<string, unknown>> {
  try {
    return await import(packageName);
  } catch (error) {
    throw new Error(
      `Unable to import ${packageName}; install @redstone-finance/evm-connector and @redstone-finance/sdk for RedStone-wrapped keeper writes: ${errorSummary(error)}`,
    );
  }
}

interface FxPerpMarketManifestLike {
  baseToken: Address;
}

async function readBigint(
  client: PublicClient,
  address: Address,
  abi: ReturnType<typeof parseAbi>,
  functionName: string,
  args: readonly unknown[] = [],
): Promise<bigint> {
  const value = await read(client, address, abi, functionName, args);
  return integerToBigint(value);
}

async function readBool(
  client: PublicClient,
  address: Address,
  abi: ReturnType<typeof parseAbi>,
  functionName: string,
  args: readonly unknown[] = [],
): Promise<boolean> {
  const value = await read(client, address, abi, functionName, args);
  if (typeof value !== "boolean") throw new Error(`${functionName} returned non-bool ${String(value)}`);
  return value;
}

async function readHex(
  client: PublicClient,
  address: Address,
  abi: ReturnType<typeof parseAbi>,
  functionName: string,
  args: readonly unknown[] = [],
): Promise<Hex> {
  const value = await read(client, address, abi, functionName, args);
  if (typeof value !== "string" || !isHex(value, { strict: true })) {
    throw new Error(`${functionName} returned non-hex ${String(value)}`);
  }
  return value as Hex;
}

async function readTuple(
  client: PublicClient,
  address: Address,
  abi: ReturnType<typeof parseAbi>,
  functionName: string,
  args: readonly unknown[] = [],
): Promise<unknown> {
  return read(client, address, abi, functionName, args);
}

async function read(
  client: PublicClient,
  address: Address,
  abi: ReturnType<typeof parseAbi>,
  functionName: string,
  args: readonly unknown[] = [],
): Promise<unknown> {
  return (client as unknown as { readContract(input: unknown): Promise<unknown> }).readContract({
    address,
    abi,
    functionName,
    args,
  });
}

async function write(wallet: WalletClient, input: unknown): Promise<Hex> {
  return (wallet as unknown as { writeContract(input: unknown): Promise<Hex> }).writeContract(input);
}

function tupleBigint(tuple: unknown, key: string, index: number): bigint {
  if (Array.isArray(tuple)) return integerToBigint(tuple[index]);
  if (tuple && typeof tuple === "object") return integerToBigint((tuple as Record<string, unknown>)[key]);
  throw new Error(`Expected tuple object for ${key}`);
}

function integerToBigint(value: unknown): bigint {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isSafeInteger(value)) return BigInt(value);
  throw new Error(`Expected integer, got ${String(value)}`);
}

function readOptionalMatchFile(path: string | undefined): string | undefined {
  if (!path) return undefined;
  return readFileSync(path, "utf8");
}

function parseJsonArray(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${label} must be a JSON array`);
  return value;
}

function objectInput(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
  return value as Record<string, unknown>;
}

function addressInput(value: unknown, label: string): Address {
  if (typeof value !== "string" || !isAddress(value)) throw new Error(`${label} must be an EVM address`);
  return value as Address;
}

function addressArray(value: unknown, label: string): Address[] {
  if (!Array.isArray(value)) throw new Error(`${label} must be an address array`);
  return value.map((item, index) => addressInput(item, `${label}[${index}]`));
}

function hexInput(value: unknown, label: string, bytes?: number): Hex {
  if (typeof value !== "string") throw new Error(`${label} must be hex`);
  const normalized = value.startsWith("0x") ? value : `0x${value}`;
  if (!isHex(normalized, { strict: true })) throw new Error(`${label} must be hex`);
  if (bytes !== undefined && normalized.length !== 2 + bytes * 2) {
    throw new Error(`${label} must be ${bytes} bytes`);
  }
  return normalized as Hex;
}

function bigintInput(value: unknown, label: string): bigint {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isSafeInteger(value)) return BigInt(value);
  if (typeof value === "string" && /^-?\d+$/.test(value)) return BigInt(value);
  throw new Error(`${label} must be an integer string`);
}

function numberInput(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${label} must be a non-negative integer`);
  }
  return value;
}

function parseOptionalNumber(value: string | undefined): number | undefined {
  if (!value?.trim()) return undefined;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`${value} must be a non-negative integer`);
  return parsed;
}

function parseOptionalBigint(value: string | undefined): bigint | undefined {
  if (!value?.trim()) return undefined;
  if (!/^\d+$/.test(value)) throw new Error(`${value} must be a non-negative integer`);
  return BigInt(value);
}

function parseBoolean(value: string | undefined): boolean | undefined {
  if (value === undefined) return undefined;
  if (["1", "true", "yes", "y"].includes(value.toLowerCase())) return true;
  if (["0", "false", "no", "n"].includes(value.toLowerCase())) return false;
  throw new Error(`${value} must be boolean`);
}

function normalizePrivateKey(value: string): Hex {
  const normalized = value.startsWith("0x") ? value : `0x${value}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(normalized)) {
    throw new Error("private key must be a 32-byte hex string");
  }
  return normalized as Hex;
}

function isFxPerpKeeperComponent(value: string): value is FxPerpKeeperComponent {
  return (FX_PERP_KEEPER_COMPONENTS as readonly string[]).includes(value);
}

function isFxPerpMarketKey(value: string): value is FxPerpMarketKey {
  return (ALL_FX_PERP_MARKET_KEYS as readonly string[]).includes(value);
}

function abs(value: bigint): bigint {
  return value < 0n ? -value : value;
}

function minBigint(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}

function strip0x(value: Hex): string {
  return value.startsWith("0x") ? value.slice(2) : value;
}

function sleep(ms: number, signal: AbortSignal | undefined): Promise<void> {
  if (ms === 0) return Promise.resolve();
  return new Promise((resolveSleep) => {
    const timeout = setTimeout(resolveSleep, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(timeout);
      resolveSleep();
    }, { once: true });
  });
}

function jsonReplacer(_key: string, value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  return value;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function errorSummary(error: unknown): string {
  return errorMessage(error).split("\n")[0] ?? String(error);
}
