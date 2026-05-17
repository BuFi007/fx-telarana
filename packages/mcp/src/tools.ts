// SPDX-License-Identifier: AGPL-3.0-only
import { z } from "zod";

import {
  borrowIntentSchema,
  buildBorrowIntent,
  buildRepayIntent,
  buildSupplyCollateralIntent,
  buildSupplyIntent,
  buildWithdrawCollateralIntent,
  buildWithdrawIntent,
  collateralIntentSchema,
  ensureMarketState,
  getMarketByPair,
  listAccountPositions,
  listMarkets,
  marketIdSchema,
  marketPairSchema,
  readMarketOracleQuote,
  quoteBorrow,
  quoteBorrowSchema,
  quoteSupply,
  quoteSupplySchema,
  rankLiquidationCandidates,
  repayIntentSchema,
  stringifyBalances,
  supplyIntentSchema,
  aggregateTvl,
  withdrawIntentSchema,
  WAD,
} from "@fx-telarana/core";

import { addressProperty, marketPairJsonSchema, uintStringProperty } from "./json-schema.js";
import type { ToolDef } from "./types.js";

const inspectPositionSchema = z.object({
  address: z.string(),
  marketId: z.string(),
  hubChainId: z.number().optional(),
});

const limitSchema = z.object({
  market: z.string().optional(),
  limit: z.number().int().positive().max(250).default(50),
});

export const fxTelaranaTools = [
  {
    name: "inspect_fx_telarana_market",
    description: "Inspect one FX Telarana lending market by loan/collateral pair and hub chain.",
    inputSchema: marketPairSchema,
    jsonSchema: marketPairJsonSchema,
    async handler(input) {
      const markets = await listMarkets();
      return (
        markets.find(
          (market) =>
            market.hubChainId === input.hubChainId &&
            market.loanToken.toLowerCase() === input.loanToken.toLowerCase() &&
            market.collateralToken.toLowerCase() === input.collateralToken.toLowerCase()
        ) ?? null
      );
    },
  },
  {
    name: "inspect_fx_telarana_position",
    description: "Inspect a live Morpho position for a FX Telarana lending market. Read-only.",
    inputSchema: inspectPositionSchema,
    jsonSchema: {
      type: "object",
      additionalProperties: false,
      required: ["address", "marketId"],
      properties: { address: addressProperty, marketId: { type: "string" }, hubChainId: { type: "number" } },
    },
    async handler(input) {
      const positions = await listAccountPositions({
        account: input.address as `0x${string}`,
        marketId: marketIdSchema.parse(input.marketId),
        includeEmpty: true,
        ...(input.hubChainId ? { hubChainId: input.hubChainId as 43113 | 5042002 } : {}),
      });
      return positions[0] ?? null;
    },
  },
  {
    name: "quote_fx_telarana_supply",
    description: "Quote supply shares from market totals. Read-only.",
    inputSchema: quoteSupplySchema,
    jsonSchema: {
      ...marketPairJsonSchema,
      required: [...(marketPairJsonSchema.required ?? []), "assets"],
      properties: { ...marketPairJsonSchema.properties, assets: uintStringProperty },
    },
    async handler(input) {
      const market = await getMarketByPair(input);
      if (!market) throw new Error("Market not found");
      const state = await ensureMarketState({ market });
      return quoteSupply({
        assets: input.assets,
        totalSupplyAssets: state.totalSupplyAssets,
        totalSupplyShares: state.totalSupplyShares,
      });
    },
  },
  {
    name: "quote_fx_telarana_borrow",
    description: "Quote borrow health factor from supplied collateral and requested borrow amount.",
    inputSchema: quoteBorrowSchema,
    jsonSchema: {
      ...marketPairJsonSchema,
      required: [...(marketPairJsonSchema.required ?? []), "collateral", "borrowAmount"],
      properties: {
        ...marketPairJsonSchema.properties,
        collateral: uintStringProperty,
        borrowAmount: uintStringProperty,
        account: addressProperty,
      },
    },
    async handler(input) {
      const market = await getMarketByPair(input);
      if (!market) throw new Error("Market not found");
      const [state, oracle, positions] = await Promise.all([
        ensureMarketState({ market }),
        readMarketOracleQuote({ market }),
        input.account
          ? listAccountPositions({
              account: input.account,
              hubChainId: market.hubChainId,
              marketId: market.id,
              includeEmpty: true,
            })
          : Promise.resolve([]),
      ]);
      const existingPosition = positions[0] ?? null;
      return quoteBorrow({
        market: { ...market, state },
        collateral: (existingPosition?.collateral ?? 0n) + input.collateral,
        borrowAmount: input.borrowAmount,
        ...(existingPosition ? { existingBorrowShares: existingPosition.borrowShares } : {}),
        totalBorrowAssets: state.totalBorrowAssets,
        totalBorrowShares: state.totalBorrowShares,
        collateralPriceE36: oracle.midE18 * WAD,
      });
    },
  },
  {
    name: "list_fx_telarana_liquidation_candidates",
    description: "List liquidation candidates from indexed positions, sorted by health factor ascending.",
    inputSchema: limitSchema,
    jsonSchema: {
      type: "object",
      additionalProperties: false,
      properties: { market: { type: "string" }, limit: { type: "number" } },
    },
    async handler(input) {
      return rankLiquidationCandidates([], input.limit);
    },
  },
  {
    name: "inspect_fx_telarana_oracle_freshness",
    description: "Inspect oracle freshness policy for a market. Read-only.",
    inputSchema: marketPairSchema,
    jsonSchema: marketPairJsonSchema,
    async handler(input) {
      const market = await getMarketByPair(input);
      if (!market) throw new Error("Market not found");
      const oracle = await readMarketOracleQuote({ market });
      return {
        ...input,
        oracleSurface: "FxOracle.getMid",
        directPythOrRedStoneHttp: false,
        midE18: oracle.midE18,
        publishedAt: oracle.publishedAt,
      };
    },
  },
  {
    name: "inspect_fx_telarana_tvl",
    description: "Inspect TVL aggregates in DefiLlama-compatible token balance shape.",
    inputSchema: z.object({ by: z.enum(["byMarket", "byHub", "total"]).default("total") }),
    jsonSchema: {
      type: "object",
      additionalProperties: false,
      properties: { by: { type: "string", enum: ["byMarket", "byHub", "total"] } },
    },
    async handler() {
      const breakdown = aggregateTvl(await listMarkets());
      return {
        tvl: stringifyBalances(breakdown.netSupply),
        borrowed: stringifyBalances(breakdown.borrowed),
      };
    },
  },
  {
    name: "build_supply_intent",
    description: "Build an unsigned EIP-712 supply intent. Never executes a transaction.",
    inputSchema: supplyIntentSchema,
    jsonSchema: {
      ...marketPairJsonSchema,
      required: [...(marketPairJsonSchema.required ?? []), "spokeChainId", "assets", "onBehalf", "nonce", "deadline"],
      properties: {
        ...marketPairJsonSchema.properties,
        spokeChainId: { type: "number" },
        assets: uintStringProperty,
        onBehalf: addressProperty,
        nonce: uintStringProperty,
        deadline: { type: "number" },
      },
    },
    signedAction: true,
    async handler(input) {
      return { unsigned: true, typedData: buildSupplyIntent({ chainId: input.hubChainId, ...input }) };
    },
  },
  {
    name: "build_borrow_intent",
    description: "Build an unsigned EIP-712 borrow intent. Never executes a transaction.",
    inputSchema: borrowIntentSchema,
    jsonSchema: {
      type: "object",
      additionalProperties: false,
      properties: {},
    },
    signedAction: true,
    async handler(input) {
      return { unsigned: true, typedData: buildBorrowIntent({ chainId: input.hubChainId, ...input }) };
    },
  },
  {
    name: "build_repay_intent",
    description: "Build an unsigned EIP-712 repay intent. Never executes a transaction.",
    inputSchema: repayIntentSchema,
    jsonSchema: { type: "object", additionalProperties: false, properties: {} },
    signedAction: true,
    async handler(input) {
      return { unsigned: true, typedData: buildRepayIntent({ chainId: input.hubChainId, ...input }) };
    },
  },
  {
    name: "build_withdraw_intent",
    description: "Build an unsigned EIP-712 withdraw intent. Never executes a transaction.",
    inputSchema: withdrawIntentSchema,
    jsonSchema: { type: "object", additionalProperties: false, properties: {} },
    signedAction: true,
    async handler(input) {
      return { unsigned: true, typedData: buildWithdrawIntent({ chainId: input.hubChainId, ...input }) };
    },
  },
  {
    name: "build_supplyCollateral_intent",
    description: "Build an unsigned EIP-712 supply-collateral intent. Never executes a transaction.",
    inputSchema: collateralIntentSchema,
    jsonSchema: { type: "object", additionalProperties: false, properties: {} },
    signedAction: true,
    async handler(input) {
      return { unsigned: true, typedData: buildSupplyCollateralIntent({ chainId: input.hubChainId, ...input }) };
    },
  },
  {
    name: "build_withdrawCollateral_intent",
    description: "Build an unsigned EIP-712 withdraw-collateral intent. Never executes a transaction.",
    inputSchema: collateralIntentSchema,
    jsonSchema: { type: "object", additionalProperties: false, properties: {} },
    signedAction: true,
    async handler(input) {
      return { unsigned: true, typedData: buildWithdrawCollateralIntent({ chainId: input.hubChainId, ...input }) };
    },
  },
] satisfies ToolDef<any, any>[];
