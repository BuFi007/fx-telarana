// SPDX-License-Identifier: AGPL-3.0-only
import { ChainId } from "@fx-telarana/contracts";
import { listMarkets } from "@fx-telarana/core";

type DefiLlamaApi = {
  chain?: string;
  add(token: string, amount: bigint | string): void;
};

async function addForChain(api: DefiLlamaApi, chainId: number, kind: "tvl" | "borrowed") {
  const markets = (await listMarkets()).filter((market) => market.hubChainId === chainId);
  for (const market of markets) {
    const amount =
      kind === "tvl"
        ? (market.state?.totalSupplyAssets ?? 0n)
        : (market.state?.totalBorrowAssets ?? 0n);
    api.add(market.loanToken, amount);
  }
}

export async function avalancheTvl(api: DefiLlamaApi) {
  await addForChain(api, ChainId.AvalancheFuji, "tvl");
}

export async function avalancheBorrowed(api: DefiLlamaApi) {
  await addForChain(api, ChainId.AvalancheFuji, "borrowed");
}

export async function arcTvl(api: DefiLlamaApi) {
  await addForChain(api, ChainId.ArcTestnet, "tvl");
}

export async function arcBorrowed(api: DefiLlamaApi) {
  await addForChain(api, ChainId.ArcTestnet, "borrowed");
}

export const methodology =
  "Sums net supplied assets and borrowed assets across FxMarketRegistry-registered Morpho Blue isolated markets.";

export const adapter = {
  methodology,
  misrepresentedTokens: false,
  avalanche: {
    tvl: avalancheTvl,
    borrowed: avalancheBorrowed,
  },
  arc: {
    tvl: arcTvl,
    borrowed: arcBorrowed,
  },
};

export default adapter;
