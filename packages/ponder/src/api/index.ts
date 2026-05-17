// SPDX-License-Identifier: AGPL-3.0-only
import { and, asc, eq, isNotNull, like, lt, sql } from "drizzle-orm";
import { Hono, type Context } from "hono";
import type { StatusCode } from "hono/utils/http-status";
import { client, graphql } from "ponder";
import { db } from "ponder:api";
import schema, { market, position } from "ponder:schema";

import { WAD, aggregateTvl, stringifyBalances, type LendingMarket } from "@fx-telarana/core";

const app = new Hono();

function replacer(_key: string, value: unknown) {
  return typeof value === "bigint" ? value.toString() : value;
}

function json(c: Context, value: unknown, status: StatusCode = 200) {
  return c.newResponse(JSON.stringify(value, replacer), status, {
    "content-type": "application/json; charset=utf-8",
  });
}

function parseLimit(value: string | undefined, fallback = 50, max = 250): number {
  const parsed = value ? Number(value) : fallback;
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.min(Math.trunc(parsed), max);
}

function marketKeyFromQuery(c: Context) {
  const hubChainId = c.req.query("hubChainId");
  const marketId = c.req.query("marketId")?.toLowerCase();
  return hubChainId && marketId ? `${hubChainId}:${marketId}` : undefined;
}

function toLendingMarket(row: typeof market.$inferSelect): LendingMarket {
  return {
    id: row.marketId,
    hubChainId: row.hubChainId as 43113 | 5042002,
    hubName: row.hubChainId === 5042002 ? "arc" : "fuji",
    loanToken: row.loanToken,
    collateralToken: row.collateralToken,
    oracle: row.oracle,
    irm: row.irm,
    lltv: row.lltv,
    isLive: row.isLive,
    state: {
      totalSupplyAssets: row.totalSupplyAssets,
      totalSupplyShares: row.totalSupplyShares,
      totalBorrowAssets: row.totalBorrowAssets,
      totalBorrowShares: row.totalBorrowShares,
      lastUpdate: row.lastUpdated ?? 0n,
      fee: 0n,
    },
  };
}

app.get("/health", (c) =>
  c.json({
    ok: true,
    service: "@fx-telarana/ponder",
    timestamp: new Date().toISOString(),
  })
);

app.use("/graphql", graphql({ db, schema }));
app.use("/sql/*", client({ db, schema }));

app.get("/fx-telarana/markets", async (c) => {
  const rows = await db.select().from(market).orderBy(asc(market.hubChainId), asc(market.marketId));
  return json(c, { markets: rows });
});

app.get("/fx-telarana/liquidations/candidates", async (c) => {
  const limit = parseLimit(c.req.query("limit"));
  const marketKey = marketKeyFromQuery(c);
  const predicates = [
    isNotNull(position.healthFactor),
    lt(position.healthFactor, WAD),
    ...(marketKey ? [eq(position.market, marketKey)] : []),
    ...(c.req.query("hubChainId") && !marketKey ? [like(position.market, `${c.req.query("hubChainId")}:%`)] : []),
  ];
  const rows = await db
    .select()
    .from(position)
    .where(and(...predicates))
    .orderBy(asc(position.healthFactor))
    .limit(limit);
  return json(c, {
    source: "ponder",
    candidates: rows.map((row, index) => ({
      ...row,
      rank: index + 1,
      liquidatable: row.healthFactor !== null && row.healthFactor < WAD,
    })),
  });
});

app.get("/fx-telarana/liquidations/density", async (c) => {
  const hubChainId = c.req.query("hubChainId");
  const predicates = [
    isNotNull(position.healthFactor),
    ...(hubChainId ? [like(position.market, `${hubChainId}:%`)] : []),
  ];
  const rows = await db
    .select({
      market: position.market,
      count: sql<number>`count(*)`,
      liquidatable: sql<number>`sum(case when ${position.healthFactor} < ${WAD} then 1 else 0 end)`,
      nearLiquidation: sql<number>`sum(case when ${position.healthFactor} >= ${WAD} and ${position.healthFactor} < ${WAD * 11n / 10n} then 1 else 0 end)`,
    })
    .from(position)
    .where(and(...predicates))
    .groupBy(position.market);
  return json(c, { source: "ponder", density: rows });
});

app.get("/fx-telarana/tvl/defillama", async (c) => {
  const rows = await db.select().from(market);
  const breakdown = aggregateTvl(rows.map(toLendingMarket));
  return json(c, {
    methodology:
      "Net TVL sums totalSupplyAssets minus totalBorrowAssets across FxMarketRegistry markets; borrowed reports totalBorrowAssets.",
    tvl: stringifyBalances(breakdown.netSupply),
    borrowed: stringifyBalances(breakdown.borrowed),
  });
});

export default app;
