// SPDX-License-Identifier: AGPL-3.0-only
import type { Address } from "viem";

import type { LendingMarket } from "./types.js";

export type TokenBalanceMap = Record<Address, bigint>;

export type TvlBreakdown = {
  tvl: TokenBalanceMap;
  borrowed: TokenBalanceMap;
  netSupply: TokenBalanceMap;
};

function add(map: TokenBalanceMap, token: Address, amount: bigint) {
  map[token] = (map[token] ?? 0n) + amount;
}

export function aggregateTvl(markets: LendingMarket[]): TvlBreakdown {
  const tvl: TokenBalanceMap = {};
  const borrowed: TokenBalanceMap = {};
  const netSupply: TokenBalanceMap = {};

  for (const market of markets) {
    const supply = market.state?.totalSupplyAssets ?? 0n;
    const borrow = market.state?.totalBorrowAssets ?? 0n;
    add(tvl, market.loanToken, supply);
    add(borrowed, market.loanToken, borrow);
    add(netSupply, market.loanToken, supply > borrow ? supply - borrow : 0n);
  }

  return { tvl, borrowed, netSupply };
}

export function stringifyBalances(map: TokenBalanceMap): Record<string, string> {
  return Object.fromEntries(Object.entries(map).map(([token, amount]) => [token, amount.toString()]));
}
