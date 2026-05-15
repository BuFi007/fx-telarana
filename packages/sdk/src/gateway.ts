// SPDX-License-Identifier: Apache-2.0
import {
  encodeFunctionData,
  getAddress,
  isAddress,
  pad,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";

import { ChainId, type ChainIdValue } from "./addresses/index.js";

export type CircleGatewayNetwork = "testnet" | "mainnet";

export type CircleGatewaySignerMode = "eoa" | "erc1271-contract-future";

export type GatewayHubTransferStatus =
  | "draft"
  | "deposit-required"
  | "ready-to-sign"
  | "signing"
  | "attesting"
  | "mint-ready"
  | "minted"
  | "settled"
  | "cancelled"
  | "failed";

export type GatewayHubAction =
  | "mint-to-hub"
  | "mint-and-request-spot-fx";

export type CircleGatewayChainConfig = {
  chainId: ChainIdValue;
  label: string;
  environment: CircleGatewayNetwork;
  domain: number;
  usdc: Address;
  gatewayWallet: Address;
  gatewayMinter: Address;
  apiBaseUrl: string;
};

export type GatewayHubRouteConfig = {
  routeId: string;
  label: string;
  environment: CircleGatewayNetwork;
  sourceHubChainId: ChainIdValue;
  destinationHubChainId: ChainIdValue;
  sourceDomain: number;
  destinationDomain: number;
  sourceUsdc: Address;
  destinationUsdc: Address;
  sourceGatewayWallet: Address;
  destinationGatewayMinter: Address;
  signerMode: CircleGatewaySignerMode;
  supportedActions: readonly GatewayHubAction[];
  destinationHub?: Address;
  destinationGatewayHook?: Address;
  whitelistedCaller?: Address;
  metadataRef?: string;
};

export type GatewayTransferSpec = {
  version: number;
  sourceDomain: number;
  destinationDomain: number;
  sourceContract: Hex;
  destinationContract: Hex;
  sourceToken: Hex;
  destinationToken: Hex;
  sourceDepositor: Hex;
  destinationRecipient: Hex;
  sourceSigner: Hex;
  destinationCaller: Hex;
  value: bigint;
  salt: Hex;
  hookData: Hex;
};

export type GatewayBurnIntent = {
  maxBlockHeight: bigint;
  maxFee: bigint;
  spec: GatewayTransferSpec;
};

export type BuildGatewayBurnIntentInput = {
  route: GatewayHubRouteConfig;
  amount: bigint;
  sourceDepositor: Address;
  sourceSigner: Address;
  destinationRecipient: Address;
  maxBlockHeight: bigint;
  salt: Hex;
  maxFee?: bigint;
  destinationCaller?: Address;
  hookData?: Hex;
  version?: number;
};

export type GatewayHubAtomicFxRequest = {
  requestId: string;
  sourceHubChainId: ChainIdValue;
  destinationHubChainId: ChainIdValue;
  sourceDomain: number;
  destinationDomain: number;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  minAmountOut: bigint;
  routeId: string;
  sourceDepositor: Address;
  sourceSigner: Address;
  destinationRecipient: Address;
  deadline: number;
  status: GatewayHubTransferStatus;
  metadataRef?: string;
};

export type GatewayHubMintContext = {
  routeId: Hex;
  requestId: Hex;
  action: GatewayHubAction;
  sourceDepositor: Address;
  sourceSigner: Address;
  recipient: Address;
  tokenOut?: Address;
  amount: bigint;
  minAmountOut?: bigint;
  spotRouteId?: Hex;
  metadataRef?: Hex;
  hookData?: Hex;
};

export type GatewayIndexerEventName =
  | "GatewayHubRouteConfigured"
  | "GatewayHubTransferRequested"
  | "GatewayHubBurnIntentSigned"
  | "GatewayHubMintAttested"
  | "GatewayHubLiquidityReceived"
  | "GatewayAtomicFxSwapRequested"
  | "GatewayAtomicFxSwapSettled"
  | "GatewaySignerModeUpdated";

export type GatewayIndexerEventSchema = {
  name: GatewayIndexerEventName;
  indexed: readonly string[];
  data: readonly string[];
};

export const CIRCLE_GATEWAY_TESTNET_API =
  "https://gateway-api-testnet.circle.com/v1";

export const CIRCLE_GATEWAY_MAINNET_API =
  "https://gateway-api.circle.com/v1";

export const CIRCLE_GATEWAY_TESTNET_WALLET =
  "0x0077777d7EBA4688BDeF3E311b846F25870A19B9" as const satisfies Address;

export const CIRCLE_GATEWAY_TESTNET_MINTER =
  "0x0022222ABE238Cc2C7Bb1f21003F0a260052475B" as const satisfies Address;

export const CIRCLE_GATEWAY_MAINNET_WALLET =
  "0x77777777Dcc4d5A2b6e418Fd04D8997ef11000eE" as const satisfies Address;

export const CIRCLE_GATEWAY_MAINNET_MINTER =
  "0x2222222d7164433c4C09B0b0D809a9b52C04C205" as const satisfies Address;

export const GATEWAY_DEFAULT_MAX_FEE = 2_010000n;

export const GATEWAY_HUB_ACTION_IDS = {
  "mint-to-hub": 0,
  "mint-and-request-spot-fx": 1,
} as const satisfies Record<GatewayHubAction, number>;

export const GATEWAY_SIGNER_MODE_IDS = {
  eoa: 0,
  "erc1271-contract-future": 1,
} as const satisfies Record<CircleGatewaySignerMode, number>;

export const GATEWAY_EIP712_DOMAIN = {
  name: "GatewayWallet",
  version: "1",
} as const;

export const GATEWAY_EIP712_TYPES = {
  TransferSpec: [
    { name: "version", type: "uint32" },
    { name: "sourceDomain", type: "uint32" },
    { name: "destinationDomain", type: "uint32" },
    { name: "sourceContract", type: "bytes32" },
    { name: "destinationContract", type: "bytes32" },
    { name: "sourceToken", type: "bytes32" },
    { name: "destinationToken", type: "bytes32" },
    { name: "sourceDepositor", type: "bytes32" },
    { name: "destinationRecipient", type: "bytes32" },
    { name: "sourceSigner", type: "bytes32" },
    { name: "destinationCaller", type: "bytes32" },
    { name: "value", type: "uint256" },
    { name: "salt", type: "bytes32" },
    { name: "hookData", type: "bytes" },
  ],
  BurnIntent: [
    { name: "maxBlockHeight", type: "uint256" },
    { name: "maxFee", type: "uint256" },
    { name: "spec", type: "TransferSpec" },
  ],
} as const;

export const CircleGatewayWalletAbi = [
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "value", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "depositFor",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "depositor", type: "address" },
      { name: "value", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "addDelegate",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "delegate", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "removeDelegate",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "delegate", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "isAuthorizedForBalance",
    stateMutability: "view",
    inputs: [
      { name: "token", type: "address" },
      { name: "depositor", type: "address" },
      { name: "addr", type: "address" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "availableBalance",
    stateMutability: "view",
    inputs: [
      { name: "token", type: "address" },
      { name: "depositor", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export const CircleGatewayMinterAbi = [
  {
    type: "function",
    name: "gatewayMint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "attestationPayload", type: "bytes" },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

export const TELARANA_GATEWAY_TESTNET_CHAINS = [
  {
    chainId: ChainId.AvalancheFuji,
    label: "Avalanche Fuji hub",
    environment: "testnet",
    domain: 1,
    usdc: "0x5425890298aed601595a70AB815c96711a31Bc65",
    gatewayWallet: CIRCLE_GATEWAY_TESTNET_WALLET,
    gatewayMinter: CIRCLE_GATEWAY_TESTNET_MINTER,
    apiBaseUrl: CIRCLE_GATEWAY_TESTNET_API,
  },
  {
    chainId: ChainId.ArcTestnet,
    label: "Arc Testnet hub",
    environment: "testnet",
    domain: 26,
    usdc: "0x3600000000000000000000000000000000000000",
    gatewayWallet: CIRCLE_GATEWAY_TESTNET_WALLET,
    gatewayMinter: CIRCLE_GATEWAY_TESTNET_MINTER,
    apiBaseUrl: CIRCLE_GATEWAY_TESTNET_API,
  },
] as const satisfies readonly CircleGatewayChainConfig[];

export const TELARANA_GATEWAY_MAINNET_CHAINS = [
  {
    chainId: ChainId.AvalancheMainnet,
    label: "Avalanche mainnet hub",
    environment: "mainnet",
    domain: 1,
    usdc: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    gatewayWallet: CIRCLE_GATEWAY_MAINNET_WALLET,
    gatewayMinter: CIRCLE_GATEWAY_MAINNET_MINTER,
    apiBaseUrl: CIRCLE_GATEWAY_MAINNET_API,
  },
] as const satisfies readonly CircleGatewayChainConfig[];

export const TELARANA_GATEWAY_HUB_ROUTES = [
  {
    routeId: "gateway-fuji-to-arc-usdc",
    label: "Fuji hub to Arc Testnet hub USDC",
    environment: "testnet",
    sourceHubChainId: ChainId.AvalancheFuji,
    destinationHubChainId: ChainId.ArcTestnet,
    sourceDomain: 1,
    destinationDomain: 26,
    sourceUsdc: "0x5425890298aed601595a70AB815c96711a31Bc65",
    destinationUsdc: "0x3600000000000000000000000000000000000000",
    sourceGatewayWallet: CIRCLE_GATEWAY_TESTNET_WALLET,
    destinationGatewayMinter: CIRCLE_GATEWAY_TESTNET_MINTER,
    signerMode: "eoa",
    supportedActions: ["mint-to-hub", "mint-and-request-spot-fx"],
    metadataRef: "telarana-gateway-fuji-arc-v0",
  },
  {
    routeId: "gateway-arc-to-fuji-usdc",
    label: "Arc Testnet hub to Fuji hub USDC",
    environment: "testnet",
    sourceHubChainId: ChainId.ArcTestnet,
    destinationHubChainId: ChainId.AvalancheFuji,
    sourceDomain: 26,
    destinationDomain: 1,
    sourceUsdc: "0x3600000000000000000000000000000000000000",
    destinationUsdc: "0x5425890298aed601595a70AB815c96711a31Bc65",
    sourceGatewayWallet: CIRCLE_GATEWAY_TESTNET_WALLET,
    destinationGatewayMinter: CIRCLE_GATEWAY_TESTNET_MINTER,
    signerMode: "eoa",
    supportedActions: ["mint-to-hub", "mint-and-request-spot-fx"],
    metadataRef: "telarana-gateway-arc-fuji-v0",
  },
] as const satisfies readonly GatewayHubRouteConfig[];

export const GATEWAY_HUB_EVENT_NAMES: readonly GatewayIndexerEventName[] = [
  "GatewayHubRouteConfigured",
  "GatewayHubTransferRequested",
  "GatewayHubBurnIntentSigned",
  "GatewayHubMintAttested",
  "GatewayHubLiquidityReceived",
  "GatewayAtomicFxSwapRequested",
  "GatewayAtomicFxSwapSettled",
  "GatewaySignerModeUpdated",
];

export const GATEWAY_HUB_INDEXER_SCHEMA = [
  {
    name: "GatewayHubRouteConfigured",
    indexed: ["routeId", "sourceDomain", "destinationDomain"],
    data: [
      "sourceUsdc",
      "destinationUsdc",
      "sourceGatewayWallet",
      "destinationGatewayMinter",
      "signerMode",
      "enabled",
    ],
  },
  {
    name: "GatewayHubTransferRequested",
    indexed: ["requestId", "routeId", "sourceSigner"],
    data: [
      "sourceDepositor",
      "destinationRecipient",
      "amount",
      "maxFee",
      "deadline",
      "metadataRef",
    ],
  },
  {
    name: "GatewayHubBurnIntentSigned",
    indexed: ["requestId", "sourceSigner"],
    data: ["sourceDomain", "destinationDomain", "amount", "salt"],
  },
  {
    name: "GatewayHubMintAttested",
    indexed: ["requestId", "routeId"],
    data: ["destinationMinter", "attestationHash"],
  },
  {
    name: "GatewayHubLiquidityReceived",
    indexed: ["requestId", "routeId", "recipient"],
    data: ["destinationUsdc", "amount"],
  },
  {
    name: "GatewayAtomicFxSwapRequested",
    indexed: ["requestId", "routeId", "spotRouteId"],
    data: ["tokenOut", "amountIn", "minAmountOut", "recipient", "metadataRef"],
  },
  {
    name: "GatewayAtomicFxSwapSettled",
    indexed: ["requestId", "spotRouteId", "recipient"],
    data: ["tokenOut", "amountOut"],
  },
  {
    name: "GatewaySignerModeUpdated",
    indexed: ["routeId"],
    data: ["signerMode", "allowed"],
  },
] as const satisfies readonly GatewayIndexerEventSchema[];

export function evmAddressToGatewayBytes32(address: Address): Hex {
  if (!isAddress(address)) {
    throw new Error(`Invalid EVM address: ${address}`);
  }

  return pad(getAddress(address).toLowerCase() as Hex, { size: 32 });
}

export function buildGatewayBurnIntent(
  input: BuildGatewayBurnIntentInput,
): GatewayBurnIntent {
  return {
    maxBlockHeight: input.maxBlockHeight,
    maxFee: input.maxFee ?? GATEWAY_DEFAULT_MAX_FEE,
    spec: {
      version: input.version ?? 1,
      sourceDomain: input.route.sourceDomain,
      destinationDomain: input.route.destinationDomain,
      sourceContract: evmAddressToGatewayBytes32(input.route.sourceGatewayWallet),
      destinationContract: evmAddressToGatewayBytes32(
        input.route.destinationGatewayMinter,
      ),
      sourceToken: evmAddressToGatewayBytes32(input.route.sourceUsdc),
      destinationToken: evmAddressToGatewayBytes32(input.route.destinationUsdc),
      sourceDepositor: evmAddressToGatewayBytes32(input.sourceDepositor),
      destinationRecipient: evmAddressToGatewayBytes32(
        input.destinationRecipient,
      ),
      sourceSigner: evmAddressToGatewayBytes32(input.sourceSigner),
      destinationCaller: evmAddressToGatewayBytes32(
        input.destinationCaller ?? zeroAddress,
      ),
      value: input.amount,
      salt: input.salt,
      hookData: input.hookData ?? "0x",
    },
  };
}

export function gatewayBurnIntentToJson(intent: GatewayBurnIntent) {
  return {
    maxBlockHeight: intent.maxBlockHeight.toString(),
    maxFee: intent.maxFee.toString(),
    spec: {
      ...intent.spec,
      value: intent.spec.value.toString(),
    },
  };
}

export function encodeGatewayMintCalldata(
  attestationPayload: Hex,
  signature: Hex,
): Hex {
  return encodeFunctionData({
    abi: CircleGatewayMinterAbi,
    functionName: "gatewayMint",
    args: [attestationPayload, signature],
  });
}
