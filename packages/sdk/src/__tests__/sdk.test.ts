// SPDX-License-Identifier: Apache-2.0
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "bun:test";
import { encodeFunctionData } from "viem";

import {
  ChainId,
  CircleGatewayMinterAbi,
  CircleGatewayWalletAbi,
  EligibilityReason,
  FxRouteMode,
  FxHyperlaneAction,
  FX_PERP_MARKET_KEYS,
  MIN_LIQUIDATION_FLAG_DELAY,
  FxHyperlaneHubReceiverAbi,
  FxGhostCommitmentRegistryAbi,
  FxGhostKycHookAbi,
  FxGhostSpokeRouterAbi,
  FxMarketRegistryAbi,
  FxOracleAbi,
  FxFundingEngineAbi,
  FxHealthCheckerAbi,
  FxLiquidationEngineAbi,
  FxMarginAccountAbi,
  FxOrderSettlementAbi,
  FxPerpClearinghouseAbi,
  FxSpokeAbi,
  FxSpokeIntentRouterAbi,
  FxSwapHookAbi,
  HyperlaneInterchainAccountRouterAbi,
  HyperlaneWarpRouteAbi,
  IBufiKycPassAbi,
  RFQ_PASILLO_EVENT_NAMES,
  RFQ_PASILLO_INDEXER_SCHEMA,
  GATEWAY_EIP712_TYPES,
  GATEWAY_HUB_ACTION_IDS,
  GATEWAY_HUB_EVENT_NAMES,
  GATEWAY_HUB_INDEXER_SCHEMA,
  GHOST_MODE_EVENT_NAMES,
  GHOST_MODE_INDEXER_SCHEMA,
  TELARANA_GATEWAY_HUB_ROUTES,
  TELARANA_GATEWAY_TESTNET_CHAINS,
  TELARANA_AVALANCHE_SPOT_TOKEN_PAIRS,
  TELARANA_FUJI_SPOT_TOKEN_PAIRS,
  TELARANA_SPOT_FX_EVENT_NAMES,
  TELARANA_SPOT_FX_INDEXER_SCHEMA,
  TELARANA_SPOT_HOOK_CONFIGS,
  TELARANA_SPOT_POOL_CONFIGS,
  TELARANA_SPOT_ROUTE_CONFIGS,
  TelaranaGatewayHubHookAbi,
  buildGatewayBurnIntent,
  encodeGatewayMintCalldata,
  evmAddressToGatewayBytes32,
  assertFxPerpConfigReady,
  fxPerpContractAddressesJson,
  fxPerpsAddressesFromConfigManifest,
  gatewayBurnIntentToJson,
  getFxPerpMarket,
  getAddresses,
  hyperlaneAddressToBytes32,
  parseFxPerpConfigManifest,
  resolveRouteMode,
  planExecuteHyperlaneIntent,
  planExecuteRoutedHyperlaneIntent,
  planFxSpokeIntent,
  planHyperlaneIcaCallRemote,
  planHyperlaneWarpTransferRemote,
  planBorrow,
  planEnterHub,
  planRepay,
  planSupply,
  planSupplyCollateral,
  planWithdraw,
} from "../index.js";
import {
  loadFxPerpRuntimeConfig,
  parseFxPerpContractAddressesJson,
} from "../perps-runtime.js";
import {
  createJsonLogger,
  keeperComponentsFromString,
  marketKeysFromString,
  parseLiquidationCandidates,
  parseMatchIntent,
} from "../perps-keeper.js";

const USDC = "0x036cbd53842c5426634e7929541ec2318f3dcf7e" as const;
const EURC = "0x000000000000000000000000000000000000eefc" as const;
const ALICE = "0x000000000000000000000000000000000000a11c" as const;
const ROUTE = "0x000000000000000000000000000000000000a0df" as const;
const INTENT_ID = "0x1111111111111111111111111111111111111111111111111111111111111111" as const;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../../..");

describe("address registry", () => {
  test("Base Sepolia includes Morpho + Pyth + USDC", () => {
    const a = getAddresses(ChainId.BaseSepolia);
    expect(a.morphoBlue).toBe("0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb");
    expect(a.pyth).toBe("0xA2aa501b19aff244D90cc15a4Cf739D2725B5729");
    expect(a.usdc?.toLowerCase()).toBe(USDC);
    expect(a.pythFeedUSDC).toMatch(/^0x[0-9a-f]{64}$/);
  });

  test("Arc testnet known addresses", () => {
    const a = getAddresses(ChainId.ArcTestnet);
    expect(a.usdc).toBe("0x3600000000000000000000000000000000000000");
    expect(a.eurc).toBe("0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a");
    expect(a.pyth).toBe("0x2880aB155794e7179c9eE2e38200202908C17B43");
    expect(a.cctpDomain).toBe(26);
    expect(a.hyperlane).toMatchObject({
      domain: 5042002,
      mailbox: "0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9",
      interchainGasPaymaster: "0x0000000000000000000000000000000000000000",
      interchainAccountRouter: "0x113A539625D208b5EcC59f300Be14b9b3508E559",
    });
    // Arc hookathon yield-engine perp stack.
    expect(a.fxPerps).toMatchObject({
      clearinghouse: "0xCE3401BD53be4c0a8c7CCb0376b313925f99b8d2",
      marginAccount: "0x766b96971F484E7287E41130E9a5b248CDE44ca9",
      fundingEngine: "0x8b3b63D2031da48e3114871a49CD02B923E388e1",
      healthChecker: "0x12d18BC4b2295834Bb7A08aF5Bc2b40E40c7F53B",
      liquidationEngine: "0xA70aA9B3bCD3BB829B2E8aF29d8A48f5e09f50E5",
      orderSettlement: "0x904bb24A910c54A84341E157B894d11B474A2e1F",
      keeperAdmin: "0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69",
    });
  });

  test("Arc perps manifest parses and matches SDK address registry", () => {
    const manifestPath = resolve(REPO_ROOT, "deployments/perps-config-5042002.json");
    const manifest = parseFxPerpConfigManifest(JSON.parse(readFileSync(manifestPath, "utf8")) as unknown);
    assertFxPerpConfigReady(manifest);

    expect(manifest.chainId).toBe(ChainId.ArcTestnet);
    expect(manifest.liquidation.flagDelay).toBeGreaterThanOrEqual(MIN_LIQUIDATION_FLAG_DELAY);
    expect(manifest.usdc).toBe("0x3600000000000000000000000000000000000000");
    expect(fxPerpsAddressesFromConfigManifest(manifest)).toEqual(getAddresses(ChainId.ArcTestnet).fxPerps);
    expect(FX_PERP_MARKET_KEYS.map((key) => getFxPerpMarket(manifest, key).enabled)).toEqual([
      true,
      true,
      true,
      true,
    ]);
    expect(getFxPerpMarket(manifest, "EURC_USDC")).toMatchObject({
      marketId: "0x565a6e2fab61800aa18813603b5b485af5bed7dea1aa0845bdaa61502063cab8",
      baseToken: "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a",
      tradingFeeBps: 5,
    });
    expect(manifest.protocolLiquidity).toBeGreaterThanOrEqual(manifest.minProtocolLiquidity);
    expect(fxPerpContractAddressesJson(manifest)).toContain("FxPerpClearinghouse");
  });

  test("perps manifest rejects unsafe liquidation flag delays", () => {
    const manifestPath = resolve(REPO_ROOT, "deployments/perps-config-5042002.json");
    const raw = JSON.parse(readFileSync(manifestPath, "utf8")) as Record<string, unknown>;
    expect(() => parseFxPerpConfigManifest({ ...raw, liquidation_flagDelay: 0 })).toThrow(
      /flagDelay 0 below minimum 60/,
    );

    const manifest = parseFxPerpConfigManifest(raw);
    expect(() =>
      assertFxPerpConfigReady({
        ...manifest,
        liquidation: { ...manifest.liquidation, flagDelay: MIN_LIQUIDATION_FLAG_DELAY - 1n },
      }),
    ).toThrow(/flagDelay 59 below minimum 60/);
  });

  test("Fuji perps manifest parses with safe liquidation delay", () => {
    const manifestPath = resolve(REPO_ROOT, "deployments/perps-config-43113.json");
    const manifest = parseFxPerpConfigManifest(JSON.parse(readFileSync(manifestPath, "utf8")) as unknown);
    assertFxPerpConfigReady(manifest);

    expect(manifest.chainId).toBe(ChainId.AvalancheFuji);
    expect(manifest.marketKeys).toEqual(["EURC_USDC", "MXNB_USDC"]);
    expect(manifest.liquidation.flagDelay).toBeGreaterThanOrEqual(MIN_LIQUIDATION_FLAG_DELAY);
    expect(getFxPerpMarket(manifest, "MXNB_USDC")).toMatchObject({
      marketId: "0x7930040de904501a480cb2993edef814f14199d00fa1b9888e1aad6de76281be",
      baseToken: "0xAB99d44185af87AeB08361588F00F59B0CE85eBb",
      tradingFeeBps: 5,
    });
  });

  test("Arc perps runtime loader gates manifest and CONTRACT_ADDRESSES_JSON parity", () => {
    const manifestPath = resolve(REPO_ROOT, "deployments/perps-config-5042002.json");
    const manifest = parseFxPerpConfigManifest(JSON.parse(readFileSync(manifestPath, "utf8")) as unknown);
    const contractAddressesJson = fxPerpContractAddressesJson(manifest);
    const runtime = loadFxPerpRuntimeConfig({
      configPath: manifestPath,
      contractAddressesJson,
      env: {},
    });

    expect(runtime.source).toBe("manifest");
    expect(runtime.manifest?.chainId).toBe(ChainId.ArcTestnet);
    expect(runtime.addresses).toEqual(fxPerpsAddressesFromConfigManifest(manifest));
    expect(loadFxPerpRuntimeConfig({ cwd: resolve(REPO_ROOT, "packages/sdk"), env: {} }).configPath).toBe(
      manifestPath,
    );
    expect(parseFxPerpContractAddressesJson(contractAddressesJson)).toMatchObject({
      clearinghouse: manifest.addresses.clearinghouse,
      orderSettlement: manifest.addresses.orderSettlement,
    });

    const mismatchedJson = contractAddressesJson.replace(
      manifest.addresses.clearinghouse,
      "0x0000000000000000000000000000000000000001",
    );
    expect(() =>
      loadFxPerpRuntimeConfig({
        configPath: manifestPath,
        contractAddressesJson: mismatchedJson,
        env: {},
      }),
    ).toThrow(/does not match manifest/);
  });

  test("Arc perps keeper helpers parse components, matches, candidates, and JSON logs", () => {
    expect(keeperComponentsFromString("matcher,funding")).toEqual(["matcher", "funding"]);
    expect(keeperComponentsFromString("all")).toEqual(["matcher", "funding", "liquidation", "canary"]);
    expect(() => keeperComponentsFromString("unknown")).toThrow(/Unknown keeper component/);
    expect(marketKeysFromString(undefined, ["EURC_USDC"])).toEqual(["EURC_USDC"]);
    expect(marketKeysFromString("all", ["EURC_USDC"])).toEqual([
      "EURC_USDC",
      "JPYC_USDC",
      "TMXNB_USDC",
      "CIRBTC_USDC",
    ]);

    const marketId = "0x565a6e2fab61800aa18813603b5b485af5bed7dea1aa0845bdaa61502063cab8" as const;
    const maker = {
      order: {
        trader: "0x0000000000000000000000000000000000000a11",
        marketId,
        sizeDeltaE18: "10000000000000000",
        priceE18: "1160000000000000000",
        maxFee: "1000",
        orderType: 1,
        flags: 2,
        nonce: "1",
        deadline: "9999999999",
      },
      signature: `0x${"11".repeat(65)}`,
    };
    const taker = {
      order: {
        ...maker.order,
        trader: "0x0000000000000000000000000000000000000b0b",
        sizeDeltaE18: "-10000000000000000",
        flags: 0,
        nonce: "2",
      },
      signature: `0x${"22".repeat(65)}`,
    };
    const match = parseMatchIntent({
      maker,
      taker,
      fillSizeE18: "10000000000000000",
      fillPriceE18: "1160000000000000000",
    });
    expect(match.id).toMatch(/^0x[0-9a-f]{64}$/);
    expect(match.maker.order.nonce).toBe(1n);
    expect(match.taker.order.sizeDeltaE18).toBe(-10000000000000000n);

    expect(
      parseLiquidationCandidates(
        JSON.stringify({
          EURC_USDC: ["0x0000000000000000000000000000000000000a11"],
        }),
      ),
    ).toEqual({ EURC_USDC: ["0x0000000000000000000000000000000000000a11"] });

    const lines: string[] = [];
    createJsonLogger("test", (line) => lines.push(line)).info("bigint_ok", { component: "ignored", value: 7n });
    expect(JSON.parse(lines[0] ?? "{}")).toMatchObject({
      component: "test",
      event: "bigint_ok",
      value: "7",
    });
  });

  test("Arc testnet basket metadata follows live issuer migrations", () => {
    const a = getAddresses(ChainId.ArcTestnet);
    expect(a.stablecoinBasket?.audf).toMatchObject({
      symbol: "AUDF",
      decimals: 6,
      pythFeedInverted: false,
      redstoneFeedId: "AUD",
      source: "mock",
    });
    expect(a.stablecoinBasket?.jpyc).toMatchObject({
      symbol: "JPYC",
      address: "0xE7C3D8C9a439feDe00D2600032D5dB0Be71C3c29",
      decimals: 18,
      pythFeedInverted: false,
      redstoneFeedId: "JPY",
      source: "issuer",
    });
    // MXNB on Arc testnet upgraded to issuer-backed 2026-05-21.
    expect(a.stablecoinBasket?.mxnb).toMatchObject({
      symbol: "MXNB",
      address: "0x836F73Fbc370A9329Ba4957E47912DfDBA6BA461",
      decimals: 6,
      pythFeedInverted: true,
      redstoneFeedId: "MXN",
      source: "issuer",
    });
    expect(a.stablecoinBasket?.krw1).toMatchObject({
      symbol: "KRW1",
      decimals: 0,
      pythFeedInverted: true,
      redstoneFeedId: "KRW",
      source: "mock",
    });
    expect(a.stablecoinBasket?.zchf).toMatchObject({
      symbol: "ZCHF",
      decimals: 18,
      pythFeedInverted: true,
      redstoneFeedId: "CHF",
      source: "mock",
    });
    // cirBTC on Arc testnet upgraded to issuer-backed 2026-05-21
    // (replacing the prior Morpho Labs FakeCirBTC at 0x44cEe9…).
    expect(a.stablecoinBasket?.cirbtc).toMatchObject({
      symbol: "cirBTC",
      address: "0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF",
      decimals: 18,
      pythFeedId: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
      pythFeedInverted: false,
      redstoneFeedId: "BTC",
      source: "issuer",
    });
    // QCAD on Arc testnet dropped 2026-05-21.
    expect(a.stablecoinBasket?.qcad).toMatchObject({
      symbol: "QCAD",
      address: "0x23d7CFFd0876f3ABb6B074287ba2aeefBc83825d",
      decimals: 6,
      pythFeedInverted: true,
      redstoneFeedId: "CAD",
      source: "issuer",
    });
    expect(a.stablecoinBasket?.brla.source).toBe("excluded");
    expect(a.stablecoinBasket?.phpc.source).toBe("excluded");
  });

  test("Avalanche mainnet basket metadata uses issuer addresses for simulation", () => {
    const a = getAddresses(ChainId.AvalancheMainnet);
    expect(a.usdc).toBe("0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E");
    expect(a.eurc).toBe("0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD");
    expect(a.stablecoinBasket?.audf).toMatchObject({
      address: "0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b",
      decimals: 6,
      source: "issuer",
    });
    expect(a.stablecoinBasket?.jpyc).toMatchObject({
      address: "0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB",
      decimals: 18,
      source: "issuer",
    });
    expect(a.stablecoinBasket?.mxnb).toMatchObject({
      address: "0xF197FFC28c23E0309B5559e7a166f2c6164C80aA",
      decimals: 6,
      source: "issuer",
    });
    expect(a.stablecoinBasket?.zchf).toMatchObject({
      address: "0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553",
      decimals: 18,
      source: "issuer",
    });
    expect(a.stablecoinBasket?.krw1).toMatchObject({
      address: "0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318",
      decimals: 0,
      source: "issuer",
    });
    expect(a.hyperlane).toMatchObject({
      domain: 43114,
      mailbox: "0xFf06aFcaABaDDd1fb08371f9ccA15D73D51FeBD6",
      interchainAccountRouter: "0x2c58687fFfCD5b7043a5bF256B196216a98a6587",
    });
    expect(a.hyperlaneWarpRoutes?.find((route) => route.symbol === "JPYC")).toMatchObject({
      status: "planned",
      hubTokenSource: "collateralReleased",
      routeTokenType: "collateral",
    });
  });

  test("Avalanche Fuji points at the Stage 6 hub stack and self-loop spoke", () => {
    // Stage 6 redeploy: V1 (0xAa875a68…/0x365DE300…) is deprecated.
    // Round-3 codex finding patched these — addresses now mirror
    // deployments/avalanche-fuji.json.
    const a = getAddresses(ChainId.AvalancheFuji);
    expect(a.fxSpoke).toBe("0xb7fc291c27f6a7a659d4d229e5d8a55e58f26ab1");
    expect(a.fxSpokeAlt).toBe("0xe22ef07a0996df9ae6252cc9bf491fbe13fd6575");
    expect(a.fxHubMessageReceiver).toBe("0x7eAdfD0c08dd6544f763285bBD31be14179d594B");
    expect(a.fxGatewayHook).toBe("0x7dA191bfB85D9F14069228cf618519BFb41f371E");
    expect(a.cctpDomain).toBe(1);
    expect(a.hyperlane?.domain).toBe(43113);
    expect(a.hyperlane?.mailbox).toBe("0x5b6CFf85442B851A8e6eaBd2A4E4507B5135B3B0");
    expect(a.hyperlane?.appSpecificIsms?.[ChainId.ArcTestnet]).toBe(
      "0x3f5d9B44aa1D59D26B20862D91533d60B32d9aFa",
    );
    expect(a.usdc).toBe("0x5425890298aed601595a70AB815c96711a31Bc65");
    expect(a.eurc).toBe("0x5E44db7996c682E92a960b65AC713a54AD815c6B");
  });

  test("Arc testnet points at the Stage 6 hub stack and spider-web spokes", () => {
    // Stage 6 redeploy: V1 spoke (0x47c76D…) is deprecated. Mirrors
    // deployments/arc-testnet.json. Codex v3 round 3 finding patched these.
    const a = getAddresses(ChainId.ArcTestnet);
    expect(a.fxHubMessageReceiver).toBe("0x44B50E93eCC7775aF99bcd04c30e1A00da80F63C");
    expect(a.fxGatewayHook).toBe("0x2931C50745334d6DFf9eC4E3106fE05b49717DF1");
    expect(a.fxMarketRegistry).toBe("0x813232259c9b922e7571F15220617C80581f1464");
    expect(a.fxOracle).toBe("0x77b3A3B420dB98B01085b8C46a753Ed9879e2865");
    expect(a.fxReceiptUSDC).toBe("0xdd22365Bba7330BE537c9BC26da9b1b4Db9aC431");
    expect(a.fxReceiptEURC).toBe("0xF829f57Db8530fa93FCD6e13b00193cbe8cE1493");
    expect(a.fxLiquidator).toBe("0xa50f7D4D4a1A0D3CF418515973545b80E037B379");
    // Arc Morpho stack migrated 2026-05-21 from the self-deployed
    // 0x3c9b95C6… to Morpho Labs canonical 0x65f435eB….
    expect(a.morphoBlue).toBe("0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4");
    expect(a.adaptiveCurveIrm).toBe("0xBD583cc9807980f9e41f7c8250f594fB6173abE3");
    expect(a.morphoChainlinkOracleV2Factory).toBe("0xEBef760B0CA0d1Fa9578f47001A184Ee53EaE839");
    expect(a.morphoVaultV2Factory).toBe("0x6b7F638B64539F83810A1f6ea81C703b561C3Be6");
    expect(a.morphoMarketV1AdapterV2Factory).toBe("0x9372EbEDF2C64344817c67dAeD99512F4b9DC434");
    expect(a.morphoRegistryList).toBe("0xcba6be0EF65176CE7D440A4a93657fb2dd84200c");
    // Arc-resident spoke routing TO Fuji is the primary user entry from Arc.
    expect(a.fxSpoke).toBe("0x13c8463589d460db6f21235eedfd678c22a1ea25");
    // Arc-resident spoke routing TO local Arc hub (self-loop).
    expect(a.fxSpokeAlt).toBe("0x5d10d2c3b9951054845534b2f60a68ebc0898cd3");
    expect(a.cctpDomain).toBe(26);
  });
});

describe("Telaraña future spot FX config", () => {
  test("exports indexer-ready event names", () => {
    expect(TELARANA_SPOT_FX_EVENT_NAMES).toEqual([
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
    ]);
    expect(RFQ_PASILLO_EVENT_NAMES).toEqual([
      "RfqQuoteRequested",
      "RfqQuoteAccepted",
      "RfqQuoteFilled",
    ]);
  });

  test("exports Avalanche and Fuji spot token pair prep", () => {
    expect(TELARANA_AVALANCHE_SPOT_TOKEN_PAIRS.map((pair) => pair.quoteSymbol)).toEqual([
      "JPYC",
      "MXNB",
      "AUDF",
      "KRW1",
      "ZCHF",
    ]);
    expect(TELARANA_AVALANCHE_SPOT_TOKEN_PAIRS.every((pair) => pair.enabled === false)).toBe(true);
    expect(TELARANA_FUJI_SPOT_TOKEN_PAIRS[0]).toMatchObject({
      pairId: "avalanche-fuji-usdc-eurc",
      chainId: ChainId.AvalancheFuji,
      enabled: true,
    });
  });

  test("keeps v4 spot execution as placeholder config only", () => {
    expect(TELARANA_SPOT_HOOK_CONFIGS.every((hook) => hook.kind === "placeholder")).toBe(true);
    expect(TELARANA_SPOT_POOL_CONFIGS[0]).toMatchObject({
      status: "planned",
      hookConfigId: "fuji-v4-spot-placeholder",
    });
    expect(TELARANA_SPOT_ROUTE_CONFIGS[0]).toMatchObject({
      routeId: "fuji-usdc-eurc-spot-demo",
      kind: "internal-test",
      status: "configured",
    });
    expect(TELARANA_SPOT_ROUTE_CONFIGS[0].whitelistedCallers).toEqual([]);
  });

  test("exports event schemas for spot FX and RFQ Pasillo", () => {
    expect(TELARANA_SPOT_FX_INDEXER_SCHEMA.map((event) => event.name)).toContain("RouteConfigured");
    expect(TELARANA_SPOT_FX_INDEXER_SCHEMA.map((event) => event.name)).toContain("PoolConfigured");
    expect(RFQ_PASILLO_INDEXER_SCHEMA.map((event) => event.name)).toEqual([
      "RfqQuoteRequested",
      "RfqQuoteAccepted",
      "RfqQuoteFilled",
    ]);
  });
});

describe("Circle Gateway hub liquidity prep", () => {
  test("exports Fuji and Arc testnet Gateway chain config", () => {
    expect(TELARANA_GATEWAY_TESTNET_CHAINS).toHaveLength(2);

    const fuji = TELARANA_GATEWAY_TESTNET_CHAINS.find(
      (chain) => chain.chainId === ChainId.AvalancheFuji,
    );
    const arc = TELARANA_GATEWAY_TESTNET_CHAINS.find(
      (chain) => chain.chainId === ChainId.ArcTestnet,
    );

    expect(fuji).toMatchObject({
      domain: 1,
      usdc: "0x5425890298aed601595a70AB815c96711a31Bc65",
      gatewayWallet: "0x0077777d7EBA4688BDeF3E311b846F25870A19B9",
      gatewayMinter: "0x0022222ABE238Cc2C7Bb1f21003F0a260052475B",
    });
    expect(arc).toMatchObject({
      domain: 26,
      usdc: "0x3600000000000000000000000000000000000000",
      gatewayWallet: "0x0077777d7EBA4688BDeF3E311b846F25870A19B9",
      gatewayMinter: "0x0022222ABE238Cc2C7Bb1f21003F0a260052475B",
    });
    expect(GATEWAY_HUB_ACTION_IDS["mint-to-hub"]).toBe(0);
    expect(GATEWAY_HUB_ACTION_IDS["mint-and-request-spot-fx"]).toBe(1);
  });

  test("locks Circle Gateway EIP-712 type order", () => {
    expect(GATEWAY_EIP712_TYPES.TransferSpec.map((field) => field.name)).toEqual([
      "version",
      "sourceDomain",
      "destinationDomain",
      "sourceContract",
      "destinationContract",
      "sourceToken",
      "destinationToken",
      "sourceDepositor",
      "destinationRecipient",
      "sourceSigner",
      "destinationCaller",
      "value",
      "salt",
      "hookData",
    ]);
    expect(GATEWAY_EIP712_TYPES.BurnIntent.map((field) => field.name)).toEqual([
      "maxBlockHeight",
      "maxFee",
      "spec",
    ]);
  });

  test("builds a Fuji to Arc Gateway burn intent", () => {
    const route = TELARANA_GATEWAY_HUB_ROUTES.find(
      (candidate) => candidate.routeId === "gateway-fuji-to-arc-usdc",
    );
    if (!route) throw new Error("missing gateway-fuji-to-arc-usdc");

    const salt =
      "0x1111111111111111111111111111111111111111111111111111111111111111" as const;
    const intent = buildGatewayBurnIntent({
      route,
      amount: 25_000000n,
      sourceDepositor: ALICE,
      sourceSigner: ALICE,
      destinationRecipient: ROUTE,
      destinationCaller: ZERO_ADDRESS,
      maxBlockHeight: 123456789n,
      salt,
    });

    expect(intent.maxFee).toBe(2_010000n);
    expect(intent.spec.sourceDomain).toBe(1);
    expect(intent.spec.destinationDomain).toBe(26);
    expect(intent.spec.sourceContract).toBe(
      "0x0000000000000000000000000077777d7eba4688bdef3e311b846f25870a19b9",
    );
    expect(intent.spec.destinationContract).toBe(
      "0x0000000000000000000000000022222abe238cc2c7bb1f21003f0a260052475b",
    );
    expect(intent.spec.sourceToken).toBe(
      "0x0000000000000000000000005425890298aed601595a70ab815c96711a31bc65",
    );
    expect(intent.spec.destinationToken).toBe(
      "0x0000000000000000000000003600000000000000000000000000000000000000",
    );
    expect(intent.spec.sourceDepositor).toBe(evmAddressToGatewayBytes32(ALICE));
    expect(intent.spec.sourceSigner).toBe(evmAddressToGatewayBytes32(ALICE));
    expect(intent.spec.destinationRecipient).toBe(evmAddressToGatewayBytes32(ROUTE));
    expect(intent.spec.destinationCaller).toBe(evmAddressToGatewayBytes32(ZERO_ADDRESS));
    expect(gatewayBurnIntentToJson(intent).spec.value).toBe("25000000");
  });

  test("exports Gateway mint calldata and indexer events", () => {
    const walletFunctions = CircleGatewayWalletAbi.map((item) => item.name);
    const expected = encodeFunctionData({
      abi: CircleGatewayMinterAbi,
      functionName: "gatewayMint",
      args: ["0x1234", "0xabcd"],
    });

    expect(walletFunctions).toContain("deposit");
    expect(walletFunctions).toContain("availableBalance");
    expect(encodeGatewayMintCalldata("0x1234", "0xabcd")).toBe(expected);
    expect(GATEWAY_HUB_EVENT_NAMES).toContain("GatewayHubLiquidityReceived");
    expect(GATEWAY_HUB_EVENT_NAMES).toContain("GatewayAtomicFxSwapSettled");
    expect(GATEWAY_HUB_INDEXER_SCHEMA.map((event) => event.name)).toContain(
      "GatewayHubRouteConfigured",
    );
  });
});

describe("eligibility enum", () => {
  test("includes all expected reasons", () => {
    const values: string[] = Object.values(EligibilityReason);
    expect(values).toContain("OK");
    expect(values).toContain("NO_BUFI_WALLET");
    expect(values).toContain("NO_BUFI_KYC_PASS");
    expect(values).toContain("KYC_PENDING");
    expect(values).toContain("GHOST_ROUTE_UNAVAILABLE");
  });

  test("resolveRouteMode only returns Ghost when pass and route are live", () => {
    expect(
      resolveRouteMode(
        { public: true, ghost: true, reason: EligibilityReason.OK },
        FxRouteMode.Ghost,
        { deployed: true },
      ),
    ).toBe(FxRouteMode.Ghost);

    expect(
      resolveRouteMode(
        { public: true, ghost: false, reason: EligibilityReason.NO_BUFI_KYC_PASS },
        FxRouteMode.Ghost,
        { deployed: true },
      ),
    ).toBe(FxRouteMode.Public);

    expect(
      resolveRouteMode(
        { public: true, ghost: true, reason: EligibilityReason.OK },
        FxRouteMode.Ghost,
        { deployed: false },
      ),
    ).toBe(FxRouteMode.Public);
  });
});

describe("Ghost Mode prep", () => {
  test("exports indexer-ready Ghost event names", () => {
    expect(GHOST_MODE_EVENT_NAMES).toEqual([
      "GhostCommitmentRegistered",
      "GhostNullifierConsumed",
      "GhostSpokeEntered",
      "GhostRouteConfigured",
    ]);
    expect(GHOST_MODE_INDEXER_SCHEMA.map((event) => event.name)).toEqual([
      "GhostCommitmentRegistered",
      "GhostNullifierConsumed",
      "GhostSpokeEntered",
      "GhostRouteConfigured",
    ]);
  });

  test("exports Ghost router, registry, and hook ABIs", () => {
    const routerFunctions = FxGhostSpokeRouterAbi.filter((x) => x.type === "function").map((x) => x.name);
    const registryFunctions = FxGhostCommitmentRegistryAbi.filter((x) => x.type === "function").map((x) => x.name);
    const hookFunctions = FxGhostKycHookAbi.filter((x) => x.type === "function").map((x) => x.name);

    expect(routerFunctions).toContain("enterHubGhost");
    expect(routerFunctions).toContain("setGhostRoute");
    expect(registryFunctions).toContain("registerCommitment");
    expect(registryFunctions).toContain("consumeNullifier");
    expect(hookFunctions).toContain("beforeSwap");
    expect(hookFunctions).toContain("getHookPermissions");
  });
});

describe("planSupply / planBorrow", () => {
  test("planSupply matches encodeFunctionData", () => {
    const ours = planSupply({
      loanToken: USDC,
      collateralToken: EURC,
      assets: 1_000_000n,
      onBehalf: ALICE,
    });
    const ref = encodeFunctionData({
      abi: FxMarketRegistryAbi,
      functionName: "supply",
      args: [USDC, EURC, 1_000_000n, ALICE],
    });
    expect(ours).toBe(ref);
  });

  test("planBorrow encodes correctly", () => {
    const data = planBorrow({
      loanToken: USDC,
      collateralToken: EURC,
      assets: 500_000n,
      onBehalf: ALICE,
      receiver: ALICE,
    });
    expect(data).toMatch(/^0x[0-9a-f]+$/);
    expect(data.length).toBeGreaterThan(10);
  });

  test("planWithdraw / planSupplyCollateral / planRepay all produce valid hex", () => {
    expect(
      planWithdraw({
        loanToken: USDC,
        collateralToken: EURC,
        shares: 1n,
        onBehalf: ALICE,
        receiver: ALICE,
      }),
    ).toMatch(/^0x/);
    expect(
      planSupplyCollateral({
        loanToken: USDC,
        collateralToken: EURC,
        collateral: 1n,
        onBehalf: ALICE,
      }),
    ).toMatch(/^0x/);
    expect(
      planRepay({
        loanToken: USDC,
        collateralToken: EURC,
        assets: 1n,
        onBehalf: ALICE,
      }),
    ).toMatch(/^0x/);
  });
});

describe("planEnterHub composition", () => {
  test("wraps a planSupply hubCalldata correctly", () => {
    const hubCalldata = planSupply({
      loanToken: USDC,
      collateralToken: EURC,
      assets: 1_000_000n,
      onBehalf: ALICE,
    });
    const spokeCall = planEnterHub({
      token: USDC,
      amount: 1_000_000n,
      beneficiary: ALICE,
      hubCalldata,
    });

    const ref = encodeFunctionData({
      abi: FxSpokeAbi,
      functionName: "enterHub",
      args: [USDC, 1_000_000n, ALICE, hubCalldata],
    });
    expect(spokeCall).toBe(ref);
  });
});

describe("Hyperlane helpers", () => {
  test("left-pads EVM addresses to Hyperlane bytes32", () => {
    expect(hyperlaneAddressToBytes32(ALICE)).toBe(
      "0x000000000000000000000000000000000000000000000000000000000000a11c",
    );
  });

  test("encodes Warp Route transferRemote", () => {
    const data = planHyperlaneWarpTransferRemote({
      destinationDomain: 43114,
      recipient: ALICE,
      amount: 1_000_000n,
    });
    const ref = encodeFunctionData({
      abi: HyperlaneWarpRouteAbi,
      functionName: "transferRemote",
      args: [
        43114,
        "0x000000000000000000000000000000000000000000000000000000000000a11c",
        1_000_000n,
      ],
    });
    expect(data).toBe(ref);
  });

  test("encodes ICA callRemote for hub-side action", () => {
    const hubCall = planSupplyCollateral({
      loanToken: EURC,
      collateralToken: USDC,
      collateral: 1_000_000n,
      onBehalf: ALICE,
    });
    const data = planHyperlaneIcaCallRemote({
      destinationDomain: 43114,
      calls: [{ to: ALICE, data: hubCall }],
    });
    const ref = encodeFunctionData({
      abi: HyperlaneInterchainAccountRouterAbi,
      functionName: "callRemote",
      args: [
        43114,
        [
          {
            to: "0x000000000000000000000000000000000000000000000000000000000000a11c",
            value: 0n,
            data: hubCall,
          },
        ],
      ],
    });
    expect(data).toBe(ref);
  });

  test("encodes FxSpokeIntentRouter sendIntent", () => {
    const data = planFxSpokeIntent({
      action: FxHyperlaneAction.SupplyCollateral,
      beneficiary: ALICE,
      inputToken: USDC,
      inputAmount: 1_000_000n,
      loanToken: EURC,
      collateralToken: USDC,
      route: ROUTE,
    });
    const ref = encodeFunctionData({
      abi: FxSpokeIntentRouterAbi,
      functionName: "sendIntent",
      args: [FxHyperlaneAction.SupplyCollateral, ALICE, USDC, 1_000_000n, EURC, USDC, ROUTE],
    });
    expect(data).toBe(ref);
  });

  test("encodes FxSpokeIntentRouter borrow intent without route token", () => {
    const data = planFxSpokeIntent({
      action: FxHyperlaneAction.Borrow,
      beneficiary: ALICE,
      inputToken: ZERO_ADDRESS,
      inputAmount: 1_000_000n,
      loanToken: EURC,
      collateralToken: USDC,
      route: ZERO_ADDRESS,
    });
    const ref = encodeFunctionData({
      abi: FxSpokeIntentRouterAbi,
      functionName: "sendIntent",
      args: [FxHyperlaneAction.Borrow, ALICE, ZERO_ADDRESS, 1_000_000n, EURC, USDC, ZERO_ADDRESS],
    });
    expect(data).toBe(ref);
  });

  test("encodes FxHyperlaneHubReceiver executeIntent", () => {
    const data = planExecuteHyperlaneIntent(INTENT_ID);
    const ref = encodeFunctionData({
      abi: FxHyperlaneHubReceiverAbi,
      functionName: "executeIntent",
      args: [INTENT_ID],
    });
    expect(data).toBe(ref);
  });

  test("encodes FxHyperlaneHubReceiver executeRoutedIntent", () => {
    const data = planExecuteRoutedHyperlaneIntent(INTENT_ID);
    const ref = encodeFunctionData({
      abi: FxHyperlaneHubReceiverAbi,
      functionName: "executeRoutedIntent",
      args: [INTENT_ID],
    });
    expect(data).toBe(ref);
  });
});

describe("ABI exports", () => {
  test("FxOracle ABI includes getMid + getMidVerified + getMidWithUpdate", () => {
    const fnNames = FxOracleAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(fnNames).toContain("getMid");
    expect(fnNames).toContain("getMidVerified");
    expect(fnNames).toContain("getMidWithUpdate");
  });

  test("FxSwapHook ABI exposes oracle observation and dynamic spread surfaces", () => {
    const fnNames = FxSwapHookAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(fnNames).toContain("recordOracleObservation");
    expect(fnNames).toContain("previewOracleObservation");
    expect(fnNames).toContain("effectiveSpreadBps");
    expect(fnNames).toContain("setOracleGuardrails");
  });

  test("FxMarketRegistry ABI exposes the routing surface", () => {
    const fnNames: string[] = FxMarketRegistryAbi
      .filter((x) => x.type === "function")
      .map((x) => x.name);
    for (const required of [
      "supply",
      "withdraw",
      "borrow",
      "borrowDelegated",
      "repay",
      "supplyCollateral",
      "withdrawCollateral",
      "setBorrowDelegate",
      "marketIdOf",
      "paramsOf",
    ]) {
      expect(fnNames).toContain(required);
    }
  });

  test("FxSpoke ABI exposes Circle-only spoke controls", () => {
    const fnNames = FxSpokeAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(fnNames).toContain("setCircleTokenAllowed");
    expect(fnNames).toContain("transferOwner");
    expect(fnNames).toContain("exitHubForToken");

    const enterHub = FxSpokeAbi.find((x) => x.type === "function" && x.name === "enterHub");
    expect(enterHub).toBeDefined();
    if (enterHub && enterHub.type === "function") {
      const argNames = enterHub.inputs.map((i) => i.name);
      expect(argNames).toContain("beneficiary");
    }
  });

  test("Hyperlane ABI exports include Warp Route and ICA surfaces", () => {
    expect(HyperlaneWarpRouteAbi.some((x) => x.type === "function" && x.name === "transferRemote")).toBe(true);
    expect(
      HyperlaneInterchainAccountRouterAbi.some((x) => x.type === "function" && x.name === "callRemote"),
    ).toBe(true);
    expect(FxSpokeIntentRouterAbi.some((x) => x.type === "function" && x.name === "sendIntent")).toBe(true);
    expect(FxHyperlaneHubReceiverAbi.some((x) => x.type === "function" && x.name === "executeIntent")).toBe(true);
    expect(FxHyperlaneHubReceiverAbi.some((x) => x.type === "function" && x.name === "executeRoutedIntent")).toBe(
      true,
    );
  });

  test("Gateway hub hook ABI exposes mint and settlement surfaces", () => {
    const fnNames = TelaranaGatewayHubHookAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(fnNames).toContain("setGatewayRoute");
    expect(fnNames).toContain("receiveGatewayMint");
    expect(fnNames).toContain("markGatewayAtomicFxSwapSettled");
    expect(fnNames).toContain("gatewayReceipt");
  });

  test("Phase B-E perp ABI exports expose trading and risk surfaces", () => {
    const clearinghouseFunctions = FxPerpClearinghouseAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(clearinghouseFunctions).toContain("configureMarket");
    expect(clearinghouseFunctions).toContain("quoteFee");
    expect(clearinghouseFunctions).toContain("openOrIncrease");
    expect(clearinghouseFunctions).toContain("applyOrderFill");
    expect(clearinghouseFunctions).toContain("liquidatePosition");
    expect(clearinghouseFunctions).toContain("setFundingEngine");
    expect(clearinghouseFunctions).toContain("settleTraderFunding");

    const marginFunctions = FxMarginAccountAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(marginFunctions).toContain("depositMargin");
    expect(marginFunctions).toContain("depositProtocolLiquidity");
    expect(marginFunctions).toContain("setFundingSettlementHook");

    const fundingFunctions = FxFundingEngineAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(fundingFunctions).toContain("configureFunding");
    expect(fundingFunctions).toContain("pokeFundingRate");
    expect(fundingFunctions).toContain("settleFunding");

    const healthFunctions = FxHealthCheckerAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(healthFunctions).toContain("healthFactor");
    expect(healthFunctions).toContain("isLiquidatable");
    // Sprint-1 codex r0 P1 #1: strict-oracle counterparts MUST appear on
    // the surface so integrators can route through the verified path.
    expect(healthFunctions).toContain("healthFactorVerified");
    expect(healthFunctions).toContain("isLiquidatableVerified");

    const liquidationFunctions = FxLiquidationEngineAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(liquidationFunctions).toContain("configureLiquidation");
    expect(liquidationFunctions).toContain("flagAccount");
    expect(liquidationFunctions).toContain("liquidate");
    // Sprint-1 codex r0 P1 #5: rescindFlag is the anti-flag-bomb surface.
    // Sprint-1 codex r1 LOW: third-party indexers need AccountFlagRescinded
    // exported so they don't classify auto-rescind as an unknown event.
    expect(liquidationFunctions).toContain("rescindFlag");
    const liquidationEvents = FxLiquidationEngineAbi.filter((x) => x.type === "event").map((x) => x.name);
    expect(liquidationEvents).toContain("AccountFlagRescinded");
    expect(liquidationEvents).toContain("AccountLiquidated");

    const settlementFunctions = FxOrderSettlementAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(settlementFunctions).toContain("hashOrder");
    expect(settlementFunctions).toContain("settleMatch");
  });

  test("Bufi pass ABI exposes the Ghost Mode verifier surface", () => {
    const fnNames = IBufiKycPassAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(fnNames).toContain("hasValidPass");
    expect(fnNames).toContain("passLevel");
  });
});
