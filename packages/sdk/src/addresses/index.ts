import type { Address } from "viem";

/// Chain IDs the SDK knows about. Add new entries as we deploy.
export const ChainId = {
  EthereumMainnet: 1,
  Sepolia: 11155111,
  BaseSepolia: 84532,
  ArcTestnet: 5042002,
} as const;

export type ChainIdName = keyof typeof ChainId;
export type ChainIdValue = (typeof ChainId)[ChainIdName];

export interface FxAddresses {
  /// fx-Telarana contracts (set after deploy)
  fxOracle: Address;
  fxMarketRegistry: Address;
  fxLiquidator: Address;
  fxReceiptUSDC: Address;
  fxReceiptEURC: Address;
  fxHubMessageReceiver?: Address;
  fxSpoke?: Address;

  /// External dependencies
  morphoBlue: Address;
  adaptiveCurveIrm: Address;
  pyth: Address;
  cctpTokenMessengerV2?: Address;
  cctpMessageTransmitterV2?: Address;
  cctpDomain?: number;

  /// Tokens
  usdc: Address;
  eurc: Address;

  /// Pyth feed IDs (chain-agnostic, included here for convenience)
  pythFeedUSDC: `0x${string}`;
  pythFeedEURC: `0x${string}`;
  pythFeedEURUSD: `0x${string}`;
}

const PYTH_FEED_USDC_USD = "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a" as const;
const PYTH_FEED_EURC_USD = "0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c" as const;
const PYTH_FEED_EUR_USD  = "0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b" as const;

const ZERO = "0x0000000000000000000000000000000000000000" as const;

/// Addresses partitioned per chain. fx-Telarana contracts are TBD until deploy.
export const addresses: Record<ChainIdValue, Partial<FxAddresses>> = {
  [ChainId.BaseSepolia]: {
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    adaptiveCurveIrm: "0x46415998764C29aB2a25CbeA6254146D50D22687",
    pyth: "0xA2aa501b19aff244D90cc15a4Cf739D2725B5729",
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    // eurc: filled in after MockEURC is deployed by DeployBaseSepolia.s.sol
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.ArcTestnet]: {
    pyth: "0x2880aB155794e7179c9eE2e38200202908C17B43",
    usdc: "0x3600000000000000000000000000000000000000",
    eurc: "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a",
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 26,
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
    // morphoBlue + adaptiveCurveIrm: TBD on Arc
  },
  [ChainId.EthereumMainnet]: {
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    adaptiveCurveIrm: "0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC",
    pyth: "0x4305FB66699C3B2702D4d05CF36551390A4c69C6",
    usdc: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    eurc: "0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.Sepolia]: {
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    adaptiveCurveIrm: "0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
};

export function getAddresses(chainId: ChainIdValue): Partial<FxAddresses> {
  return addresses[chainId] ?? {};
}

export { ZERO };
