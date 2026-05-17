// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import { ChainId } from "@fx-telarana/contracts";

import { WAD } from "../constants.js";
import { buildAccountPositionView } from "../positions.js";
import type { LendingMarket } from "../types.js";

const market: LendingMarket = {
  id: "0x1111111111111111111111111111111111111111111111111111111111111111",
  hubChainId: ChainId.AvalancheFuji,
  hubName: "fuji",
  loanToken: "0x1111111111111111111111111111111111111111",
  collateralToken: "0x2222222222222222222222222222222222222222",
  oracle: "0x3333333333333333333333333333333333333333",
  irm: "0x4444444444444444444444444444444444444444",
  lltv: 860_000_000_000_000_000n,
  isLive: true,
};

describe("position view builder", () => {
  test("computes assets and health factor from Morpho shares plus FxOracle price", () => {
    const position = buildAccountPositionView({
      market,
      account: "0x5555555555555555555555555555555555555555",
      state: {
        totalSupplyAssets: 200n,
        totalSupplyShares: 200_000_000n,
        totalBorrowAssets: 100n,
        totalBorrowShares: 100_000_000n,
        lastUpdate: 1n,
        fee: 0n,
      },
      position: {
        supplyShares: 20_000_000n,
        borrowShares: 50_000_000n,
        collateral: 100n,
      },
      oracle: {
        midE18: WAD,
        publishedAt: 123n,
      },
    });

    expect(position.supplyAssets).toBe(20n);
    expect(position.borrowAssets).toBe(50n);
    expect(position.collateralPriceE36).toBe(WAD * WAD);
    expect(position.healthFactorE18).toBe(1_720_000_000_000_000_000n);
    expect(position.liquidatable).toBe(false);
  });
});
