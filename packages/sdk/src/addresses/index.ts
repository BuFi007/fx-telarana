// SPDX-License-Identifier: Apache-2.0
import type { Address } from "viem";

/// Chain IDs the SDK knows about. Add new entries as we deploy.
export const ChainId = {
  EthereumMainnet: 1,
  AvalancheMainnet: 43114,
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
  /// Per-chain secondary spoke that routes to the *other* hub (e.g. on
  /// Fuji, this is the Fuji-resident spoke whose HUB_RECEIVER points at the
  /// Arc hub). Spider-web topology: every chain has both a Fuji-routed and
  /// an Arc-routed spoke. Populated post-Stage-6.
  fxSpokeAlt?: Address;
  fxGatewayHook?: Address;
  fxSwapHook?: Address;
  fxPerps?: FxPerpsAddresses;

  /// External dependencies
  morphoBlue: Address;
  adaptiveCurveIrm?: Address;
  pyth: Address;
  cctpTokenMessengerV2?: Address;
  cctpMessageTransmitterV2?: Address;
  cctpDomain?: number;
  hyperlane?: HyperlaneChainAddresses;
  hyperlaneWarpRoutes?: HyperlaneWarpRouteConfig[];

  /// Tokens
  usdc: Address;
  eurc: Address;
  stablecoinBasket?: StablecoinBasketAddresses;

  /// Pyth feed IDs (chain-agnostic, included here for convenience)
  pythFeedUSDC: `0x${string}`;
  pythFeedEURC: `0x${string}`;
  pythFeedEURUSD: `0x${string}`;
}

export interface FxPerpsAddresses {
  clearinghouse: Address;
  marginAccount: Address;
  fundingEngine: Address;
  healthChecker: Address;
  liquidationEngine: Address;
  orderSettlement: Address;
  keeperAdmin: Address;
}

export interface StablecoinBasketToken {
  symbol: "AUDF" | "BRLA" | "JPYC" | "KRW1" | "MXNB" | "PHPC" | "ZCHF";
  address?: Address;
  decimals?: number;
  pythFeedId?: `0x${string}`;
  pythFeedInverted?: boolean;
  redstoneFeedId?: "AUD" | "BRL" | "JPY" | "KRW" | "MXN" | "PHP" | "CHF";
  source: "issuer" | "mock" | "blocked" | "excluded";
  blockedReason?: string;
}

export interface StablecoinBasketAddresses {
  audf: StablecoinBasketToken;
  brla: StablecoinBasketToken;
  jpyc: StablecoinBasketToken;
  krw1: StablecoinBasketToken;
  mxnb: StablecoinBasketToken;
  phpc: StablecoinBasketToken;
  zchf: StablecoinBasketToken;
}

export interface HyperlaneChainAddresses {
  /// Hyperlane domain id. It often matches the EVM chain id, but callers should
  /// use this value rather than assuming equality.
  domain: number;
  mailbox?: Address;
  interchainGasPaymaster?: Address;
  interchainAccountRouter?: Address;
  merkleTreeHook?: Address;
  protocolFee?: Address;
  validatorAnnounce?: Address;
  appSpecificIsms?: Partial<Record<number, Address>>;
}

export interface HyperlaneWarpRouteConfig {
  symbol: StablecoinBasketToken["symbol"] | "USDC" | "EURC";
  status: "planned" | "deployed" | "disabled";
  routeId?: string;
  routeTokenType: "collateral" | "synthetic" | "collateralVault" | "native" | "fiatToken" | "xERC20";
  hubChainId: ChainIdValue;
  hubToken?: Address;
  hubTokenSource: "issuer" | "mock" | "collateralReleased" | "hyperlaneSynthetic" | "pending";
  originChains: ChainIdValue[];
  notes?: string;
}

const PYTH_FEED_USDC_USD = "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a" as const;
const PYTH_FEED_EURC_USD = "0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c" as const;
const PYTH_FEED_EUR_USD  = "0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b" as const;
const PYTH_FEED_AUD_USD  = "0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80" as const;
const PYTH_FEED_USD_JPY  = "0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52" as const;
const PYTH_FEED_USD_KRW  = "0xe539120487c29b4defdf9a53d337316ea022a2688978a468f9efd847201be7e3" as const;
const PYTH_FEED_USD_MXN  = "0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca" as const;
const PYTH_FEED_USD_CHF  = "0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8" as const;

const ZERO = "0x0000000000000000000000000000000000000000" as const;

const HYPERLANE_AVALANCHE_MAINNET: HyperlaneChainAddresses = {
  domain: 43114,
  mailbox: "0xFf06aFcaABaDDd1fb08371f9ccA15D73D51FeBD6",
  interchainGasPaymaster: "0x95519ba800BBd0d34eeAE026fEc620AD978176C0",
  interchainAccountRouter: "0x2c58687fFfCD5b7043a5bF256B196216a98a6587",
};

const HYPERLANE_FUJI: HyperlaneChainAddresses = {
  domain: 43113,
  mailbox: "0x5b6CFf85442B851A8e6eaBd2A4E4507B5135B3B0",
  interchainGasPaymaster: "0x6895d3916B94b386fAA6ec9276756e16dAe7480E",
  appSpecificIsms: {
    [ChainId.ArcTestnet]: "0x3f5d9B44aa1D59D26B20862D91533d60B32d9aFa",
  },
};

const HYPERLANE_ARC_TESTNET: HyperlaneChainAddresses = {
  domain: 5042002,
  mailbox: "0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9",
  interchainGasPaymaster: ZERO,
  interchainAccountRouter: "0x113A539625D208b5EcC59f300Be14b9b3508E559",
  merkleTreeHook: "0xccceb5B90d9C1d9c5f8CcF755E4f37A849C8Ca11",
  protocolFee: "0x971b6ED14521f354eD13d64506Bf47D84E70F4fc",
  validatorAnnounce: "0xbBc9AE9dbd3F6D3dB672F0CA2419d0f4C8513062",
};

const HYPERLANE_SEPOLIA: HyperlaneChainAddresses = {
  domain: 11155111,
  mailbox: "0xfFAEF09B3cd11D9b20d1a19bECca54EEC2884766",
  interchainGasPaymaster: "0x6f2756380FD49228ae25Aa7F2817993cB74Ecc56",
};

const HYPERLANE_OP_SEPOLIA: HyperlaneChainAddresses = {
  domain: 11155420,
  mailbox: "0x6966b0E55883d49BFB24539356a2f8A673E02039",
  interchainGasPaymaster: "0x28B02B97a850872C4D33C3E024fab6499ad96564",
};

const HYPERLANE_ARBITRUM_SEPOLIA: HyperlaneChainAddresses = {
  domain: 421614,
  mailbox: "0x598facE78a4302f11E3de0bee1894Da0b2Cb71F8",
  interchainGasPaymaster: "0xc756cFc1b7d0d4646589EDf10eD54b201237F5e8",
};

const HYPERLANE_BASE_SEPOLIA: HyperlaneChainAddresses = {
  domain: 84532,
  mailbox: "0x6966b0E55883d49BFB24539356a2f8A673E02039",
  interchainGasPaymaster: "0x28B02B97a850872C4D33C3E024fab6499ad96564",
};

const HYPERLANE_POLYGON_AMOY: HyperlaneChainAddresses = {
  domain: 80002,
  mailbox: "0x54148470292C24345fb828B003461a9444414517",
  interchainGasPaymaster: "0x6c13643B3927C57DB92c790E4E3E7Ee81e13f78C",
};

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
    hyperlane: HYPERLANE_BASE_SEPOLIA,
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    eurc: "0x808456652fdb597867f38412077A9182bf77359F", // Circle's real EURC on Base Sepolia
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.UnichainSepolia]: {
    // Stage 6 spokes (2026-05-15). Synced from deployments/unichain-sepolia.json.
    fxSpoke: "0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b",
    fxSpokeAlt: "0x7882d3f0e210128a4dce51e1af1ec801e21e1e5a",
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
    // Fuji = PRIMARY HUB (Stage 6 live). The hub stack below was redeployed
    // 2026-05-15 with the relay surface (relayToRemoteHub, relayMintFromRemote,
    // setRelayCaller, sweepHubBalance) plus Codex-adversarial-review-v3-r2
    // hardening (msg.sender-bound recipient, strandedUsdcLiability gate).
    // V1 contracts (0x365DE300…, 0xAa875a68…) are deprecated and tracked in
    // deployments/avalanche-fuji.json's `deprecated:` block; do NOT route new
    // deposits to them. Source of truth: deployments/avalanche-fuji.json +
    // deployments/hub-config-fuji.json.
    fxOracle: "0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b",
    fxMarketRegistry: "0x7ba745b979e027992ECFa51207666e3F5B46cF0a",
    fxLiquidator: "0x2900599ff0e6dd057493d62fac856e5a8f93c6eb",
    fxReceiptEURC: "0xefd7cf5ad5a2db9a3c23e2807f2279de92c730d2",
    fxReceiptUSDC: "0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e",
    fxHubMessageReceiver: "0x7eAdfD0c08dd6544f763285bBD31be14179d594B",
    fxGatewayHook: "0x7dA191bfB85D9F14069228cf618519BFb41f371E",
    // Fuji-resident spoke that routes to the LOCAL Fuji hub (self-loop CCTP V2).
    fxSpoke: "0xb7fc291c27f6a7a659d4d229e5d8a55e58f26ab1",
    // Fuji-resident spoke that routes to the ARC hub (cross-hub spider-web edge).
    fxSpokeAlt: "0xe22ef07a0996df9ae6252cc9bf491fbe13fd6575",
    morphoBlue: "0xeF64621D41093144D9ED8aB8327eE381ECdB79E6",
    adaptiveCurveIrm: "0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA",
    pyth: "0x23f0e8FAeE7bbb405E7A7C3d60138FCfd43d7509",
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 1,
    hyperlane: HYPERLANE_FUJI,
    usdc: "0x5425890298aed601595a70AB815c96711a31Bc65",
    eurc: "0x5E44db7996c682E92a960b65AC713a54AD815c6B",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
    // MXNB on Fuji is the LIVE Bitso testnet deployment (real issuer
    // token, not a mock). Add via `DeployFujiMxnbMarkets.s.sol`.
    stablecoinBasket: {
      audf: { symbol: "AUDF", source: "blocked", blockedReason: "Not deployed on Fuji testnet." },
      brla: { symbol: "BRLA", source: "blocked", blockedReason: "Not deployed on Fuji testnet." },
      jpyc: { symbol: "JPYC", source: "blocked", blockedReason: "Not deployed on Fuji testnet." },
      krw1: { symbol: "KRW1", source: "blocked", blockedReason: "Not deployed on Fuji testnet." },
      mxnb: {
        symbol: "MXNB",
        address: "0xAB99d44185af87AeB08361588F00F59B0CE85eBb",
        decimals: 6,
        pythFeedId: PYTH_FEED_USD_MXN,
        pythFeedInverted: true,
        redstoneFeedId: "MXN",
        source: "issuer",
      },
      phpc: { symbol: "PHPC", source: "blocked", blockedReason: "Not deployed on Fuji testnet." },
      zchf: { symbol: "ZCHF", source: "blocked", blockedReason: "Not deployed on Fuji testnet." },
    },
  },
  [ChainId.ArcTestnet]: {
    // Arc = TRADING-EXECUTION HUB (Stage 6 live, 2026-05-15). Receives USDC
    // liquidity from Fuji via FxGatewayHook for FX/perp execution; never
    // user-initiated. The hub stack below mirrors Fuji's contract surface
    // — same relay + sweep + liability hardening from Codex v3 round 2.
    // V1 spoke (0x47c76D…) is deprecated; do NOT route new deposits to it.
    // Source of truth: deployments/arc-testnet.json + hub-config-arc.json.
    // Tenderly does NOT yet index chain 5042002 — on-chain verification only.
    fxOracle: "0x77b3A3B420dB98B01085b8C46a753Ed9879e2865",
    fxMarketRegistry: "0x813232259c9b922e7571F15220617C80581f1464",
    fxLiquidator: "0xa50f7D4D4a1A0D3CF418515973545b80E037B379",
    fxReceiptEURC: "0xF829f57Db8530fa93FCD6e13b00193cbe8cE1493",
    fxReceiptUSDC: "0xdd22365Bba7330BE537c9BC26da9b1b4Db9aC431",
    fxHubMessageReceiver: "0x44B50E93eCC7775aF99bcd04c30e1A00da80F63C",
    fxGatewayHook: "0x2931C50745334d6DFf9eC4E3106fE05b49717DF1",
    fxPerps: {
      clearinghouse: "0x6A265045D9A3291D2881d77DDC62e2781A2418c5",
      marginAccount: "0x35c7cD02cFa0c2889547482B71c1a5114d8439C6",
      fundingEngine: "0x88B70872759E1aA24858746779Cb15ca9F2cdcf3",
      healthChecker: "0x272305e821D810eC5741761F98DbDC273efD47E6",
      liquidationEngine: "0xD384560E5f8CE969BF4C1BDfAFACc5304AFbe8f2",
      orderSettlement: "0x0F62FCdA2de63d905Cb167301C00251A9bB6dAa1",
      keeperAdmin: "0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69",
    },
    morphoBlue: "0x3c9b95C6E7B23f094f066733E7797C8680760830",
    // Arc-resident spoke that routes to the FUJI hub (sends users back).
    fxSpoke: "0x13c8463589d460db6f21235eedfd678c22a1ea25",
    // Arc-resident spoke that routes to the LOCAL Arc hub (self-loop CCTP V2).
    fxSpokeAlt: "0x5d10d2c3b9951054845534b2f60a68ebc0898cd3",
    pyth: "0x2880aB155794e7179c9eE2e38200202908C17B43",
    usdc: "0x3600000000000000000000000000000000000000",
    eurc: "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a",
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 26,
    hyperlane: HYPERLANE_ARC_TESTNET,
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
    stablecoinBasket: {
      audf: {
        symbol: "AUDF",
        address: "0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b",
        decimals: 6,
        pythFeedId: PYTH_FEED_AUD_USD,
        pythFeedInverted: false,
        redstoneFeedId: "AUD",
        source: "issuer",
      },
      brla: {
        symbol: "BRLA",
        source: "excluded",
        blockedReason: "Excluded from Phase 3 until Avenia deploys BRLA natively on Avalanche.",
      },
      jpyc: {
        symbol: "JPYC",
        decimals: 18,
        pythFeedId: PYTH_FEED_USD_JPY,
        pythFeedInverted: true,
        redstoneFeedId: "JPY",
        source: "mock",
      },
      krw1: {
        symbol: "KRW1",
        decimals: 0,
        pythFeedId: PYTH_FEED_USD_KRW,
        pythFeedInverted: true,
        redstoneFeedId: "KRW",
        source: "mock",
      },
      mxnb: {
        symbol: "MXNB",
        decimals: 6,
        pythFeedId: PYTH_FEED_USD_MXN,
        pythFeedInverted: true,
        redstoneFeedId: "MXN",
        source: "mock",
      },
      phpc: {
        symbol: "PHPC",
        source: "excluded",
        blockedReason: "Excluded from Phase 3; PHPC is not natively live on Avalanche.",
      },
      zchf: {
        symbol: "ZCHF",
        decimals: 18,
        pythFeedId: PYTH_FEED_USD_CHF,
        pythFeedInverted: true,
        redstoneFeedId: "CHF",
        source: "mock",
      },
    },
    // morphoBlue + adaptiveCurveIrm: TBD on Arc
  },
  [ChainId.AvalancheMainnet]: {
    usdc: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    eurc: "0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD",
    hyperlane: HYPERLANE_AVALANCHE_MAINNET,
    hyperlaneWarpRoutes: [
      {
        symbol: "AUDF",
        status: "planned",
        routeTokenType: "collateral",
        hubChainId: ChainId.AvalancheMainnet,
        hubToken: "0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b",
        hubTokenSource: "collateralReleased",
        originChains: [ChainId.EthereumMainnet, ChainId.BaseSepolia],
        notes: "Use only if the Avalanche route is collateral-backed and funded to release issuer AUDF; otherwise list the Hyperlane synthetic as a separate asset.",
      },
      {
        symbol: "JPYC",
        status: "planned",
        routeTokenType: "collateral",
        hubChainId: ChainId.AvalancheMainnet,
        hubToken: "0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB",
        hubTokenSource: "collateralReleased",
        originChains: [ChainId.EthereumMainnet],
        notes: "Mainnet route must preserve 18 decimals. Do not use JPYC Sepolia's 6-decimal test token as production metadata.",
      },
      {
        symbol: "MXNB",
        status: "planned",
        routeTokenType: "collateral",
        hubChainId: ChainId.AvalancheMainnet,
        hubToken: "0xF197FFC28c23E0309B5559e7a166f2c6164C80aA",
        hubTokenSource: "collateralReleased",
        originChains: [ChainId.EthereumMainnet],
        notes: "MXNB is also live on Arbitrum One; add that chain id to the SDK before publishing an Arbitrum-origin route.",
      },
      {
        symbol: "KRW1",
        status: "planned",
        routeTokenType: "collateral",
        hubChainId: ChainId.AvalancheMainnet,
        hubToken: "0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318",
        hubTokenSource: "collateralReleased",
        originChains: [],
        notes: "No EVM origin route until BDACS publishes additional chain deployments or we intentionally deploy a synthetic route.",
      },
      {
        symbol: "ZCHF",
        status: "disabled",
        routeTokenType: "synthetic",
        hubChainId: ChainId.AvalancheMainnet,
        hubToken: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
        hubTokenSource: "issuer",
        originChains: [],
        notes: "Avalanche ZCHF is the CCIP-bridged issuer asset. Do not replace it with a Hyperlane synthetic without separate risk approval.",
      },
    ],
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
    stablecoinBasket: {
      audf: {
        symbol: "AUDF",
        address: "0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b",
        decimals: 6,
        pythFeedId: PYTH_FEED_AUD_USD,
        pythFeedInverted: false,
        redstoneFeedId: "AUD",
        source: "issuer",
      },
      brla: {
        symbol: "BRLA",
        source: "excluded",
        blockedReason: "Polygon-only in Phase 3 research; not natively live on Avalanche.",
      },
      jpyc: {
        symbol: "JPYC",
        address: "0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB",
        decimals: 18,
        pythFeedId: PYTH_FEED_USD_JPY,
        pythFeedInverted: true,
        redstoneFeedId: "JPY",
        source: "issuer",
      },
      krw1: {
        symbol: "KRW1",
        address: "0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318",
        decimals: 0,
        pythFeedId: PYTH_FEED_USD_KRW,
        pythFeedInverted: true,
        redstoneFeedId: "KRW",
        source: "issuer",
      },
      mxnb: {
        symbol: "MXNB",
        address: "0xF197FFC28c23E0309B5559e7a166f2c6164C80aA",
        decimals: 6,
        pythFeedId: PYTH_FEED_USD_MXN,
        pythFeedInverted: true,
        redstoneFeedId: "MXN",
        source: "issuer",
      },
      phpc: {
        symbol: "PHPC",
        source: "excluded",
        blockedReason: "Polygon/Ronin only in Phase 3 research; not natively live on Avalanche.",
      },
      zchf: {
        symbol: "ZCHF",
        address: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
        decimals: 18,
        pythFeedId: PYTH_FEED_USD_CHF,
        pythFeedInverted: true,
        redstoneFeedId: "CHF",
        source: "issuer",
      },
    },
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
    // Stage 6 spokes (2026-05-15). `fxSpoke` routes to Fuji hub;
    // `fxSpokeAlt` routes to Arc hub. Synced from deployments/ethereum-sepolia.json.
    fxSpoke: "0xf6d845da2051183b9519ca1806c39040ba5e71ba",
    fxSpokeAlt: "0x4e63954685241c4469f02fec3761ff1d4f34ffa9",
    // CCTP V2 domain 0
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 0,
    hyperlane: HYPERLANE_SEPOLIA,
    usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    adaptiveCurveIrm: "0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
    // MXNB on Ethereum Sepolia is the LIVE Bitso testnet deployment.
    // AUDF on Ethereum Sepolia is the LIVE Forte testnet deployment
    // (same address as mainnet; faucet 0x14e18b...). Confirmed 2026-05-18.
    stablecoinBasket: {
      audf: {
        symbol: "AUDF",
        address: "0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b",
        decimals: 6,
        pythFeedId: PYTH_FEED_AUD_USD,
        pythFeedInverted: false,
        redstoneFeedId: "AUD",
        source: "issuer",
      },
      brla: { symbol: "BRLA", source: "blocked", blockedReason: "Not deployed on Ethereum Sepolia." },
      jpyc: { symbol: "JPYC", source: "blocked", blockedReason: "Not deployed on Ethereum Sepolia." },
      krw1: { symbol: "KRW1", source: "blocked", blockedReason: "Not deployed on Ethereum Sepolia." },
      mxnb: {
        symbol: "MXNB",
        address: "0x34D4CeBB03Af55b99B68342Ac4bD78e598D9A9fC",
        decimals: 6,
        pythFeedId: PYTH_FEED_USD_MXN,
        pythFeedInverted: true,
        redstoneFeedId: "MXN",
        source: "issuer",
      },
      phpc: { symbol: "PHPC", source: "blocked", blockedReason: "Not deployed on Ethereum Sepolia." },
      zchf: { symbol: "ZCHF", source: "blocked", blockedReason: "Not deployed on Ethereum Sepolia." },
    },
  },
  [ChainId.OpSepolia]: {
    // Stage 6 spokes. Synced from deployments/op-sepolia.json.
    fxSpoke: "0x0b5d18bbe92f07ec0111ae6d2e102858268d6aca",
    fxSpokeAlt: "0x579fccdebb1f7e983c4ead27aa300d3b5397e28c",
    // CCTP V2 domain 2
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 2,
    hyperlane: HYPERLANE_OP_SEPOLIA,
    usdc: "0x5fd84259d66Cd46123540766Be93DFE6D43130D7",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.ArbitrumSepolia]: {
    // Stage 6 spokes. Synced from deployments/arbitrum-sepolia.json.
    fxSpoke: "0x2900599ff0e6dd057493d62fac856e5a8f93c6eb",
    fxSpokeAlt: "0x365de300dda61c81a33bce3606a5d524ed964362",
    // CCTP V2 domain 3
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 3,
    hyperlane: HYPERLANE_ARBITRUM_SEPOLIA,
    usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
    // MXNB on Arbitrum Sepolia is the LIVE Bitso testnet deployment.
    // (We already hold 10k MXNB on this chain for protocol-bootstrap LPing.)
    stablecoinBasket: {
      audf: { symbol: "AUDF", source: "blocked", blockedReason: "Not deployed on Arbitrum Sepolia." },
      brla: { symbol: "BRLA", source: "blocked", blockedReason: "Not deployed on Arbitrum Sepolia." },
      jpyc: { symbol: "JPYC", source: "blocked", blockedReason: "Not deployed on Arbitrum Sepolia." },
      krw1: { symbol: "KRW1", source: "blocked", blockedReason: "Not deployed on Arbitrum Sepolia." },
      mxnb: {
        symbol: "MXNB",
        address: "0xb56E3E3769EfB85214Cb4fA42eBA198E9FDA92bf",
        decimals: 6,
        pythFeedId: PYTH_FEED_USD_MXN,
        pythFeedInverted: true,
        redstoneFeedId: "MXN",
        source: "issuer",
      },
      phpc: { symbol: "PHPC", source: "blocked", blockedReason: "Not deployed on Arbitrum Sepolia." },
      zchf: { symbol: "ZCHF", source: "blocked", blockedReason: "Not deployed on Arbitrum Sepolia." },
    },
  },
  [ChainId.PolygonAmoy]: {
    // Stage 6 spokes. Synced from deployments/polygon-amoy.json.
    fxSpoke: "0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b",
    fxSpokeAlt: "0x7882d3f0e210128a4dce51e1af1ec801e21e1e5a",
    // CCTP V2 domain 7
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 7,
    hyperlane: HYPERLANE_POLYGON_AMOY,
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
    // Stage 6 spokes. Synced from deployments/worldchain-sepolia.json.
    fxSpoke: "0x0b5d18bbe92f07ec0111ae6d2e102858268d6aca",
    fxSpokeAlt: "0x579fccdebb1f7e983c4ead27aa300d3b5397e28c",
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
