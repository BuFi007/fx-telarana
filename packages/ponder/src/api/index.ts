// SPDX-License-Identifier: AGPL-3.0-only
import { and, asc, eq, gte, isNotNull, like, lt, sql } from "drizzle-orm";
import { Hono, type Context } from "hono";
import type { StatusCode } from "hono/utils/http-status";
import { client, graphql } from "ponder";
import { db } from "ponder:api";
import schema, { lendingEvent, market, position } from "ponder:schema";

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

function rangeSeconds(range: string): number {
  const match = range.match(/^(\d+)([dhw])$/);
  if (!match) return 30 * 24 * 60 * 60;
  const value = Number(match[1]);
  const unit = match[2];
  if (!Number.isFinite(value) || value <= 0) return 30 * 24 * 60 * 60;
  if (unit === "d") return value * 24 * 60 * 60;
  if (unit === "h") return value * 60 * 60;
  return value * 7 * 24 * 60 * 60;
}

function utilizationE18(row: typeof market.$inferSelect): bigint {
  if (row.totalSupplyAssets === 0n) return 0n;
  return (row.totalBorrowAssets * WAD) / row.totalSupplyAssets;
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

app.get("/fx-telarana/markets/:hubChainId/:marketId/historical-apy", async (c) => {
  const hubChainId = Number(c.req.param("hubChainId"));
  const marketId = c.req.param("marketId").toLowerCase();
  const key = `${hubChainId}:${marketId}`;
  const range = c.req.query("range") ?? "30d";
  const cutoff = BigInt(Math.floor(Date.now() / 1000) - rangeSeconds(range));
  const row = await db.select().from(market).where(eq(market.id, key)).limit(1).then((rows) => rows[0]);
  if (!row) return json(c, { error: "market_not_found" }, 404);
  const events = await db
    .select()
    .from(lendingEvent)
    .where(and(eq(lendingEvent.market, key), gte(lendingEvent.ts, cutoff)))
    .orderBy(asc(lendingEvent.ts))
    .limit(500);
  const utilization = utilizationE18(row);
  return json(c, {
    source: "ponder",
    hubChainId,
    marketId,
    range,
    rateModel: "indexed_utilization_pending_irm_adapter",
    apyUnavailableReason: "IRM borrowRateView adapter is not wired yet; points include indexed utilization and totals.",
    points: [
      {
        ts: row.lastUpdated ?? 0n,
        eventType: "CurrentState",
        utilizationE18: utilization,
        supplyApyE18: null,
        borrowApyE18: null,
        totalSupplyAssets: row.totalSupplyAssets,
        totalBorrowAssets: row.totalBorrowAssets,
      },
      ...events.map((event) => ({
        ts: event.ts,
        eventType: event.type,
        utilizationE18: utilization,
        supplyApyE18: null,
        borrowApyE18: null,
        totalSupplyAssets: row.totalSupplyAssets,
        totalBorrowAssets: row.totalBorrowAssets,
      })),
    ],
  });
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
