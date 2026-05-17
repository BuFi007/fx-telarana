// SPDX-License-Identifier: AGPL-3.0-only
import { createLogger } from "@bufinance/logger";
import { Hono, type Context } from "hono";
import { z } from "zod";

import {
  aggregateTvl,
  addressSchema,
  borrowIntentSchema,
  buildBorrowIntent,
  buildRepayIntent,
  buildSupplyCollateralIntent,
  buildSupplyIntent,
  buildWithdrawCollateralIntent,
  buildWithdrawIntent,
  collateralIntentSchema,
  ensureMarketState,
  getAccountPosition,
  getMarketById,
  getMarketByPair,
  hubChainIdSchema,
  hexSchema,
  liquidationCandidatesQuerySchema,
  listAccountPositions,
  listMarkets,
  marketIdSchema,
  marketRefSchema,
  quoteBorrow,
  quoteBorrowSchema,
  quoteRepay,
  quoteRepaySchema,
  quoteSupply,
  quoteSupplySchema,
  quoteWithdraw,
  quoteWithdrawSchema,
  readMarketOracleQuote,
  repayIntentSchema,
  stringifyBalances,
  supplyIntentSchema,
  WAD,
  withdrawIntentSchema,
} from "@fx-telarana/core";
import { buildInternalDefiLlamaPayload } from "@fx-telarana/defillama";
import { issueLendingSession } from "@fx-telarana/liveblocks/server";
import { createMcpApp } from "@fx-telarana/mcp/hono";
import { requireX402Payment, verifyX402Request } from "@fx-telarana/x402";

import { getIntent, getNextIntentNonce, storeIntent, verifyStoredIntent } from "./intent-store.js";
import { json } from "./json.js";

const log = createLogger({ prefix: "fx-telarana:api" });

async function parseJson<TSchema extends z.ZodTypeAny>(schema: TSchema, c: Context): Promise<z.output<TSchema>> {
  const body = await c.req.json().catch(() => ({}));
  return schema.parse(body);
}

const signatureSchema = hexSchema.refine(
  (value) => /^0x[0-9a-fA-F]{130}$/.test(value),
  "Expected a 65-byte ECDSA signature"
);

const intentSignatureSchema = z.object({
  signer: addressSchema,
  signature: signatureSchema,
});

const intentActionSchema = z.enum([
  "Supply",
  "Borrow",
  "Repay",
  "Withdraw",
  "SupplyCollateral",
  "WithdrawCollateral",
]);

function ponderApiUrl(): string | null {
  return process.env.PONDER_API_URL ?? process.env.PONDER_BASE_URL ?? null;
}

async function fetchPonderJson(path: string): Promise<unknown | null> {
  const base = ponderApiUrl();
  if (!base) return null;
  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(),
    Number(process.env.PONDER_API_TIMEOUT_MS ?? 3_000)
  );
  try {
    const response = await fetch(new URL(path, base), { signal: controller.signal });
    if (!response.ok) {
      log.warn(
        JSON.stringify({
          msg: "ponder api request failed",
          path,
          status: response.status,
        })
      );
      return null;
    }
    return response.json();
  } catch (error) {
    log.warn(
      JSON.stringify({
        msg: "ponder api request failed",
        path,
        error: error instanceof Error ? error.message : String(error),
      })
    );
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

async function buildBorrowQuotePayload(body: z.output<typeof quoteBorrowSchema>) {
  const market = await getMarketByPair(body);
  if (!market) return null;
  const [state, oracle, existingPosition] = await Promise.all([
    ensureMarketState({ market }),
    readMarketOracleQuote({ market }),
    body.account
      ? getAccountPosition({
          account: body.account,
          hubChainId: market.hubChainId,
          marketId: market.id,
        })
      : Promise.resolve(null),
  ]);
  const quote = quoteBorrow({
    market: { ...market, state },
    collateral: (existingPosition?.collateral ?? 0n) + body.collateral,
    borrowAmount: body.borrowAmount,
    ...(existingPosition ? { existingBorrowShares: existingPosition.borrowShares } : {}),
    totalBorrowAssets: state.totalBorrowAssets,
    totalBorrowShares: state.totalBorrowShares,
    collateralPriceE36: oracle.midE18 * WAD,
  });
  return {
    ...quote,
    collateralInput: body.collateral,
    existingPosition,
    oracle,
  };
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
    async (c) => {
      const range = c.req.query("range") ?? "30d";
      const hubChainId = Number(c.req.param("hubChainId"));
      const marketId = c.req.param("marketId");
      const indexed = await fetchPonderJson(
        `/fx-telarana/markets/${hubChainId}/${marketId}/historical-apy?range=${encodeURIComponent(range)}`
      );
      return json(
        c,
        indexed ?? {
          source: "ponder_unconfigured",
          hubChainId,
          marketId,
          range,
          points: [],
        }
      );
    }
  );

  app.get("/fx-telarana/markets/:hubChainId/:marketId/oracle", async (c) => {
    const ref = marketRefSchema.parse({
      hubChainId: Number(c.req.param("hubChainId")),
      marketId: c.req.param("marketId"),
    });
    const market = await getMarketById(ref);
    if (!market) return c.json({ error: "market_not_found" }, 404);
    const oracle = await readMarketOracleQuote({ market });
    return json(c, {
      ...ref,
      loanToken: market.loanToken,
      collateralToken: market.collateralToken,
      oracleSurface: "FxOracle.getMid",
      directProviderHttp: false,
      midE18: oracle.midE18,
      publishedAt: oracle.publishedAt,
    });
  });

  app.get("/fx-telarana/positions/:address", async (c) => {
    const account = addressSchema.parse(c.req.param("address"));
    const hubChainId = c.req.query("hubChainId")
      ? hubChainIdSchema.parse(Number(c.req.query("hubChainId")))
      : undefined;
    const positions = await listAccountPositions({
      account,
      ...(hubChainId ? { hubChainId } : {}),
    });
    return json(c, {
      address: account,
      source: "onchain_morpho_fx_oracle",
      positions,
    });
  });

  app.get("/fx-telarana/positions/:address/:marketId", async (c) => {
    const account = addressSchema.parse(c.req.param("address"));
    const marketId = marketIdSchema.parse(c.req.param("marketId"));
    const hubChainId = c.req.query("hubChainId")
      ? hubChainIdSchema.parse(Number(c.req.query("hubChainId")))
      : undefined;
    const positions = await listAccountPositions({
      account,
      marketId,
      includeEmpty: true,
      ...(hubChainId ? { hubChainId } : {}),
    });
    const position = positions[0] ?? null;
    if (!position) return c.json({ error: "position_market_not_found" }, 404);
    return json(c, {
      address: account,
      marketId,
      source: "onchain_morpho_fx_oracle",
      position,
    });
  });

  app.post("/fx-telarana/supply/quote", async (c) => {
    const body = await parseJson(quoteSupplySchema, c);
    const market = await getMarketByPair(body);
    if (!market) return c.json({ error: "market_not_found" }, 404);
    const state = await ensureMarketState({ market });
    return json(c, {
      marketId: market.id,
      ...quoteSupply({
        assets: body.assets,
        totalSupplyAssets: state.totalSupplyAssets,
        totalSupplyShares: state.totalSupplyShares,
      }),
    });
  });

  app.post("/fx-telarana/borrow/quote", async (c) => {
    const body = await parseJson(quoteBorrowSchema, c);
    const payload = await buildBorrowQuotePayload(body);
    if (!payload) return c.json({ error: "market_not_found" }, 404);
    return json(c, payload);
  });

  app.post("/fx-telarana/quote/borrow-with-sim", async (c) => {
    const body = await parseJson(quoteBorrowSchema.extend({ simulateTenderly: z.boolean().default(true) }), c);
    log.info(JSON.stringify({ route: "borrow-with-sim", simulateTenderly: body.simulateTenderly }));
    const payload = await buildBorrowQuotePayload(body);
    if (!payload) return c.json({ error: "market_not_found" }, 404);
    const payment = body.simulateTenderly ? await verifyX402Request(c, { endpoint: "borrow_with_sim" }) : null;
    if (payment && !payment.ok) return payment.response;
    return json(c, {
      quote: payload,
      simulation: body.simulateTenderly
        ? {
            status: "provider_unconfigured",
            provider: "tenderly",
            paid: true,
            payer: payment?.receipt.payer,
            settlementRef: payment?.receipt.settlementRef,
          }
        : { status: "skipped", paid: false },
    });
  });

  app.post("/fx-telarana/repay/quote", async (c) => {
    const body = await parseJson(quoteRepaySchema, c);
    const market = await getMarketByPair(body);
    if (!market) return c.json({ error: "market_not_found" }, 404);
    const state = await ensureMarketState({ market });
    return json(c, {
      marketId: market.id,
      ...quoteRepay({
        assets: body.assets,
        totalBorrowAssets: state.totalBorrowAssets,
        totalBorrowShares: state.totalBorrowShares,
      }),
    });
  });

  app.post("/fx-telarana/withdraw/quote", async (c) => {
    const body = await parseJson(quoteWithdrawSchema, c);
    const market = await getMarketByPair(body);
    if (!market) return c.json({ error: "market_not_found" }, 404);
    const state = await ensureMarketState({ market });
    return json(c, {
      marketId: market.id,
      ...quoteWithdraw({
        shares: body.shares,
        totalSupplyAssets: state.totalSupplyAssets,
        totalSupplyShares: state.totalSupplyShares,
      }),
    });
  });

  app.get("/fx-telarana/intents/nonce/:hubChainId/:action/:address", (c) => {
    const chainId = hubChainIdSchema.parse(Number(c.req.param("hubChainId")));
    const action = intentActionSchema.parse(c.req.param("action"));
    const account = addressSchema.parse(c.req.param("address"));
    return json(c, {
      hubChainId: chainId,
      action,
      account,
      nextNonce: getNextIntentNonce({ chainId, action, account }),
    });
  });

  app.post("/fx-telarana/supply/intents", async (c) => {
    const body = await parseJson(supplyIntentSchema, c);
    return json(c, storeIntent("Supply", buildSupplyIntent({ chainId: body.hubChainId, ...body })), 201);
  });

  app.get("/fx-telarana/supply/intents/:id", (c) => {
    const intent = getIntent(c.req.param("id"));
    return intent ? json(c, intent) : c.json({ error: "intent_not_found" }, 404);
  });

  app.post("/fx-telarana/supply/intents/:id/signature", async (c) =>
    json(c, await verifyStoredIntent(c.req.param("id"), await parseJson(intentSignatureSchema, c)))
  );

  app.post("/fx-telarana/borrow/intents", async (c) => {
    const body = await parseJson(borrowIntentSchema, c);
    return json(c, storeIntent("Borrow", buildBorrowIntent({ chainId: body.hubChainId, ...body })), 201);
  });

  app.get("/fx-telarana/borrow/intents/:id", (c) => {
    const intent = getIntent(c.req.param("id"));
    return intent ? json(c, intent) : c.json({ error: "intent_not_found" }, 404);
  });

  app.post("/fx-telarana/borrow/intents/:id/signature", async (c) =>
    json(c, await verifyStoredIntent(c.req.param("id"), await parseJson(intentSignatureSchema, c)))
  );

  app.post("/fx-telarana/repay/intents", async (c) => {
    const body = await parseJson(repayIntentSchema, c);
    return json(c, storeIntent("Repay", buildRepayIntent({ chainId: body.hubChainId, ...body })), 201);
  });

  app.get("/fx-telarana/repay/intents/:id", (c) => {
    const intent = getIntent(c.req.param("id"));
    return intent ? json(c, intent) : c.json({ error: "intent_not_found" }, 404);
  });

  app.post("/fx-telarana/repay/intents/:id/signature", async (c) =>
    json(c, await verifyStoredIntent(c.req.param("id"), await parseJson(intentSignatureSchema, c)))
  );

  app.post("/fx-telarana/withdraw/intents", async (c) => {
    const body = await parseJson(withdrawIntentSchema, c);
    return json(c, storeIntent("Withdraw", buildWithdrawIntent({ chainId: body.hubChainId, ...body })), 201);
  });

  app.get("/fx-telarana/withdraw/intents/:id", (c) => {
    const intent = getIntent(c.req.param("id"));
    return intent ? json(c, intent) : c.json({ error: "intent_not_found" }, 404);
  });

  app.post("/fx-telarana/withdraw/intents/:id/signature", async (c) =>
    json(c, await verifyStoredIntent(c.req.param("id"), await parseJson(intentSignatureSchema, c)))
  );

  app.post("/fx-telarana/collateral/supply/intents", async (c) => {
    const body = await parseJson(collateralIntentSchema, c);
    return json(
      c,
      storeIntent("SupplyCollateral", buildSupplyCollateralIntent({ chainId: body.hubChainId, ...body })),
      201
    );
  });

  app.get("/fx-telarana/collateral/supply/intents/:id", (c) => {
    const intent = getIntent(c.req.param("id"));
    return intent ? json(c, intent) : c.json({ error: "intent_not_found" }, 404);
  });

  app.post("/fx-telarana/collateral/supply/intents/:id/signature", async (c) =>
    json(c, await verifyStoredIntent(c.req.param("id"), await parseJson(intentSignatureSchema, c)))
  );

  app.post("/fx-telarana/collateral/withdraw/intents", async (c) => {
    const body = await parseJson(collateralIntentSchema, c);
    return json(
      c,
      storeIntent("WithdrawCollateral", buildWithdrawCollateralIntent({ chainId: body.hubChainId, ...body })),
      201
    );
  });

  app.get("/fx-telarana/collateral/withdraw/intents/:id", (c) => {
    const intent = getIntent(c.req.param("id"));
    return intent ? json(c, intent) : c.json({ error: "intent_not_found" }, 404);
  });

  app.post("/fx-telarana/collateral/withdraw/intents/:id/signature", async (c) =>
    json(c, await verifyStoredIntent(c.req.param("id"), await parseJson(intentSignatureSchema, c)))
  );

  app.get("/fx-telarana/liquidations/candidates", async (c) => {
    const query = liquidationCandidatesQuerySchema.parse({
      hubChainId: c.req.query("hubChainId") ? Number(c.req.query("hubChainId")) : undefined,
      marketId: c.req.query("marketId"),
      limit: c.req.query("limit"),
      cursor: c.req.query("cursor"),
    });
    const search = new URLSearchParams();
    search.set("limit", String(query.limit));
    if (query.hubChainId) search.set("hubChainId", String(query.hubChainId));
    if (query.marketId) search.set("marketId", query.marketId);
    const indexed = await fetchPonderJson(`/fx-telarana/liquidations/candidates?${search.toString()}`);
    return json(c, indexed ?? { ...query, source: "ponder_unconfigured", candidates: [] });
  });

  app.get(
    "/fx-telarana/liquidations/density",
    requireX402Payment({ endpoint: "liquidation_density" }),
    async (c) => {
      const search = new URLSearchParams();
      if (c.req.query("hubChainId")) search.set("hubChainId", c.req.query("hubChainId")!);
      const indexed = await fetchPonderJson(`/fx-telarana/liquidations/density?${search.toString()}`);
      return json(c, indexed ?? { density: [], source: "ponder_unconfigured" });
    }
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

  app.get("/fx-telarana/tvl/defillama", async (c) => {
    const indexed = await fetchPonderJson("/fx-telarana/tvl/defillama");
    return json(c, indexed ?? buildInternalDefiLlamaPayload(await listMarkets()));
  });

  return app;
}
