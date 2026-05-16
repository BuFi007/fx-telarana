// SPDX-License-Identifier: AGPL-3.0-only
import { getAddress, isAddress, type Address, type Hex } from "viem";
import { z } from "zod";

import { ChainId } from "@fx-telarana/contracts";

export const addressSchema = z
  .string()
  .refine(isAddress, "Expected an EVM address")
  .transform((value) => getAddress(value) as Address);

export const hexSchema = z.string().regex(/^0x[0-9a-fA-F]*$/, "Expected a hex string") as z.ZodType<Hex>;

export const marketIdSchema = z
  .string()
  .regex(/^0x[0-9a-fA-F]{64}$/, "Expected a bytes32 market id") as z.ZodType<Hex>;

export const bigintStringSchema = z
  .string()
  .regex(/^[0-9]+$/, "Expected an unsigned integer string")
  .transform((value) => BigInt(value));

export const hubChainIdSchema = z.union([
  z.literal(ChainId.AvalancheFuji),
  z.literal(ChainId.ArcTestnet),
]);

export const marketPairSchema = z.object({
  loanToken: addressSchema,
  collateralToken: addressSchema,
  hubChainId: hubChainIdSchema,
});

export const marketRefSchema = z.object({
  hubChainId: hubChainIdSchema,
  marketId: marketIdSchema,
});

export const quoteSupplySchema = marketPairSchema.extend({
  assets: bigintStringSchema,
  account: addressSchema.optional(),
});

export const quoteBorrowSchema = marketPairSchema.extend({
  collateral: bigintStringSchema,
  borrowAmount: bigintStringSchema,
  account: addressSchema.optional(),
});

export const quoteRepaySchema = marketPairSchema.extend({
  assets: bigintStringSchema,
  account: addressSchema.optional(),
});

export const quoteWithdrawSchema = marketPairSchema.extend({
  shares: bigintStringSchema,
  account: addressSchema.optional(),
});

export const intentBaseSchema = marketPairSchema.extend({
  spokeChainId: z.number().int().positive(),
  onBehalf: addressSchema,
  nonce: bigintStringSchema,
  deadline: z.number().int().positive(),
});

export const supplyIntentSchema = intentBaseSchema.extend({
  assets: bigintStringSchema,
});

export const borrowIntentSchema = intentBaseSchema.extend({
  borrowAssets: bigintStringSchema,
  receiver: addressSchema,
});

export const repayIntentSchema = intentBaseSchema.extend({
  assets: bigintStringSchema,
});

export const withdrawIntentSchema = intentBaseSchema.extend({
  shares: bigintStringSchema,
  receiver: addressSchema,
});

export const collateralIntentSchema = intentBaseSchema.extend({
  collateral: bigintStringSchema,
});

export const liquidationCandidatesQuerySchema = z.object({
  hubChainId: hubChainIdSchema.optional(),
  marketId: marketIdSchema.optional(),
  limit: z.coerce.number().int().positive().max(250).default(50),
  cursor: z.string().optional(),
});

export const tvlQuerySchema = z.object({
  by: z.enum(["market", "hub", "total"]).default("total"),
});
