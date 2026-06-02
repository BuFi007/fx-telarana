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
  /// Morpho ecosystem v2 contracts. Present on chains where Morpho Labs has
  /// shipped the post-Blue infra (oracle factory + vault V2 + market V1
  /// adapter V2 + registry). Use these instead of self-deploying the dummy
  /// vault when real Morpho-pattern vaults are needed.
  morphoChainlinkOracleV2Factory?: Address;
  morphoVaultV2Factory?: Address;
  morphoMarketV1AdapterV2Factory?: Address;
  morphoRegistryList?: Address;
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

  /// Shielded privacy hook surface. Present where FxPrivacyEntrypoint + at
  /// least one FxPrivacyPool are deployed. `pools` keys are token symbols
  /// (e.g. "USDC", "EURC", "MXNB"). `swapAdapter` is the cross-currency
  /// relay adapter (currently only Arc has one — Fuji's adapter slot is
  /// reserved for when MockEURC is replaced with a user-acquirable EURC).
  privacy?: PrivacyHookAddresses;
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
  symbol: "AUDF" | "BRLA" | "cirBTC" | "JPYC" | "KRW1" | "MXNB" | "PHPC" | "QCAD" | "ZCHF";
  address?: Address;
  decimals?: number;
  pythFeedId?: `0x${string}`;
  pythFeedInverted?: boolean;
  redstoneFeedId?: "AUD" | "BRL" | "BTC" | "CAD" | "JPY" | "KRW" | "MXN" | "PHP" | "CHF";
  source: "issuer" | "mock" | "blocked" | "excluded";
  blockedReason?: string;
  notes?: string;
}

export interface PrivacyHookAddresses {
  entrypoint: Address;
  swapAdapter?: Address;
  fixedRateSwapAdapter?: Address;
  spotExecutionAdapterId?: string;
  spotExecutionAdapter?: Address;
  pools: Partial<Record<"USDC" | "EURC" | StablecoinBasketToken["symbol"], Address>>;
}

export interface StablecoinBasketAddresses {
  audf: StablecoinBasketToken;
  brla: StablecoinBasketToken;
  cirbtc: StablecoinBasketToken;
  jpyc: StablecoinBasketToken;
  krw1: StablecoinBasketToken;
  mxnb: StablecoinBasketToken;
  phpc: StablecoinBasketToken;
  qcad?: StablecoinBasketToken;
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
// Pyth USD/CAD price feed id. Verify against the Pyth catalog before
// production use; QCAD is currently used only for the Arc testnet listing.
const PYTH_FEED_USD_CAD  = "0x3f3f306cd6c0e6e09a8ce6878fcdb1862c3bbac1d3e3aedebfde4e7e7a73f2c1" as const;
const PYTH_FEED_BTC_USD  = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43" as const;

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
      cirbtc: { symbol: "cirBTC", source: "blocked", blockedReason: "Not deployed on Fuji testnet." },
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
    // This live Stage 6 stack is bound to the earlier self-deployed Morpho.
    // Fresh Morpho Labs-backed Arc hub is deployed in
    // deployments/arc-testnet-morpho-labs-cirbtc-5042002.json. Keep this
    // Stage 6 block as the SDK/default route until Circle SCP, spokes, and
    // Gateway wiring are intentionally switched.
    fxOracle: "0x77b3A3B420dB98B01085b8C46a753Ed9879e2865",
    fxMarketRegistry: "0x813232259c9b922e7571F15220617C80581f1464",
    fxLiquidator: "0xa50f7D4D4a1A0D3CF418515973545b80E037B379",
    fxReceiptEURC: "0xF829f57Db8530fa93FCD6e13b00193cbe8cE1493",
    fxReceiptUSDC: "0xdd22365Bba7330BE537c9BC26da9b1b4Db9aC431",
    fxHubMessageReceiver: "0x44B50E93eCC7775aF99bcd04c30e1A00da80F63C",
    fxGatewayHook: "0x2931C50745334d6DFf9eC4E3106fE05b49717DF1",
    // Arc hookathon yield-engine perp stack. Old sprint-1 contracts
    // (clearinghouse 0x39dc43E2…) are superseded by these.
    fxPerps: {
      clearinghouse: "0x7707d108F6Ce3d95ceA38D3965448F00C21CaFdC",
      marginAccount: "0x77BBAef17257AD4800BE12A5D36AF87f3a49FBb7",
      fundingEngine: "0xE08a146B9081A8dd32203fC5e7B5988352489518",
      healthChecker: "0x234E06a0761cde322E4Fc5065A8256247669F362",
      liquidationEngine: "0x18DEA7845c36d45AaDbcCeC04aC6cFc103748D80",
      orderSettlement: "0xCeae7846c8ED2Dd9E6f541798a657875305EA0d8",
      keeperAdmin: "0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69",
    },
    // Arc Morpho stack 2026-05-21: switched from the self-deployed
    // 0x3c9b95C6E7B23f094f066733E7797C8680760830 to Morpho Labs' canonical
    // testnet deployment, confirmed via their 2026-05-21 email and verified
    // on-chain (see deployments/morpho-arc-testnet.json).
    morphoBlue: "0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4",
    adaptiveCurveIrm: "0xBD583cc9807980f9e41f7c8250f594fB6173abE3",
    morphoChainlinkOracleV2Factory: "0xEBef760B0CA0d1Fa9578f47001A184Ee53EaE839",
    morphoVaultV2Factory: "0x6b7F638B64539F83810A1f6ea81C703b561C3Be6",
    // Linkage verified on-chain: morpho() = canonical MorphoBlue 0x65f435…
    morphoMarketV1AdapterV2Factory: "0x9372EbEDF2C64344817c67dAeD99512F4b9DC434",
    morphoRegistryList: "0xcba6be0EF65176CE7D440A4a93657fb2dd84200c",
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
    // Shielded pools — full basket coverage on Arc as of 2026-05-23. USDC +
    // EURC are the v1 ship (2026-05-18); MXNB / QCAD / cirBTC / AUDF were
    // added in 100%-hot mode (hotReservePct=10000 disables Morpho rehyp).
    // Full deploy manifest: deployments/privacy-hook-arc.json. Pool tree
    // configs (asset, scope) live in privacyTradeClient.ts.
    privacy: {
      entrypoint: "0xD11cDdd1f04e850d3810a71608A49907c80f2736",
      swapAdapter: "0xe9147f799C1d65d1bAcFD0fE019d8c46531ef917",
      fixedRateSwapAdapter: "0x3Fa1AcC89DFd52f6692F20b7E49cD58A306C27f2",
      spotExecutionAdapterId: "3",
      spotExecutionAdapter: "0x73633884c21997d8ef09dd2730841e770a5e3371",
      pools: {
        USDC: "0xC11C216C9C7A36848b1d4276d223160C8b51988f",
        EURC: "0x7B4582CDE65c8cC00fE24B16dBA60472242d234c",
        MXNB: "0x441723FD6212EF7C95D0e04F59b2Eeb59838d4E7",
        QCAD: "0xF3bd84bDdaD66a3b1F94dF7de0aD34AB158f2De4",
        cirBTC: "0x2465806A9293A588867DD94b9A6aB5d47531E928",
        AUDF: "0x5BC0e0795D5ea842601220bd1f855e60Fad7E3D1",
      },
    },
    stablecoinBasket: {
      audf: {
        symbol: "AUDF",
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
      cirbtc: {
        symbol: "cirBTC",
        address: "0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF",
        decimals: 18,
        pythFeedId: PYTH_FEED_BTC_USD,
        pythFeedInverted: false,
        redstoneFeedId: "BTC",
        source: "issuer",
        notes:
          "Arc testnet cirBTC issuance dropped 2026-05-21. Replaces the prior Morpho Labs FakeCirBTC at 0x44cEe9E472C34b2f0d9710CD8aBd02dadb912761.",
      },
      jpyc: {
        symbol: "JPYC",
        address: "0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29",
        decimals: 18,
        pythFeedId: PYTH_FEED_USD_JPY,
        pythFeedInverted: false,
        redstoneFeedId: "JPY",
        source: "issuer",
        notes: "Official Arc testnet JPYC used by the hookathon yield engine.",
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
        address: "0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461",
        decimals: 6,
        pythFeedId: PYTH_FEED_USD_MXN,
        pythFeedInverted: true,
        redstoneFeedId: "MXN",
        source: "issuer",
        notes: "Arc testnet MXNB issuance dropped 2026-05-21.",
      },
      qcad: {
        symbol: "QCAD",
        address: "0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d",
        decimals: 6,
        pythFeedId: PYTH_FEED_USD_CAD,
        pythFeedInverted: true,
        redstoneFeedId: "CAD",
        source: "issuer",
        notes: "Arc testnet QCAD issuance dropped 2026-05-21.",
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
    // adaptiveCurveIrm is now wired (above) — Arc testnet is on the Morpho
    // Labs-canonical stack and no longer self-deploys.
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
      cirbtc: {
        symbol: "cirBTC",
        source: "excluded",
        blockedReason: "cirBTC mainnet issuance is planned for Ethereum + Arc first; no Avalanche mainnet address is published.",
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
    stablecoinBasket: {
      audf: { symbol: "AUDF", source: "blocked", blockedReason: "Not deployed on Ethereum Sepolia." },
      brla: { symbol: "BRLA", source: "blocked", blockedReason: "Not deployed on Ethereum Sepolia." },
      cirbtc: { symbol: "cirBTC", source: "blocked", blockedReason: "No Ethereum Sepolia cirBTC test token configured." },
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
      cirbtc: { symbol: "cirBTC", source: "blocked", blockedReason: "No Arbitrum Sepolia cirBTC test token configured." },
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
