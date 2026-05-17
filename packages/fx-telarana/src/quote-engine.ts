// SPDX-License-Identifier: AGPL-3.0-only
import { MAX_UINT_256, ORACLE_PRICE_SCALE, WAD } from "./constants.js";
import { mulDivDown, toAssetsDown, toAssetsUp, toSharesDown } from "./morpho-math.js";
import type { BorrowQuote, LendingMarket } from "./types.js";

export function calculateCollateralValueE18(collateralAssets: bigint, collateralPriceE36: bigint): bigint {
  return mulDivDown(collateralAssets, collateralPriceE36, ORACLE_PRICE_SCALE);
}

export function calculateHealthFactorE18(args: {
  collateralAssets: bigint;
  collateralPriceE36: bigint;
  borrowAssetsE18: bigint;
  lltv: bigint;
}): bigint {
  if (args.borrowAssetsE18 === 0n) return MAX_UINT_256;
  const collateralValueE18 = calculateCollateralValueE18(
    args.collateralAssets,
    args.collateralPriceE36
  );
  return (collateralValueE18 * args.lltv) / args.borrowAssetsE18;
}

export function maxBorrowAssets(args: {
  collateralAssets: bigint;
  collateralPriceE36: bigint;
  lltv: bigint;
}): bigint {
  const collateralValueE18 = calculateCollateralValueE18(
    args.collateralAssets,
    args.collateralPriceE36
  );
  return (collateralValueE18 * args.lltv) / WAD;
}

export function quoteSupply(args: {
  assets: bigint;
  totalSupplyAssets: bigint;
  totalSupplyShares: bigint;
}) {
  return {
    assets: args.assets,
    supplyShares: toSharesDown(args.assets, args.totalSupplyAssets, args.totalSupplyShares),
  };
}

export function quoteWithdraw(args: {
  shares: bigint;
  totalSupplyAssets: bigint;
  totalSupplyShares: bigint;
}) {
  return {
    shares: args.shares,
    assetsOut: toAssetsDown(args.shares, args.totalSupplyAssets, args.totalSupplyShares),
  };
}

export function quoteRepay(args: {
  assets: bigint;
  totalBorrowAssets: bigint;
  totalBorrowShares: bigint;
}) {
  return {
    assets: args.assets,
    borrowSharesBurned: toSharesDown(args.assets, args.totalBorrowAssets, args.totalBorrowShares),
  };
}

export function quoteBorrow(args: {
  market: LendingMarket;
  collateral: bigint;
  borrowAmount: bigint;
  existingBorrowShares?: bigint;
  totalBorrowAssets?: bigint;
  totalBorrowShares?: bigint;
  collateralPriceE36: bigint;
}): BorrowQuote {
  const currentBorrow =
    args.existingBorrowShares && args.totalBorrowAssets !== undefined && args.totalBorrowShares !== undefined
      ? toAssetsUp(args.existingBorrowShares, args.totalBorrowAssets, args.totalBorrowShares)
      : 0n;
  const borrowAfter = currentBorrow + args.borrowAmount;
  const hf = calculateHealthFactorE18({
    collateralAssets: args.collateral,
    collateralPriceE36: args.collateralPriceE36,
    borrowAssetsE18: borrowAfter,
    lltv: args.market.lltv,
  });
  return {
    market: args.market,
    collateral: args.collateral,
    borrowAmount: args.borrowAmount,
    borrowAssetsAfter: borrowAfter,
    healthFactorE18: hf,
    liquidatable: hf < WAD,
    maxBorrowAssets: maxBorrowAssets({
      collateralAssets: args.collateral,
      collateralPriceE36: args.collateralPriceE36,
      lltv: args.market.lltv,
    }),
  };
}
