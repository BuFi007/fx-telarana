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
    // Fuji-routed spoke refreshed during the 2026-05-17 canonical Fuji EURC migration.
    // Arc-routed spoke refreshed during the 2026-05-17 Arc basket hub migration.
    fxSpoke: "0x58c1a04bc4e25db2f8474c9df41907cffc894a4b",
    fxSpokeAlt: "0x71e85194f57338d854eabd158f0cd2c376b9f966",
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
    // Fuji = PRIMARY HUB. Canonical Fuji EURC stack deployed 2026-05-17:
    // current AccessControl/Pausable/listPools registry surface, real EURC
    // Morpho markets, receiver-bound Gateway hook, and fresh self-loop spoke.
    // The earlier MockEURC market stack is deprecated in deployments/*.json.
    fxOracle: "0x4178F9D64F64eD05C25B0D6284f64522436A2a1F",
    fxMarketRegistry: "0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9",
    fxLiquidator: "0x113A539625D208b5EcC59f300Be14b9b3508E559",
    fxReceiptEURC: "0x971b6ED14521f354eD13d64506Bf47D84E70F4fc",
    fxReceiptUSDC: "0x629144FDC1d0A6f9F2B12d9747557Cc508728739",
    fxHubMessageReceiver: "0xbBc9AE9dbd3F6D3dB672F0CA2419d0f4C8513062",
    fxGatewayHook: "0x1527f0230e07B202812A0F0E437995323A1a98cB",
    // Fuji-resident spoke that routes to the LOCAL Fuji hub (self-loop CCTP V2).
    fxSpoke: "0x6EC2197aC1c35Fbe64533101a3DFf081BD45Ed99",
    // Fuji-resident spoke that routes to the ARC hub (cross-hub spider-web edge).
    fxSpokeAlt: "0x225cca22879593b41c7dcceb9e961b7881061368",
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
  },
  [ChainId.ArcTestnet]: {
    // Arc = TRADING-EXECUTION HUB. Refreshed 2026-05-17 with the basket
    // money-market stack, current registry surface, receiver-bound Gateway
    // hook, and 12 EURC/mock stablecoin Morpho markets.
    fxOracle: "0x625e2870a94F67F575Ed82678C2c619994721D29",
    fxMarketRegistry: "0xdB59d712a3cD19DccD98F5a245302a94d43f9A8c",
    fxLiquidator: "0x3DD99ace9ab896C613b47749e6Daae84ceF0433B",
    fxReceiptEURC: "0x8A88024AE640B26b082E5D01BF0BDea9e0F89f3d",
    fxReceiptUSDC: "0x3b94E6A9Dc100CC390B56D1f0BB6a0B706ad3aAA",
    fxHubMessageReceiver: "0x4FBe4cc4ab09648d65195f5B9490D20D12D49a2c",
    fxGatewayHook: "0x412f0CE9cb7697458dF3804d56de259c3e38371B",
    morphoBlue: "0x3c9b95C6E7B23f094f066733E7797C8680760830",
    adaptiveCurveIrm: "0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1",
    // Arc-resident spoke that routes to the FUJI hub (sends users back).
    fxSpoke: "0xf93834070e4e4e7ff0e161feca2aeba65c2c6a38",
    // Arc-resident spoke that routes to the LOCAL Arc hub (self-loop CCTP V2).
    fxSpokeAlt: "0x10b1ddc4a061991d44643893a24b754b8fc0dc98",
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
        address: "0x4DeB6B4C83588c987C952858225A4725F6e1B1f2",
        decimals: 6,
        pythFeedId: PYTH_FEED_AUD_USD,
        pythFeedInverted: false,
        redstoneFeedId: "AUD",
        source: "mock",
      },
      brla: {
        symbol: "BRLA",
        source: "excluded",
        blockedReason: "Excluded from Phase 3 until Avenia deploys BRLA natively on Avalanche.",
      },
      jpyc: {
        symbol: "JPYC",
        address: "0xD9eCFc78BDFbD121E8b07Bf96D6E27a1C11C6331",
        decimals: 18,
        pythFeedId: PYTH_FEED_USD_JPY,
        pythFeedInverted: true,
        redstoneFeedId: "JPY",
        source: "mock",
      },
      krw1: {
        symbol: "KRW1",
        address: "0x204E306FBc71D876E4F105111bBBB1E8113886C3",
        decimals: 0,
        pythFeedId: PYTH_FEED_USD_KRW,
        pythFeedInverted: true,
        redstoneFeedId: "KRW",
        source: "mock",
      },
      mxnb: {
        symbol: "MXNB",
        address: "0xdb6EC7E8ad32D2c6fe05c0862d626A84049c24c5",
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
        address: "0xF50D7B5B6699f2D1FB7BCFC80261Ae0fca48396C",
        decimals: 18,
        pythFeedId: PYTH_FEED_USD_CHF,
        pythFeedInverted: true,
        redstoneFeedId: "CHF",
        source: "mock",
      },
    },
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
    // `fxSpokeAlt` routes to Arc hub. Arc route refreshed for the basket hub.
    fxSpoke: "0xf4556f31cace9a80aa584059c81638a5cd344dde",
    fxSpokeAlt: "0xb912a78e5dbb0848501e1d643bda2193ec64aebc",
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
  },
  [ChainId.OpSepolia]: {
    // Stage 6 spokes. Arc route refreshed for the basket hub.
    fxSpoke: "0x2552e1027ff27a285635a9593825e3da8f25808b",
    fxSpokeAlt: "0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b",
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
    // Stage 6 spokes. Arc route refreshed for the basket hub.
    fxSpoke: "0xaa875a68b0155da4bd6a528ee9e1137017d18b41",
    fxSpokeAlt: "0xfa999ca0392523a915e6bbc0026825090ed1a207",
    // CCTP V2 domain 3
    cctpTokenMessengerV2: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
    cctpMessageTransmitterV2: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    cctpDomain: 3,
    hyperlane: HYPERLANE_ARBITRUM_SEPOLIA,
    usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
    pythFeedUSDC: PYTH_FEED_USDC_USD,
    pythFeedEURC: PYTH_FEED_EURC_USD,
    pythFeedEURUSD: PYTH_FEED_EUR_USD,
  },
  [ChainId.PolygonAmoy]: {
    // Stage 6 spokes. Arc route refreshed for the basket hub.
    fxSpoke: "0x58c1a04bc4e25db2f8474c9df41907cffc894a4b",
    fxSpokeAlt: "0x71e85194f57338d854eabd158f0cd2c376b9f966",
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
    // Stage 6 spokes. Arc route refreshed for the basket hub.
    fxSpoke: "0x2552e1027ff27a285635a9593825e3da8f25808b",
    fxSpokeAlt: "0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b",
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
