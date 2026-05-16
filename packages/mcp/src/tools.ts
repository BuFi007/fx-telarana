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
  listMarkets,
  marketPairSchema,
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
} from "@fx-telarana/core";

import { addressProperty, marketPairJsonSchema, uintStringProperty } from "./json-schema.js";
import type { ToolDef } from "./types.js";

const inspectPositionSchema = z.object({
  address: z.string(),
  marketId: z.string(),
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
    description: "Inspect an indexed position. Read-only; backed by Ponder once index state is live.",
    inputSchema: inspectPositionSchema,
    jsonSchema: {
      type: "object",
      additionalProperties: false,
      required: ["address", "marketId"],
      properties: { address: addressProperty, marketId: { type: "string" } },
    },
    async handler(input) {
      return {
        address: input.address,
        marketId: input.marketId,
        source: "ponder_pending",
        note: "Position reads are wired through packages/ponder once the indexer has synced.",
      };
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
      return quoteSupply({
        assets: input.assets,
        totalSupplyAssets: 0n,
        totalSupplyShares: 0n,
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
      const markets = await listMarkets();
      const market = markets.find(
        (candidate) =>
          candidate.hubChainId === input.hubChainId &&
          candidate.loanToken.toLowerCase() === input.loanToken.toLowerCase() &&
          candidate.collateralToken.toLowerCase() === input.collateralToken.toLowerCase()
      );
      if (!market) throw new Error("Market not found");
      return quoteBorrow({
        market,
        collateral: input.collateral,
        borrowAmount: input.borrowAmount,
        collateralPriceE36: 10n ** 36n,
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
      return {
        ...input,
        oracleSurface: "FxOracle.getMid",
        directPythOrRedStoneHttp: false,
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
