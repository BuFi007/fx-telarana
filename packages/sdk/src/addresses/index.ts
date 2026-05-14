import type { Address } from "viem";

/// Chain IDs the SDK knows about. Add new entries as we deploy.
export const ChainId = {
  EthereumMainnet: 1,
  Sepolia: 11155111,
  OpSepolia: 11155420,
  ArbitrumSepolia: 421614,
  BaseSepolia: 84532,
  UnichainSepolia: 1301,
  AvalancheFuji: 43113,
  PolygonAmoy: 80002,
  LineaSepolia: 59141,
  WorldChainSepolia: 4801,
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
  fxSwapHook?: Address;

  /// External dependencies
  morphoBlue: Address;
  adaptiveCurveIrm?: Address;
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
    // fx-Telarana contracts — v3 deploy 2026-05-14
    //   FxLiquidator: caller-supplied maxRepayAssets cap, useVerified flag
    //   FxOracle:     getMidWithUpdatePyth split (Pyth-only refresh for chains w/o RedStone)
    // FxSwapHook + v4 pool are still wired to v2 oracle/registry (see deployments/base-sepolia.json).
    // v4 patch (2026-05-14): Codex adversarial-review fix —
    //   FxMarketRegistry now enforces onBehalf==msg.sender on withdraw,
    //   withdrawCollateral, borrow. FxHubMessageReceiver verifies bridged
    //   USDC was fully consumed; partial consumption → Stranded (sweepable).
    //   FxLiquidator rebound to the new registry.
    //   Do NOT setAuthorization on the v3 contracts (see deployments/base-sepolia.json
    //   v3_DEPRECATED_DO_NOT_AUTHORIZE).
    fxOracle: "0x4cf0403ee262a5f4E964658C428aC9D7EfF37076",
    fxMarketRegistry: "0x0cb2dd5296e06c86cb96aeef2c59d2a92cfd9b9e",
    fxLiquidator: "0xb9f81d14bdc2d96d99222aafcad1752ea18e80e4",
    fxReceiptEURC: "0xe6bA492FC3256Ba05c80be30436Cdf069BE23b80",
    fxReceiptUSDC: "0xD5A6cB32f2635f90C3Ccb9EB2d5d2Cc59f1C333c",
    fxHubMessageReceiver: "0x17afd89bd6888c393b8c5d7e7c0baee8259581a5",
    fxSwapHook: "0xc7260EF7D95D155aD6CA18ED539373a7576c8AC8",
    // External deps
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    adaptiveCurveIrm: "0x46415998764C29aB2a25CbeA6254146D50D22687",
    pyth: "0xA2aa501b19aff244D90cc15a4Cf739D2725B5729",
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 6,
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    eurc: "0x808456652fdb597867f38412077A9182bf77359F", // Circle's real EURC on Base Sepolia
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.UnichainSepolia]: {
    // FxSpoke — deployed 2026-05-14, targets Base Sepolia hub receiver
    //   0x758c17BfA85D1b26A81423B524397b8b2D271818 (domain 6).
    fxSpoke: "0x8B7041d8A4bd773a537a01e1F61175da5395714c",
    // CCTP V2 testnet deterministic addresses (domain 10)
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 10,
    usdc: "0x31d0220469e10c4E71834a79b1f276d740d3768F",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.AvalancheFuji]: {
    // FxSpoke — deployed 2026-05-14
    fxSpoke: "0x8B7041d8A4bd773a537a01e1F61175da5395714c",
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 1,
    usdc: "0x5425890298aed601595a70AB815c96711a31Bc65",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
    // fxSpoke: <set after deploy>
  },
  [ChainId.ArcTestnet]: {
    // FxSpoke — deployed 2026-05-14. Phase 1: swap Base Sepolia hub for an
    // Arc-hosted hub so this becomes the canonical loop. Tenderly does NOT
    // yet index chain 5042002 — no source verification possible until they
    // add it (manifest at deployments/arc-testnet.json is the source of truth).
    fxSpoke: "0x47c76D420f6534B4b83592cf706D9830669EEdB8",
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
    // FxSpoke — deployed 2026-05-14
    fxSpoke: "0xc3FFF144b37B79264573E6c4c2ac2F960113A114",
    // CCTP V2 domain 0
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 0,
    usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    adaptiveCurveIrm: "0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.OpSepolia]: {
    // FxSpoke — deployed 2026-05-14
    fxSpoke: "0x8B7041d8A4bd773a537a01e1F61175da5395714c",
    // CCTP V2 domain 2
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 2,
    usdc: "0x5fd84259d66Cd46123540766Be93DFE6D43130D7",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.ArbitrumSepolia]: {
    // FxSpoke — deployed 2026-05-14
    fxSpoke: "0xEFd7CF5ad5a2dB9a3C23e2807f2279DE92C730D2",
    // CCTP V2 domain 3
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 3,
    usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.PolygonAmoy]: {
    // FxSpoke — deployed 2026-05-14
    fxSpoke: "0x2552E1027fF27A285635a9593825E3Da8F25808b",
    // CCTP V2 domain 7
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 7,
    usdc: "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.LineaSepolia]: {
    // CCTP V2 domain 11
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 11,
    usdc: "0xFEce4462D57bD51A6A552365A011b95f0E16d9B7",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.WorldChainSepolia]: {
    // FxSpoke — deployed 2026-05-14
    fxSpoke: "0x8B7041d8A4bd773a537a01e1F61175da5395714c",
    // CCTP V2 domain 14
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 14,
    usdc: "0x66145f38cBAC35Ca6F1Dfb4914dF98F1614aeA88",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
};

export function getAddresses(chainId: ChainIdValue): Partial<FxAddresses> {
  return addresses[chainId] ?? {};
}

export { ZERO };
