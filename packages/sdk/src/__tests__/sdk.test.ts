import { describe, expect, test } from "bun:test";
import { encodeFunctionData } from "viem";

import {
  ChainId,
  EligibilityReason,
  FxMarketRegistryAbi,
  FxOracleAbi,
  FxSpokeAbi,
  getAddresses,
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
  });
});

describe("eligibility enum", () => {
  test("includes all expected reasons", () => {
    const values: string[] = Object.values(EligibilityReason);
    expect(values).toContain("OK");
    expect(values).toContain("NO_HINKAL_ACCESS_TOKEN");
    expect(values).toContain("KYC_PENDING");
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

describe("ABI exports", () => {
  test("FxOracle ABI includes getMid + getMidVerified + getMidWithUpdate", () => {
    const fnNames = FxOracleAbi.filter((x) => x.type === "function").map((x) => x.name);
    expect(fnNames).toContain("getMid");
    expect(fnNames).toContain("getMidVerified");
    expect(fnNames).toContain("getMidWithUpdate");
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
});
