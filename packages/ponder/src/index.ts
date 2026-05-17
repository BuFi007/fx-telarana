// SPDX-License-Identifier: AGPL-3.0-only
import { ponder } from "ponder:registry";
import { lendingEvent, market, position } from "ponder:schema";

import { FxOracleAbi, telarana } from "@fx-telarana/contracts";
import { WAD, calculateHealthFactorE18, toAssetsUp } from "@fx-telarana/core";

import {
  ZERO_ADDRESS,
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
  positionRowId,
} from "./lending-state.js";

const hubs = telarana.hubs();

function chainIdFromContext(context: { chain: { id: number } }): number {
  return context.chain.id;
}

function marketRowId(chainId: number, marketId: `0x${string}`) {
  return `${chainId}:${marketId.toLowerCase()}`;
}

function eventId(event: { transaction: { hash: `0x${string}` }; log: { logIndex: number } }) {
  return `${event.transaction.hash}-${event.log.logIndex}`;
}

type LendingEventArgs = {
  id: string;
  type: string;
  market: string;
  account?: `0x${string}`;
  assets?: bigint;
  shares?: bigint;
  txHash: `0x${string}`;
  block: bigint;
  ts: bigint;
};

async function insertLendingEvent(context: { db: any }, args: LendingEventArgs) {
  await context.db.insert(lendingEvent).values(args);
}

function oracleForChainId(chainId: number): `0x${string}` {
  if (chainId === hubs.fuji.chainId) return hubs.fuji.oracle;
  if (chainId === hubs.arc.chainId) return hubs.arc.oracle;
  return ZERO_ADDRESS;
}

async function refreshPositionHealthFactor(
  context: { chain: { id: number }; client: any; db: any },
  marketKey: string,
  account: `0x${string}`,
  lastUpdated: bigint
) {
  const id = positionRowId(marketKey, account);
  const [marketRow, positionRow] = await Promise.all([
    context.db.find(market, { id: marketKey }),
    context.db.find(position, { id }),
  ]);

  if (!marketRow || !positionRow || positionRow.borrowShares === 0n || marketRow.totalBorrowShares === 0n) {
    if (positionRow) {
      await context.db.update(position, { id }).set({ healthFactor: null, lastUpdated });
    }
    return;
  }

  try {
    const [midE18] = await context.client.readContract({
      address: oracleForChainId(context.chain.id),
      abi: FxOracleAbi,
      functionName: "getMid",
      args: [marketRow.collateralToken, marketRow.loanToken],
    });
    const borrowAssets = toAssetsUp(
      positionRow.borrowShares,
      marketRow.totalBorrowAssets,
      marketRow.totalBorrowShares
    );
    const healthFactor = calculateHealthFactorE18({
      collateralAssets: positionRow.collateral,
      collateralPriceE36: midE18 * WAD,
      borrowAssetsE18: borrowAssets,
      lltv: marketRow.lltv,
    });
    await context.db.update(position, { id }).set({ healthFactor, lastUpdated });
  } catch {
    await context.db.update(position, { id }).set({ healthFactor: null, lastUpdated });
  }
}

ponder.on("FxMarketRegistry:MarketRegistered", async ({ event, context }) => {
  const chainId = chainIdFromContext(context);
  const id = marketRowId(chainId, event.args.marketId);
  await context.db
    .insert(market)
    .values({
      id,
      marketId: event.args.marketId,
      hubChainId: chainId,
      loanToken: event.args.loanToken,
      collateralToken: event.args.collateralToken,
      oracle: ZERO_ADDRESS,
      irm: event.args.irm,
      lltv: event.args.lltv,
      isLive: true,
      lastUpdated: event.block.timestamp,
    })
    .onConflictDoUpdate((row) => ({
      irm: event.args.irm,
      lltv: event.args.lltv,
      isLive: row.isLive,
      lastUpdated: event.block.timestamp,
    }));
});

ponder.on("FxMarketRegistry:PoolLiveSet", async ({ event, context }) => {
  const id = marketRowId(chainIdFromContext(context), event.args.marketId);
  await context.db.update(market, { id }).set({
    isLive: event.args.isLive,
    lastUpdated: event.block.timestamp,
  });
});

ponder.on("FxMarketRegistry:BorrowDelegateSet", async ({ event, context }) => {
  await insertLendingEvent(context, {
    id: eventId(event),
    type: "BorrowDelegateSet",
    market: `${chainIdFromContext(context)}:delegate`,
    account: event.args.account,
    txHash: event.transaction.hash,
    block: event.block.number,
    ts: event.block.timestamp,
  });
});

ponder.on("MorphoBlue:Supply", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await insertLendingEvent(context, {
    id: eventId(event),
    type: "Supply",
    market: marketKey,
    account: event.args.onBehalf,
    assets: event.args.assets,
    shares: event.args.shares,
    txHash: event.transaction.hash,
    block: event.block.number,
    ts: event.block.timestamp,
  });
  await context.db.update(market, { id: marketKey }).set((row) =>
    applySupplyToMarket(row, { ...event.args, lastUpdated: event.block.timestamp })
  );
  await context.db
    .insert(position)
    .values({
      id: positionRowId(marketKey, event.args.onBehalf),
      market: marketKey,
      account: event.args.onBehalf,
      supplyShares: event.args.shares,
      lastUpdated: event.block.timestamp,
    })
    .onConflictDoUpdate((row) => ({
      ...applySupplyToPosition(row, { shares: event.args.shares, lastUpdated: event.block.timestamp }),
    }));
});

ponder.on("MorphoBlue:Withdraw", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await insertLendingEvent(context, {
    id: eventId(event),
    type: "Withdraw",
    market: marketKey,
    account: event.args.onBehalf,
    assets: event.args.assets,
    shares: event.args.shares,
    txHash: event.transaction.hash,
    block: event.block.number,
    ts: event.block.timestamp,
  });
  await context.db.update(market, { id: marketKey }).set((row) =>
    applyWithdrawToMarket(row, { ...event.args, lastUpdated: event.block.timestamp })
  );
  await context.db.update(position, { id: positionRowId(marketKey, event.args.onBehalf) }).set((row) =>
    applyWithdrawToPosition(row, { shares: event.args.shares, lastUpdated: event.block.timestamp })
  );
});

ponder.on("MorphoBlue:Borrow", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await insertLendingEvent(context, {
    id: eventId(event),
    type: "Borrow",
    market: marketKey,
    account: event.args.onBehalf,
    assets: event.args.assets,
    shares: event.args.shares,
    txHash: event.transaction.hash,
    block: event.block.number,
    ts: event.block.timestamp,
  });
  await context.db.update(market, { id: marketKey }).set((row) =>
    applyBorrowToMarket(row, { ...event.args, lastUpdated: event.block.timestamp })
  );
  await context.db
    .insert(position)
    .values({
      id: positionRowId(marketKey, event.args.onBehalf),
      market: marketKey,
      account: event.args.onBehalf,
      borrowShares: event.args.shares,
      lastUpdated: event.block.timestamp,
    })
    .onConflictDoUpdate((row) => ({
      ...applyBorrowToPosition(row, { shares: event.args.shares, lastUpdated: event.block.timestamp }),
    }));
  await refreshPositionHealthFactor(context, marketKey, event.args.onBehalf, event.block.timestamp);
});

ponder.on("MorphoBlue:Repay", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await insertLendingEvent(context, {
    id: eventId(event),
    type: "Repay",
    market: marketKey,
    account: event.args.onBehalf,
    assets: event.args.assets,
    shares: event.args.shares,
    txHash: event.transaction.hash,
    block: event.block.number,
    ts: event.block.timestamp,
  });
  await context.db.update(market, { id: marketKey }).set((row) =>
    applyRepayToMarket(row, { ...event.args, lastUpdated: event.block.timestamp })
  );
  await context.db.update(position, { id: positionRowId(marketKey, event.args.onBehalf) }).set((row) =>
    applyRepayToPosition(row, { shares: event.args.shares, lastUpdated: event.block.timestamp })
  );
  await refreshPositionHealthFactor(context, marketKey, event.args.onBehalf, event.block.timestamp);
});

ponder.on("MorphoBlue:SupplyCollateral", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await insertLendingEvent(context, {
    id: eventId(event),
    type: "SupplyCollateral",
    market: marketKey,
    account: event.args.onBehalf,
    assets: event.args.assets,
    txHash: event.transaction.hash,
    block: event.block.number,
    ts: event.block.timestamp,
  });
  await context.db
    .insert(position)
    .values({
      id: positionRowId(marketKey, event.args.onBehalf),
      market: marketKey,
      account: event.args.onBehalf,
      collateral: event.args.assets,
      lastUpdated: event.block.timestamp,
    })
    .onConflictDoUpdate((row) => ({
      ...applySupplyCollateralToPosition(row, { assets: event.args.assets, lastUpdated: event.block.timestamp }),
    }));
  await refreshPositionHealthFactor(context, marketKey, event.args.onBehalf, event.block.timestamp);
});

ponder.on("MorphoBlue:WithdrawCollateral", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await insertLendingEvent(context, {
    id: eventId(event),
    type: "WithdrawCollateral",
    market: marketKey,
    account: event.args.onBehalf,
    assets: event.args.assets,
    txHash: event.transaction.hash,
    block: event.block.number,
    ts: event.block.timestamp,
  });
  await context.db.update(position, { id: positionRowId(marketKey, event.args.onBehalf) }).set((row) =>
    applyWithdrawCollateralToPosition(row, { assets: event.args.assets, lastUpdated: event.block.timestamp })
  );
  await refreshPositionHealthFactor(context, marketKey, event.args.onBehalf, event.block.timestamp);
});

ponder.on("MorphoBlue:Liquidate", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await insertLendingEvent(context, {
    id: eventId(event),
    type: "Liquidate",
    market: marketKey,
    account: event.args.borrower,
    assets: event.args.repaidAssets,
    shares: event.args.repaidShares,
    txHash: event.transaction.hash,
    block: event.block.number,
    ts: event.block.timestamp,
  });
  await context.db.update(market, { id: marketKey }).set((row) =>
    applyLiquidationToMarket(row, { ...event.args, lastUpdated: event.block.timestamp })
  );
  await context.db.update(position, { id: positionRowId(marketKey, event.args.borrower) }).set((row) =>
    applyLiquidationToPosition(row, { ...event.args, lastUpdated: event.block.timestamp })
  );
  await refreshPositionHealthFactor(context, marketKey, event.args.borrower, event.block.timestamp);
});
