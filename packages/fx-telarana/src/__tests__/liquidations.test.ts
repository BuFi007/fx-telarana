// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import { ChainId } from "@fx-telarana/contracts";

import { rankLiquidationCandidates } from "../liquidations.js";
import type { AccountPosition } from "../types.js";

function position(account: string, hf: bigint): AccountPosition {
  return {
    id: `0xabc-${account}`,
    marketId: "0xabc0000000000000000000000000000000000000000000000000000000000000",
    hubChainId: ChainId.AvalancheFuji,
    account: account as `0x${string}`,
    supplyShares: 0n,
    borrowShares: 1n,
    collateral: 1n,
    supplyAssets: 0n,
    borrowAssets: 1n,
    healthFactorE18: hf,
    liquidatable: hf < 1_000_000_000_000_000_000n,
  };
}

describe("liquidation candidate scanner", () => {
  test("sorts by health factor ascending", () => {
    const ranked = rankLiquidationCandidates([
      position("0x0000000000000000000000000000000000000002", 2_000_000_000_000_000_000n),
      position("0x0000000000000000000000000000000000000001", 900_000_000_000_000_000n),
    ]);

    expect(ranked[0]?.healthFactorE18).toBe(900_000_000_000_000_000n);
    expect(ranked[0]?.rank).toBe(1);
  });
});
