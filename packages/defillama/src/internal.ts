// SPDX-License-Identifier: AGPL-3.0-only
import { aggregateTvl, stringifyBalances, type LendingMarket } from "@fx-telarana/core";

export function buildInternalDefiLlamaPayload(markets: LendingMarket[]) {
  const breakdown = aggregateTvl(markets);
  return {
    methodology:
      "Net supply is totalSupplyAssets - totalBorrowAssets across FX Telarana Morpho Blue isolated markets; borrowed is reported separately.",
    tvl: stringifyBalances(breakdown.netSupply),
    borrowed: stringifyBalances(breakdown.borrowed),
  };
}
