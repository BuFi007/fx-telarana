// SPDX-License-Identifier: Apache-2.0
import { describe, expect, test } from "bun:test";
import { encodeFunctionData } from "viem";

import {
  ChainId,
  CircleGatewayMinterAbi,
  CircleGatewayWalletAbi,
  EligibilityReason,
  FxRouteMode,
  FxHyperlaneAction,
  FxHyperlaneHubReceiverAbi,
  FxGhostCommitmentRegistryAbi,
  FxGhostKycHookAbi,
  FxGhostSpokeRouterAbi,
  FxMarketRegistryAbi,
  FxOracleAbi,
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
  gatewayBurnIntentToJson,
  getAddresses,
  hyperlaneAddressToBytes32,
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

const USDC = "0x036cbd53842c5426634e7929541ec2318f3dcf7e" as const;
const EURC = "0x000000000000000000000000000000000000eefc" as const;
const ALICE = "0x000000000000000000000000000000000000a11c" as const;
const ROUTE = "0x000000000000000000000000000000000000a0df" as const;
const INTENT_ID = "0x1111111111111111111111111111111111111111111111111111111111111111" as const;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

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
  });

  test("Arc testnet basket metadata follows Phase 3 mock scope", () => {
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
      decimals: 18,
      pythFeedInverted: true,
      redstoneFeedId: "JPY",
      source: "mock",
    });
    expect(a.stablecoinBasket?.mxnb).toMatchObject({
      symbol: "MXNB",
      decimals: 6,
      pythFeedInverted: true,
      redstoneFeedId: "MXN",
      source: "mock",
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

  test("Avalanche Fuji points at the canonical EURC hub stack and self-loop spoke", () => {
    const a = getAddresses(ChainId.AvalancheFuji);
    expect(a.fxSpoke).toBe("0x6EC2197aC1c35Fbe64533101a3DFf081BD45Ed99");
    expect(a.fxSpokeAlt).toBe("0x77b3A3B420dB98B01085b8C46a753Ed9879e2865");
    expect(a.fxHubMessageReceiver).toBe("0xbBc9AE9dbd3F6D3dB672F0CA2419d0f4C8513062");
    expect(a.fxGatewayHook).toBe("0x1527f0230e07B202812A0F0E437995323A1a98cB");
    expect(a.cctpDomain).toBe(1);
    expect(a.hyperlane?.domain).toBe(43113);
    expect(a.hyperlane?.mailbox).toBe("0x5b6CFf85442B851A8e6eaBd2A4E4507B5135B3B0");
    expect(a.hyperlane?.appSpecificIsms?.[ChainId.ArcTestnet]).toBe(
      "0x3f5d9B44aa1D59D26B20862D91533d60B32d9aFa",
    );
    expect(a.usdc).toBe("0x5425890298aed601595a70AB815c96711a31Bc65");
    expect(a.eurc).toBe("0x5E44db7996c682E92a960b65AC713a54AD815c6B");
  });

  test("Arc testnet points at the current hub stack and spider-web spokes", () => {
    const a = getAddresses(ChainId.ArcTestnet);
    expect(a.fxHubMessageReceiver).toBe("0xED8D2F831A8b7EbF7eb86a52323D23e2277F26b6");
    expect(a.fxGatewayHook).toBe("0x6a134214303136Ea8aa1cfA054Baf3ca74eCdad9");
    expect(a.fxMarketRegistry).toBe("0x1126aA03E678f2bc87A936AA63Df972c7c338b8b");
    expect(a.fxOracle).toBe("0x217860736E626781f9AaA91731b307619f90f65B");
    expect(a.fxReceiptUSDC).toBe("0x9559A55Ea94aF58002a857f73B15c8EF4E850Fd8");
    expect(a.fxReceiptEURC).toBe("0x7926D3b1D1360632e81F811FE9a39866Fe16074F");
    expect(a.fxLiquidator).toBe("0x4dB43e41420ACC39ee88dBc1cB868567968C0F12");
    expect(a.morphoBlue).toBe("0x3c9b95C6E7B23f094f066733E7797C8680760830");
    expect(a.adaptiveCurveIrm).toBe("0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1");
    // Arc-resident spoke routing TO Fuji is the primary user entry from Arc.
    expect(a.fxSpoke).toBe("0xf93834070e4e4e7ff0e161feca2aeba65c2c6a38");
    // Arc-resident spoke routing TO local Arc hub (self-loop).
    expect(a.fxSpokeAlt).toBe("0xb7bda9e3a09c91be6e616b58e1d855850ff46aed");
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

  test("Bufi pass ABI exposes the Ghost Mode verifier surface", () => {
    const fnNames = IBufiKycPassAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(fnNames).toContain("hasValidPass");
    expect(fnNames).toContain("passLevel");
  });
});
