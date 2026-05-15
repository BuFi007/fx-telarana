// SPDX-License-Identifier: Apache-2.0
import type { Address, PublicClient } from "viem";
import { FxOracleAbi } from "../abis/index.js";

export interface QuoteResult {
  /// 1e18-scaled mid: midE18 = (base / quote) * 1e18
  midE18: bigint;
  /// Unix seconds of the latest underlying Pyth publish (min of base+quote)
  publishedAt: bigint;
}

/// Pyth-only view read. Cheap. Reverts on staleness or low confidence.
export async function getMid(
  client: PublicClient,
  fxOracle: Address,
  base: Address,
  quote: Address
): Promise<QuoteResult> {
  const [midE18, publishedAt] = await client.readContract({
    address: fxOracle,
    abi: FxOracleAbi,
    functionName: "getMid",
    args: [base, quote],
  });
  return { midE18, publishedAt };
}

/// Verified read — runs the deviation gate vs RedStone. Caller must wrap the tx
/// with the RedStone SDK so the signed payload is in msg.data tail. For pure-
/// read use cases (no tx), `getMid` is what you want.
export async function getMidVerified(
  client: PublicClient,
  fxOracle: Address,
  base: Address,
  quote: Address
): Promise<QuoteResult> {
  const [midE18, publishedAt] = await client.readContract({
    address: fxOracle,
    abi: FxOracleAbi,
    functionName: "getMidVerified",
    args: [base, quote],
  });
  return { midE18, publishedAt };
}
