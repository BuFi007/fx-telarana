// SPDX-License-Identifier: Apache-2.0
import { describe, expect, test } from "bun:test";
import { encodeFunctionData } from "viem";

import {
  ChainId,
  EligibilityReason,
  FxRouteMode,
  FxHyperlaneAction,
  FxHyperlaneHubReceiverAbi,
  FxMarketRegistryAbi,
  FxOracleAbi,
  FxSpokeAbi,
  FxSpokeIntentRouterAbi,
  FxSwapHookAbi,
  HyperlaneInterchainAccountRouterAbi,
  HyperlaneWarpRouteAbi,
  IBufiKycPassAbi,
  getAddresses,
  hyperlaneAddressToBytes32,
  resolveRouteMode,
  planExecuteHyperlaneIntent,
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

  test("Avalanche Fuji points at the Fuji hub and self-loop spoke", () => {
    const a = getAddresses(ChainId.AvalancheFuji);
    expect(a.fxSpoke).toBe("0xAa875a68b0155da4bD6A528ee9e1137017D18b41");
    expect(a.fxHubMessageReceiver).toBe("0x365DE300dDa61C81a33bcE3606A5d524eD964362");
    expect(a.cctpDomain).toBe(1);
    expect(a.hyperlane?.domain).toBe(43113);
    expect(a.hyperlane?.mailbox).toBe("0x5b6CFf85442B851A8e6eaBd2A4E4507B5135B3B0");
    expect(a.hyperlane?.appSpecificIsms?.[ChainId.ArcTestnet]).toBe(
      "0x3f5d9B44aa1D59D26B20862D91533d60B32d9aFa",
    );
    expect(a.usdc).toBe("0x5425890298aed601595a70AB815c96711a31Bc65");
    expect(a.eurc).toBe("0x5E44db7996c682E92a960b65AC713a54AD815c6B");
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

  test("encodes FxHyperlaneHubReceiver executeIntent", () => {
    const data = planExecuteHyperlaneIntent(INTENT_ID);
    const ref = encodeFunctionData({
      abi: FxHyperlaneHubReceiverAbi,
      functionName: "executeIntent",
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
    for (const required of ["supply", "withdraw", "borrow", "repay", "supplyCollateral", "withdrawCollateral", "marketIdOf", "paramsOf"]) {
      expect(fnNames).toContain(required);
    }
  });

  test("FxSpoke ABI exposes enterHub with explicit beneficiary arg", () => {
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
  });

  test("Bufi pass ABI exposes the Ghost Mode verifier surface", () => {
    const fnNames = IBufiKycPassAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(fnNames).toContain("hasValidPass");
    expect(fnNames).toContain("passLevel");
  });
});
