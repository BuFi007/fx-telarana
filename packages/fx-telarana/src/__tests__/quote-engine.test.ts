// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import { WAD } from "../constants.js";
import { calculateHealthFactorE18, maxBorrowAssets } from "../quote-engine.js";

describe("quote engine health factor", () => {
  test("returns liquidatable=false threshold math in E18", () => {
    const hf = calculateHealthFactorE18({
      collateralAssets: 100n * WAD,
      collateralPriceE36: 1_000_000_000_000_000_000_000_000_000_000_000_000n,
      borrowAssetsE18: 50n * WAD,
      lltv: 860_000_000_000_000_000n,
    });

    expect(hf).toBe(1_720_000_000_000_000_000n);
  });

  test("max borrow follows collateral value times lltv", () => {
    expect(
      maxBorrowAssets({
        collateralAssets: 100n * WAD,
        collateralPriceE36: 1_000_000_000_000_000_000_000_000_000_000_000_000n,
        lltv: 860_000_000_000_000_000n,
      })
    ).toBe(86n * WAD);
  });
});
