// SPDX-License-Identifier: AGPL-3.0-only
export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

type MarketTotals = {
  totalSupplyAssets: bigint;
  totalSupplyShares: bigint;
  totalBorrowAssets: bigint;
  totalBorrowShares: bigint;
};

type PositionTotals = {
  supplyShares: bigint;
  borrowShares: bigint;
  collateral: bigint;
};

type AssetsShares = {
  assets: bigint;
  shares: bigint;
  lastUpdated: bigint;
};

export function positionRowId(marketKey: string, account: `0x${string}`): string {
  return `${marketKey}:${account.toLowerCase()}`;
}

export function subFloor(value: bigint, amount: bigint): bigint {
  return value > amount ? value - amount : 0n;
}

export function applySupplyToMarket(row: MarketTotals, args: AssetsShares) {
  return {
    totalSupplyAssets: row.totalSupplyAssets + args.assets,
    totalSupplyShares: row.totalSupplyShares + args.shares,
    lastUpdated: args.lastUpdated,
  };
}

export function applyWithdrawToMarket(row: MarketTotals, args: AssetsShares) {
  return {
    totalSupplyAssets: subFloor(row.totalSupplyAssets, args.assets),
    totalSupplyShares: subFloor(row.totalSupplyShares, args.shares),
    lastUpdated: args.lastUpdated,
  };
}

export function applyBorrowToMarket(row: MarketTotals, args: AssetsShares) {
  return {
    totalBorrowAssets: row.totalBorrowAssets + args.assets,
    totalBorrowShares: row.totalBorrowShares + args.shares,
    lastUpdated: args.lastUpdated,
  };
}

export function applyRepayToMarket(row: MarketTotals, args: AssetsShares) {
  return {
    totalBorrowAssets: subFloor(row.totalBorrowAssets, args.assets),
    totalBorrowShares: subFloor(row.totalBorrowShares, args.shares),
    lastUpdated: args.lastUpdated,
  };
}

export function applySupplyToPosition(row: PositionTotals, args: { shares: bigint; lastUpdated: bigint }) {
  return {
    supplyShares: row.supplyShares + args.shares,
    lastUpdated: args.lastUpdated,
  };
}

export function applyWithdrawToPosition(row: PositionTotals, args: { shares: bigint; lastUpdated: bigint }) {
  return {
    supplyShares: subFloor(row.supplyShares, args.shares),
    lastUpdated: args.lastUpdated,
  };
}

export function applyBorrowToPosition(row: PositionTotals, args: { shares: bigint; lastUpdated: bigint }) {
  return {
    borrowShares: row.borrowShares + args.shares,
    lastUpdated: args.lastUpdated,
  };
}

export function applyRepayToPosition(row: PositionTotals, args: { shares: bigint; lastUpdated: bigint }) {
  return {
    borrowShares: subFloor(row.borrowShares, args.shares),
    lastUpdated: args.lastUpdated,
  };
}

export function applySupplyCollateralToPosition(row: PositionTotals, args: { assets: bigint; lastUpdated: bigint }) {
  return {
    collateral: row.collateral + args.assets,
    lastUpdated: args.lastUpdated,
  };
}

export function applyWithdrawCollateralToPosition(row: PositionTotals, args: { assets: bigint; lastUpdated: bigint }) {
  return {
    collateral: subFloor(row.collateral, args.assets),
    lastUpdated: args.lastUpdated,
  };
}

export function applyLiquidationToMarket(
  row: MarketTotals,
  args: {
    repaidAssets: bigint;
    repaidShares: bigint;
    badDebtAssets: bigint;
    badDebtShares: bigint;
    lastUpdated: bigint;
  }
) {
  return {
    totalSupplyAssets: subFloor(row.totalSupplyAssets, args.badDebtAssets),
    totalBorrowAssets: subFloor(row.totalBorrowAssets, args.repaidAssets + args.badDebtAssets),
    totalBorrowShares: subFloor(row.totalBorrowShares, args.repaidShares + args.badDebtShares),
    lastUpdated: args.lastUpdated,
  };
}

export function applyLiquidationToPosition(
  row: PositionTotals,
  args: {
    repaidShares: bigint;
    badDebtShares: bigint;
    seizedAssets: bigint;
    lastUpdated: bigint;
  }
) {
  return {
    borrowShares: subFloor(row.borrowShares, args.repaidShares + args.badDebtShares),
    collateral: subFloor(row.collateral, args.seizedAssets),
    lastUpdated: args.lastUpdated,
  };
}
