// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import {
  applyBorrowToMarket,
  applyBorrowToPosition,
  applyLiquidationToMarket,
  applyLiquidationToPosition,
  applyRepayToMarket,
  applyRepayToPosition,
  applySupplyCollateralToPosition,
  applySupplyToMarket,
  applySupplyToPosition,
  applyWithdrawCollateralToPosition,
  applyWithdrawToMarket,
  applyWithdrawToPosition,
} from "./lending-state.js";

const market = {
  totalSupplyAssets: 1_000n,
  totalSupplyShares: 100n,
  totalBorrowAssets: 500n,
  totalBorrowShares: 50n,
};

const position = {
  supplyShares: 25n,
  borrowShares: 10n,
  collateral: 900n,
};

describe("Ponder lending state reducers", () => {
  test("applies supply and withdraw to market and position totals", () => {
    expect(applySupplyToMarket(market, { assets: 50n, shares: 5n, lastUpdated: 10n })).toMatchObject({
      totalSupplyAssets: 1_050n,
      totalSupplyShares: 105n,
      lastUpdated: 10n,
    });
    expect(applySupplyToPosition(position, { shares: 5n, lastUpdated: 10n })).toMatchObject({
      supplyShares: 30n,
      lastUpdated: 10n,
    });
    expect(applyWithdrawToMarket(market, { assets: 2_000n, shares: 200n, lastUpdated: 11n })).toMatchObject({
      totalSupplyAssets: 0n,
      totalSupplyShares: 0n,
      lastUpdated: 11n,
    });
    expect(applyWithdrawToPosition(position, { shares: 30n, lastUpdated: 11n })).toMatchObject({
      supplyShares: 0n,
      lastUpdated: 11n,
    });
  });

  test("applies borrow and repay to market and position totals", () => {
    expect(applyBorrowToMarket(market, { assets: 80n, shares: 8n, lastUpdated: 12n })).toMatchObject({
      totalBorrowAssets: 580n,
      totalBorrowShares: 58n,
      lastUpdated: 12n,
    });
    expect(applyBorrowToPosition(position, { shares: 4n, lastUpdated: 12n })).toMatchObject({
      borrowShares: 14n,
      lastUpdated: 12n,
    });
    expect(applyRepayToMarket(market, { assets: 800n, shares: 80n, lastUpdated: 13n })).toMatchObject({
      totalBorrowAssets: 0n,
      totalBorrowShares: 0n,
      lastUpdated: 13n,
    });
    expect(applyRepayToPosition(position, { shares: 20n, lastUpdated: 13n })).toMatchObject({
      borrowShares: 0n,
      lastUpdated: 13n,
    });
  });

  test("applies collateral supply and withdrawal", () => {
    expect(applySupplyCollateralToPosition(position, { assets: 100n, lastUpdated: 14n })).toMatchObject({
      collateral: 1_000n,
      lastUpdated: 14n,
    });
    expect(applyWithdrawCollateralToPosition(position, { assets: 950n, lastUpdated: 15n })).toMatchObject({
      collateral: 0n,
      lastUpdated: 15n,
    });
  });

  test("applies liquidation bad debt, repay, and seized collateral", () => {
    expect(
      applyLiquidationToMarket(market, {
        repaidAssets: 100n,
        repaidShares: 10n,
        badDebtAssets: 30n,
        badDebtShares: 3n,
        lastUpdated: 16n,
      })
    ).toMatchObject({
      totalSupplyAssets: 970n,
      totalBorrowAssets: 370n,
      totalBorrowShares: 37n,
      lastUpdated: 16n,
    });
    expect(
      applyLiquidationToPosition(position, {
        repaidShares: 6n,
        badDebtShares: 2n,
        seizedAssets: 300n,
        lastUpdated: 16n,
      })
    ).toMatchObject({
      borrowShares: 2n,
      collateral: 600n,
      lastUpdated: 16n,
    });
  });
});
