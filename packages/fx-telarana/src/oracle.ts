// SPDX-License-Identifier: AGPL-3.0-only
import type { Address, PublicClient } from "viem";

import { FxOracleAbi } from "@fx-telarana/contracts";

import { DEFAULT_QUOTE_STALE_AFTER_SECONDS } from "./constants.js";
import { OracleStaleError } from "./errors.js";
import type { OracleQuote } from "./types.js";

export async function readFxOracleMid(args: {
  client: PublicClient;
  fxOracle: Address;
  base: Address;
  quote: Address;
  staleAfterSeconds?: number;
  now?: number;
}): Promise<OracleQuote> {
  try {
    const [midE18, publishedAt] = await args.client.readContract({
      address: args.fxOracle,
      abi: FxOracleAbi,
      functionName: "getMid",
      args: [args.base, args.quote],
    });
    const now = BigInt(args.now ?? Math.floor(Date.now() / 1000));
    const maxAge = BigInt(args.staleAfterSeconds ?? DEFAULT_QUOTE_STALE_AFTER_SECONDS);
    if (publishedAt > 0n && now > publishedAt && now - publishedAt > maxAge) {
      throw new OracleStaleError();
    }
    return { midE18, publishedAt };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/stale/i.test(message)) throw new OracleStaleError(message);
    throw error;
  }
}
