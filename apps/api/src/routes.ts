// SPDX-License-Identifier: AGPL-3.0-only
import { createLogger } from "@bufinance/logger";
import { Hono, type Context } from "hono";
import { z } from "zod";

import {
  aggregateTvl,
  borrowIntentSchema,
  buildBorrowIntent,
  buildRepayIntent,
  buildSupplyCollateralIntent,
  buildSupplyIntent,
  buildWithdrawCollateralIntent,
  buildWithdrawIntent,
  collateralIntentSchema,
  getMarketById,
  liquidationCandidatesQuerySchema,
  listMarkets,
  marketRefSchema,
  quoteBorrow,
  quoteBorrowSchema,
  quoteRepay,
  quoteRepaySchema,
  quoteSupply,
  quoteSupplySchema,
  quoteWithdraw,
  quoteWithdrawSchema,
  repayIntentSchema,
  stringifyBalances,
  supplyIntentSchema,
  withdrawIntentSchema,
} from "@fx-telarana/core";
import { buildInternalDefiLlamaPayload } from "@fx-telarana/defillama";
import { issueLendingSession } from "@fx-telarana/liveblocks/server";
import { createMcpApp } from "@fx-telarana/mcp/hono";
import { requireX402Payment } from "@fx-telarana/x402";

import { getIntent, storeIntent } from "./intent-store.js";
import { json } from "./json.js";

const log = createLogger({ prefix: "fx-telarana:api" });

async function parseJson<TSchema extends z.ZodTypeAny>(schema: TSchema, c: Context): Promise<z.output<TSchema>> {
  const body = await c.req.json().catch(() => ({}));
  return schema.parse(body);
}

export function createRoutes() {
  const app = new Hono();

  app.get("/health", (c) =>
    c.json({
      ok: true,
      service: "@fx-telarana/api",
      timestamp: new Date().toISOString(),
    })
  );

  app.post("/liveblocks/auth", async (c) => {
    const body = await parseJson(
      z.object({
        userId: z.string().min(1),
        displayName: z.string().min(1),
        walletAddress: z.string().optional(),
        roomIds: z.array(z.string()).min(1),
      }),
      c
    );
    return json(
      c,
      await issueLendingSession({
        userId: body.userId,
        displayName: body.displayName,
        roomIds: body.roomIds,
        ...(body.walletAddress ? { walletAddress: body.walletAddress } : {}),
      })
    );
  });

  app.route("/", createMcpApp());

  app.get("/fx-telarana/markets", async (c) => json(c, { markets: await listMarkets() }));

  app.get("/fx-telarana/markets/:hubChainId/:marketId", async (c) => {
    const ref = marketRefSchema.parse({
      hubChainId: Number(c.req.param("hubChainId")),
      marketId: c.req.param("marketId"),
    });
    const market = await getMarketById(ref);
    if (!market) return c.json({ error: "market_not_found" }, 404);
    return json(c, { market });
  });

  app.get("/fx-telarana/markets/:hubChainId/:marketId/state", async (c) => {
    const ref = marketRefSchema.parse({
      hubChainId: Number(c.req.param("hubChainId")),
      marketId: c.req.param("marketId"),
    });
    const market = await getMarketById(ref);
    if (!market) return c.json({ error: "market_not_found" }, 404);
    return json(c, { state: market.state ?? null });
  });

  app.get("/fx-telarana/markets/:hubChainId/:marketId/apy", async (c) => {
    const ref = marketRefSchema.parse({
      hubChainId: Number(c.req.param("hubChainId")),
      marketId: c.req.param("marketId"),
    });
    return json(c, {
      ...ref,
      source: "irm_live_read_pending",
      supplyApy: null,
      borrowApy: null,
    });
  });

  app.get(
    "/fx-telarana/markets/:hubChainId/:marketId/historical-apy",
    requireX402Payment({ endpoint: "historical_apy" }),
    async (c) =>
      json(c, {
        hubChainId: Number(c.req.param("hubChainId")),
        marketId: c.req.param("marketId"),
        range: c.req.query("range") ?? "30d",
        points: [],
      })
  );

  app.get("/fx-telarana/markets/:hubChainId/:marketId/oracle", async (c) =>
    json(c, {
      hubChainId: Number(c.req.param("hubChainId")),
      marketId: c.req.param("marketId"),
      oracleSurface: "FxOracle.getMid",
      directProviderHttp: false,
    })
  );

  app.get("/fx-telarana/positions/:address", (c) =>
    json(c, {
      address: c.req.param("address"),
      source: "ponder_pending",
      positions: [],
    })
  );

  app.get("/fx-telarana/positions/:address/:marketId", (c) =>
    json(c, {
      address: c.req.param("address"),
      marketId: c.req.param("marketId"),
      source: "ponder_pending",
      position: null,
    })
  );

  app.post("/fx-telarana/supply/quote", async (c) => {
    const body = await parseJson(quoteSupplySchema, c);
    return json(c, quoteSupply({ assets: body.assets, totalSupplyAssets: 0n, totalSupplyShares: 0n }));
  });

  app.post("/fx-telarana/borrow/quote", async (c) => {
    const body = await parseJson(quoteBorrowSchema, c);
    const market =
      (await listMarkets()).find(
        (candidate) =>
          candidate.hubChainId === body.hubChainId &&
          candidate.loanToken.toLowerCase() === body.loanToken.toLowerCase() &&
          candidate.collateralToken.toLowerCase() === body.collateralToken.toLowerCase()
      ) ?? null;
    if (!market) return c.json({ error: "market_not_found" }, 404);
    return json(
      c,
      quoteBorrow({
        market,
        collateral: body.collateral,
        borrowAmount: body.borrowAmount,
        collateralPriceE36: 10n ** 36n,
      })
    );
  });

  app.post(
    "/fx-telarana/quote/borrow-with-sim",
    requireX402Payment({ endpoint: "borrow_with_sim" }),
    async (c) => {
      const body = await parseJson(quoteBorrowSchema.extend({ simulateTenderly: z.boolean().default(true) }), c);
      log.info(JSON.stringify({ route: "borrow-with-sim", simulateTenderly: body.simulateTenderly }));
      return json(c, {
        quote: { requested: body.borrowAmount },
        simulation: { status: "pending_provider_wiring" },
      });
    }
  );

  app.post("/fx-telarana/repay/quote", async (c) => {
    const body = await parseJson(quoteRepaySchema, c);
    return json(c, quoteRepay({ assets: body.assets, totalBorrowAssets: 0n, totalBorrowShares: 0n }));
  });

  app.post("/fx-telarana/withdraw/quote", async (c) => {
    const body = await parseJson(quoteWithdrawSchema, c);
    return json(c, quoteWithdraw({ shares: body.shares, totalSupplyAssets: 0n, totalSupplyShares: 0n }));
  });

  app.post("/fx-telarana/supply/intents", async (c) => {
    const body = await parseJson(supplyIntentSchema, c);
    return json(c, storeIntent("supply", buildSupplyIntent({ chainId: body.hubChainId, ...body })), 201);
  });

  app.get("/fx-telarana/supply/intents/:id", (c) => {
    const intent = getIntent(c.req.param("id"));
    return intent ? json(c, intent) : c.json({ error: "intent_not_found" }, 404);
  });

  app.post("/fx-telarana/borrow/intents", async (c) => {
    const body = await parseJson(borrowIntentSchema, c);
    return json(c, storeIntent("borrow", buildBorrowIntent({ chainId: body.hubChainId, ...body })), 201);
  });

  app.get("/fx-telarana/borrow/intents/:id", (c) => {
    const intent = getIntent(c.req.param("id"));
    return intent ? json(c, intent) : c.json({ error: "intent_not_found" }, 404);
  });

  app.post("/fx-telarana/repay/intents", async (c) => {
    const body = await parseJson(repayIntentSchema, c);
    return json(c, storeIntent("repay", buildRepayIntent({ chainId: body.hubChainId, ...body })), 201);
  });

  app.post("/fx-telarana/withdraw/intents", async (c) => {
    const body = await parseJson(withdrawIntentSchema, c);
    return json(c, storeIntent("withdraw", buildWithdrawIntent({ chainId: body.hubChainId, ...body })), 201);
  });

  app.post("/fx-telarana/collateral/supply/intents", async (c) => {
    const body = await parseJson(collateralIntentSchema, c);
    return json(
      c,
      storeIntent("supplyCollateral", buildSupplyCollateralIntent({ chainId: body.hubChainId, ...body })),
      201
    );
  });

  app.post("/fx-telarana/collateral/withdraw/intents", async (c) => {
    const body = await parseJson(collateralIntentSchema, c);
    return json(
      c,
      storeIntent("withdrawCollateral", buildWithdrawCollateralIntent({ chainId: body.hubChainId, ...body })),
      201
    );
  });

  app.get("/fx-telarana/liquidations/candidates", (c) => {
    const query = liquidationCandidatesQuerySchema.parse({
      hubChainId: c.req.query("hubChainId") ? Number(c.req.query("hubChainId")) : undefined,
      marketId: c.req.query("marketId"),
      limit: c.req.query("limit"),
      cursor: c.req.query("cursor"),
    });
    return json(c, { ...query, source: "ponder_pending", candidates: [] });
  });

  app.get(
    "/fx-telarana/liquidations/density",
    requireX402Payment({ endpoint: "liquidation_density" }),
    (c) => json(c, { density: [], source: "ponder_pending" })
  );

  app.get("/fx-telarana/tvl", async (c) => {
    const breakdown = aggregateTvl(await listMarkets());
    return json(c, {
      tvl: stringifyBalances(breakdown.netSupply),
      borrowed: stringifyBalances(breakdown.borrowed),
    });
  });

  app.get("/fx-telarana/tvl/by-market", async (c) =>
    json(c, { markets: (await listMarkets()).map((market) => ({ marketId: market.id, state: market.state ?? null })) })
  );

  app.get("/fx-telarana/tvl/by-hub", async (c) => {
    const markets = await listMarkets();
    return json(c, {
      hubs: Object.fromEntries(
        [43113, 5042002].map((hubChainId) => {
          const breakdown = aggregateTvl(markets.filter((market) => market.hubChainId === hubChainId));
          return [hubChainId, { tvl: stringifyBalances(breakdown.netSupply), borrowed: stringifyBalances(breakdown.borrowed) }];
        })
      ),
    });
  });

  app.get("/fx-telarana/tvl/defillama", async (c) =>
    json(c, buildInternalDefiLlamaPayload(await listMarkets()))
  );

  return app;
}
