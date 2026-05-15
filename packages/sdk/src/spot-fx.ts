// SPDX-License-Identifier: Apache-2.0
import type { Address, Hex } from "viem";

import { ChainId, type ChainIdValue } from "./addresses/index.js";

export type TelaranaRequesterKind =
  | "internal"
  | "bufx"
  | "rfq-pasillo"
  | "partner";

export type SpotFxExecutionStatus =
  | "draft"
  | "requested"
  | "quoted"
  | "accepted"
  | "executed"
  | "cancelled"
  | "expired"
  | "failed";

export type SpotFxRequest = {
  requestId: string;
  requester: `0x${string}`;
  requesterKind: TelaranaRequesterKind;
  tokenIn: `0x${string}`;
  tokenOut: `0x${string}`;
  amountIn: bigint;
  minAmountOut: bigint;
  routeId: string;
  recipient: `0x${string}`;
  deadline: number;
  status: SpotFxExecutionStatus;
  metadataRef?: string;
};

export type SpotFxRouteKind =
  | "uniswap-v4-spot"
  | "rfq-pasillo"
  | "internal-test";

export type SpotFxRouteStatus =
  | "planned"
  | "configured"
  | "deployed"
  | "disabled";

export type SpotFxTokenPairConfig = {
  pairId: string;
  chainId: ChainIdValue;
  baseSymbol: string;
  quoteSymbol: string;
  tokenIn: Address;
  tokenOut: Address;
  tokenInDecimals: number;
  tokenOutDecimals: number;
  enabled: boolean;
  notes?: string;
};

export type SpotFxHookConfig = {
  hookConfigId: string;
  chainId: ChainIdValue;
  hook?: Address;
  status: SpotFxRouteStatus;
  kind: "placeholder" | "fx-swap-hook";
  permissions: readonly (
    | "beforeInitialize"
    | "afterInitialize"
    | "beforeSwap"
    | "afterSwap"
    | "beforeAddLiquidity"
    | "afterAddLiquidity"
    | "beforeRemoveLiquidity"
    | "afterRemoveLiquidity"
  )[];
  notes?: string;
};

export type SpotFxPoolConfig = {
  poolConfigId: string;
  chainId: ChainIdValue;
  poolManager?: Address;
  poolId?: Hex;
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hookConfigId?: string;
  hook?: Address;
  status: SpotFxRouteStatus;
  notes?: string;
};

export type TelaranaWhitelistedRequester = {
  requester: Address;
  requesterKind: TelaranaRequesterKind;
  allowed: boolean;
  label: string;
  metadataRef?: string;
};

export type SpotFxRouteConfig = {
  routeId: string;
  chainId: ChainIdValue;
  kind: SpotFxRouteKind;
  status: SpotFxRouteStatus;
  tokenIn: Address;
  tokenOut: Address;
  poolConfigId?: string;
  hookConfigId?: string;
  whitelistedCallers: readonly Address[];
  notes?: string;
};

export type TelaranaIndexerFieldType =
  | "address"
  | "bytes32"
  | "uint24"
  | "int24"
  | "uint256"
  | "bool"
  | "enum";

export type TelaranaIndexerEventName =
  | "SpotFxRequestCreated"
  | "SpotFxRequestAccepted"
  | "SpotFxRequestExecuted"
  | "SpotFxRequestCancelled"
  | "RfqQuoteRequested"
  | "RfqQuoteAccepted"
  | "RfqQuoteFilled"
  | "WhitelistedRequesterUpdated"
  | "RouteConfigured"
  | "PoolConfigured";

export type TelaranaIndexerEventField = {
  name: string;
  type: TelaranaIndexerFieldType;
  indexed: boolean;
};

export type TelaranaIndexerEventSchema = {
  name: TelaranaIndexerEventName;
  version: 1;
  fields: readonly TelaranaIndexerEventField[];
};

export const TELARANA_SPOT_FX_EVENT_NAMES = [
  "SpotFxRequestCreated",
  "SpotFxRequestAccepted",
  "SpotFxRequestExecuted",
  "SpotFxRequestCancelled",
  "RfqQuoteRequested",
  "RfqQuoteAccepted",
  "RfqQuoteFilled",
  "WhitelistedRequesterUpdated",
  "RouteConfigured",
  "PoolConfigured",
] as const satisfies readonly TelaranaIndexerEventName[];

export const TELARANA_SPOT_FX_INDEXER_SCHEMA = [
  {
    name: "SpotFxRequestCreated",
    version: 1,
    fields: [
      { name: "requestId", type: "bytes32", indexed: true },
      { name: "requester", type: "address", indexed: true },
      { name: "requesterKind", type: "enum", indexed: false },
      { name: "tokenIn", type: "address", indexed: false },
      { name: "tokenOut", type: "address", indexed: false },
      { name: "amountIn", type: "uint256", indexed: false },
      { name: "minAmountOut", type: "uint256", indexed: false },
      { name: "routeId", type: "bytes32", indexed: false },
      { name: "recipient", type: "address", indexed: false },
      { name: "deadline", type: "uint256", indexed: false },
      { name: "metadataRef", type: "bytes32", indexed: false },
    ],
  },
  {
    name: "SpotFxRequestAccepted",
    version: 1,
    fields: [
      { name: "requestId", type: "bytes32", indexed: true },
      { name: "accepter", type: "address", indexed: true },
      { name: "amountOut", type: "uint256", indexed: false },
    ],
  },
  {
    name: "SpotFxRequestExecuted",
    version: 1,
    fields: [
      { name: "requestId", type: "bytes32", indexed: true },
      { name: "executor", type: "address", indexed: true },
      { name: "amountOut", type: "uint256", indexed: false },
    ],
  },
  {
    name: "SpotFxRequestCancelled",
    version: 1,
    fields: [
      { name: "requestId", type: "bytes32", indexed: true },
      { name: "requester", type: "address", indexed: true },
    ],
  },
  {
    name: "WhitelistedRequesterUpdated",
    version: 1,
    fields: [
      { name: "requester", type: "address", indexed: true },
      { name: "requesterKind", type: "enum", indexed: false },
      { name: "allowed", type: "bool", indexed: false },
    ],
  },
  {
    name: "RouteConfigured",
    version: 1,
    fields: [
      { name: "routeId", type: "bytes32", indexed: true },
      { name: "tokenIn", type: "address", indexed: false },
      { name: "tokenOut", type: "address", indexed: false },
      { name: "poolId", type: "bytes32", indexed: false },
      { name: "hook", type: "address", indexed: false },
      { name: "whitelistedCaller", type: "address", indexed: false },
      { name: "enabled", type: "bool", indexed: false },
      { name: "metadataRef", type: "bytes32", indexed: false },
    ],
  },
  {
    name: "PoolConfigured",
    version: 1,
    fields: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "token0", type: "address", indexed: false },
      { name: "token1", type: "address", indexed: false },
      { name: "fee", type: "uint24", indexed: false },
      { name: "tickSpacing", type: "int24", indexed: false },
      { name: "hook", type: "address", indexed: false },
      { name: "metadataRef", type: "bytes32", indexed: false },
    ],
  },
] as const satisfies readonly TelaranaIndexerEventSchema[];

export const TELARANA_AVALANCHE_SPOT_TOKEN_PAIRS = [
  {
    pairId: "avalanche-mainnet-usdc-jpyc",
    chainId: ChainId.AvalancheMainnet,
    baseSymbol: "USDC",
    quoteSymbol: "JPYC",
    tokenIn: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    tokenOut: "0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB",
    tokenInDecimals: 6,
    tokenOutDecimals: 18,
    enabled: false,
    notes: "Future Uniswap v4 spot route; no production hook execution yet.",
  },
  {
    pairId: "avalanche-mainnet-usdc-mxnb",
    chainId: ChainId.AvalancheMainnet,
    baseSymbol: "USDC",
    quoteSymbol: "MXNB",
    tokenIn: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    tokenOut: "0xF197FFC28c23E0309B5559e7a166f2c6164C80aA",
    tokenInDecimals: 6,
    tokenOutDecimals: 6,
    enabled: false,
  },
  {
    pairId: "avalanche-mainnet-usdc-audf",
    chainId: ChainId.AvalancheMainnet,
    baseSymbol: "USDC",
    quoteSymbol: "AUDF",
    tokenIn: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    tokenOut: "0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b",
    tokenInDecimals: 6,
    tokenOutDecimals: 6,
    enabled: false,
  },
  {
    pairId: "avalanche-mainnet-usdc-krw1",
    chainId: ChainId.AvalancheMainnet,
    baseSymbol: "USDC",
    quoteSymbol: "KRW1",
    tokenIn: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    tokenOut: "0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318",
    tokenInDecimals: 6,
    tokenOutDecimals: 0,
    enabled: false,
  },
  {
    pairId: "avalanche-mainnet-usdc-zchf",
    chainId: ChainId.AvalancheMainnet,
    baseSymbol: "USDC",
    quoteSymbol: "ZCHF",
    tokenIn: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    tokenOut: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
    tokenInDecimals: 6,
    tokenOutDecimals: 18,
    enabled: false,
  },
] as const satisfies readonly SpotFxTokenPairConfig[];

export const TELARANA_FUJI_SPOT_TOKEN_PAIRS = [
  {
    pairId: "avalanche-fuji-usdc-eurc",
    chainId: ChainId.AvalancheFuji,
    baseSymbol: "USDC",
    quoteSymbol: "EURC",
    tokenIn: "0x5425890298aed601595a70AB815c96711a31Bc65",
    tokenOut: "0x5E44db7996c682E92a960b65AC713a54AD815c6B",
    tokenInDecimals: 6,
    tokenOutDecimals: 6,
    enabled: true,
    notes: "Demo pair for Fuji handoff; route execution remains registry/hook dependent.",
  },
] as const satisfies readonly SpotFxTokenPairConfig[];

export const TELARANA_SPOT_HOOK_CONFIGS = [
  {
    hookConfigId: "future-v4-spot-hook",
    chainId: ChainId.AvalancheMainnet,
    status: "planned",
    kind: "placeholder",
    permissions: ["beforeInitialize", "beforeSwap", "afterSwap"],
    notes: "Placeholder only. Do not treat as deployed execution code.",
  },
  {
    hookConfigId: "fuji-v4-spot-placeholder",
    chainId: ChainId.AvalancheFuji,
    status: "planned",
    kind: "placeholder",
    permissions: ["beforeInitialize", "beforeSwap", "afterSwap"],
  },
] as const satisfies readonly SpotFxHookConfig[];

export const TELARANA_SPOT_POOL_CONFIGS = [
  {
    poolConfigId: "fuji-usdc-eurc-v4-placeholder",
    chainId: ChainId.AvalancheFuji,
    currency0: "0x5425890298aed601595a70AB815c96711a31Bc65",
    currency1: "0x5E44db7996c682E92a960b65AC713a54AD815c6B",
    fee: 3000,
    tickSpacing: 60,
    hookConfigId: "fuji-v4-spot-placeholder",
    status: "planned",
  },
] as const satisfies readonly SpotFxPoolConfig[];

export const TELARANA_SPOT_ROUTE_CONFIGS = [
  {
    routeId: "fuji-usdc-eurc-spot-demo",
    chainId: ChainId.AvalancheFuji,
    kind: "internal-test",
    status: "configured",
    tokenIn: "0x5425890298aed601595a70AB815c96711a31Bc65",
    tokenOut: "0x5E44db7996c682E92a960b65AC713a54AD815c6B",
    poolConfigId: "fuji-usdc-eurc-v4-placeholder",
    hookConfigId: "fuji-v4-spot-placeholder",
    whitelistedCallers: [],
    notes: "Internal test route metadata for handoff; not a live swap executor.",
  },
  {
    routeId: "avalanche-mainnet-usdc-jpyc-spot",
    chainId: ChainId.AvalancheMainnet,
    kind: "uniswap-v4-spot",
    status: "planned",
    tokenIn: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    tokenOut: "0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB",
    hookConfigId: "future-v4-spot-hook",
    whitelistedCallers: [],
  },
] as const satisfies readonly SpotFxRouteConfig[];
