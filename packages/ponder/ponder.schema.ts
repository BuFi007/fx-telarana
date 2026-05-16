// SPDX-License-Identifier: AGPL-3.0-only
import { index, onchainTable, relations } from "ponder";

export const market = onchainTable(
  "market",
  (t) => ({
    id: t.text().primaryKey(),
    marketId: t.hex().notNull(),
    hubChainId: t.integer().notNull(),
    loanToken: t.hex().notNull(),
    collateralToken: t.hex().notNull(),
    oracle: t.hex().notNull(),
    irm: t.hex().notNull(),
    lltv: t.bigint().notNull(),
    isLive: t.boolean().notNull().default(true),
    totalSupplyAssets: t.bigint().notNull().default(0n),
    totalSupplyShares: t.bigint().notNull().default(0n),
    totalBorrowAssets: t.bigint().notNull().default(0n),
    totalBorrowShares: t.bigint().notNull().default(0n),
    lastUpdated: t.bigint(),
  }),
  (t) => ({
    byHub: index().on(t.hubChainId),
    byPair: index().on(t.loanToken, t.collateralToken),
  })
);

export const position = onchainTable(
  "position",
  (t) => ({
    id: t.text().primaryKey(),
    market: t.text().notNull(),
    account: t.hex().notNull(),
    supplyShares: t.bigint().notNull().default(0n),
    borrowShares: t.bigint().notNull().default(0n),
    collateral: t.bigint().notNull().default(0n),
    healthFactor: t.bigint(),
    lastUpdated: t.bigint().notNull(),
  }),
  (t) => ({
    byMarket: index().on(t.market),
    byAccount: index().on(t.account),
  })
);

export const lendingEvent = onchainTable(
  "lending_event",
  (t) => ({
    id: t.text().primaryKey(),
    type: t.text().notNull(),
    market: t.text().notNull(),
    account: t.hex(),
    assets: t.bigint(),
    shares: t.bigint(),
    txHash: t.hex().notNull(),
    block: t.bigint().notNull(),
    ts: t.bigint().notNull(),
  }),
  (t) => ({
    byMarket: index().on(t.market),
    byAccount: index().on(t.account),
    byType: index().on(t.type),
  })
);

export const oracleSnapshot = onchainTable(
  "oracle_snapshot",
  (t) => ({
    id: t.text().primaryKey(),
    market: t.text().notNull(),
    midE18: t.bigint().notNull(),
    ts: t.bigint().notNull(),
    pythSequence: t.text(),
    redstoneSig: t.text(),
  }),
  (t) => ({
    byMarket: index().on(t.market),
  })
);

export const marketRelations = relations(market, ({ many }) => ({
  positions: many(position),
  events: many(lendingEvent),
  oracleSnapshots: many(oracleSnapshot),
}));

export const positionRelations = relations(position, ({ one }) => ({
  marketRef: one(market, { fields: [position.market], references: [market.id] }),
}));

export const lendingEventRelations = relations(lendingEvent, ({ one }) => ({
  marketRef: one(market, { fields: [lendingEvent.market], references: [market.id] }),
}));
