// SPDX-License-Identifier: AGPL-3.0-only
import { ponder } from "ponder:registry";
import { lendingEvent, market, position } from "ponder:schema";

function chainIdFromContext(context: { chain: { id: number } }): number {
  return context.chain.id;
}

function marketRowId(chainId: number, marketId: `0x${string}`) {
  return `${chainId}:${marketId.toLowerCase()}`;
}

function eventId(event: { transaction: { hash: `0x${string}` }; log: { logIndex: number } }) {
  return `${event.transaction.hash}-${event.log.logIndex}`;
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
      oracle: "0x0000000000000000000000000000000000000000",
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
  await context.db.insert(lendingEvent).values({
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
  await context.db.insert(lendingEvent).values({
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
  await context.db
    .insert(position)
    .values({
      id: `${marketKey}:${event.args.onBehalf.toLowerCase()}`,
      market: marketKey,
      account: event.args.onBehalf,
      supplyShares: event.args.shares,
      lastUpdated: event.block.timestamp,
    })
    .onConflictDoUpdate((row) => ({
      supplyShares: row.supplyShares + event.args.shares,
      lastUpdated: event.block.timestamp,
    }));
});

ponder.on("MorphoBlue:Withdraw", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await context.db.insert(lendingEvent).values({
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
});

ponder.on("MorphoBlue:Borrow", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await context.db.insert(lendingEvent).values({
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
});

ponder.on("MorphoBlue:Repay", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await context.db.insert(lendingEvent).values({
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
});

ponder.on("MorphoBlue:SupplyCollateral", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await context.db.insert(lendingEvent).values({
    id: eventId(event),
    type: "SupplyCollateral",
    market: marketKey,
    account: event.args.onBehalf,
    assets: event.args.assets,
    txHash: event.transaction.hash,
    block: event.block.number,
    ts: event.block.timestamp,
  });
});

ponder.on("MorphoBlue:WithdrawCollateral", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await context.db.insert(lendingEvent).values({
    id: eventId(event),
    type: "WithdrawCollateral",
    market: marketKey,
    account: event.args.onBehalf,
    assets: event.args.assets,
    txHash: event.transaction.hash,
    block: event.block.number,
    ts: event.block.timestamp,
  });
});

ponder.on("MorphoBlue:Liquidate", async ({ event, context }) => {
  const marketKey = marketRowId(chainIdFromContext(context), event.args.id);
  await context.db.insert(lendingEvent).values({
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
});
