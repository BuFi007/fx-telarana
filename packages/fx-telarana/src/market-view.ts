// SPDX-License-Identifier: AGPL-3.0-only
import { createLogger } from "@bufinance/logger";
import type { Address, Hex, PublicClient } from "viem";

import { FxMarketRegistryAbi, MorphoBlueAbi, type FxHubChainId } from "@fx-telarana/contracts";

import { LENDING_HUBS } from "./chains.js";
import { getHubClient, type HubClientMap } from "./clients.js";
import type { LendingMarket, MarketParams } from "./types.js";

const log = createLogger({ prefix: "fx-telarana:markets" });
const DEFAULT_MARKET_CACHE_MS = 30_000;

type MarketListCache = {
  expiresAt: number;
  markets: LendingMarket[];
};

let marketListCache: MarketListCache | null = null;
let marketListInFlight: Promise<LendingMarket[]> | null = null;

function marketCacheTtlMs(): number {
  const configured = Number(process.env.FX_TELARANA_MARKET_CACHE_MS ?? DEFAULT_MARKET_CACHE_MS);
  return Number.isFinite(configured) && configured > 0 ? configured : 0;
}

function normalizeMarketParams(value: unknown): MarketParams {
  const record = value as {
    loanToken: Address;
    collateralToken: Address;
    oracle: Address;
    irm: Address;
    lltv: bigint;
  };
  return {
    loanToken: record.loanToken,
    collateralToken: record.collateralToken,
    oracle: record.oracle,
    irm: record.irm,
    lltv: BigInt(record.lltv),
  };
}

export async function readMarketState(args: {
  client: PublicClient;
  morpho: Address;
  marketId: Hex;
}) {
  return args.client.readContract({
    address: args.morpho,
    abi: MorphoBlueAbi,
    functionName: "market",
    args: [args.marketId],
  });
}

export function clearMarketListCacheForTests(): void {
  marketListCache = null;
  marketListInFlight = null;
}

export async function listMarkets(
  options: { clients?: HubClientMap; forceRefresh?: boolean } = {}
): Promise<LendingMarket[]> {
  const cacheTtlMs = marketCacheTtlMs();
  const canUseCache = !options.clients && !options.forceRefresh && cacheTtlMs > 0;
  if (canUseCache && marketListCache && marketListCache.expiresAt > Date.now()) {
    return marketListCache.markets;
  }

  if (canUseCache && marketListInFlight) {
    return marketListInFlight;
  }

  const readMarkets = async () => {
    const perHub = await Promise.all(
      LENDING_HUBS.map(async (hub) => {
        const client = getHubClient(options.clients, hub.chainId);
        try {
          const pools = await client.readContract({
            address: hub.marketRegistry,
            abi: FxMarketRegistryAbi,
            functionName: "listPools",
          });

          return Promise.all(
            (pools as unknown[]).map(async (pool) => {
              const params = normalizeMarketParams(pool);
              const [id, isLive] = await Promise.all([
                client.readContract({
                  address: hub.marketRegistry,
                  abi: FxMarketRegistryAbi,
                  functionName: "marketIdOf",
                  args: [params.loanToken, params.collateralToken],
                }) as Promise<Hex>,
                client.readContract({
                  address: hub.marketRegistry,
                  abi: FxMarketRegistryAbi,
                  functionName: "isPoolLive",
                  args: [params.loanToken, params.collateralToken],
                }) as Promise<boolean>,
              ]);
              const state = await readMarketState({ client, morpho: hub.morphoBlue, marketId: id }).catch(
                () => undefined
              );

              const market: LendingMarket = {
                ...params,
                id,
                hubChainId: hub.chainId,
                hubName: hub.name,
                isLive,
              };

              if (state) {
                market.state = state;
              }
              return market;
            })
          );
        } catch (error) {
          log.warn(
            JSON.stringify({
              msg: "market list read failed",
              hub: hub.name,
              chainId: hub.chainId,
              error: error instanceof Error ? error.message : String(error),
            })
          );
          return [];
        }
      })
    );

    const markets = perHub.flat();
    if (canUseCache) {
      marketListCache = {
        markets,
        expiresAt: Date.now() + cacheTtlMs,
      };
    }
    return markets;
  };

  if (!canUseCache) {
    return readMarkets();
  }

  marketListInFlight = readMarkets().finally(() => {
    marketListInFlight = null;
  });
  return marketListInFlight;
}

export async function getMarketById(args: {
  hubChainId: FxHubChainId;
  marketId: Hex;
  clients?: HubClientMap;
}): Promise<LendingMarket | null> {
  const markets = await listMarkets(args.clients ? { clients: args.clients } : {});
  return (
    markets.find(
      (market) => market.hubChainId === args.hubChainId && market.id.toLowerCase() === args.marketId.toLowerCase()
    ) ?? null
  );
}

export async function getMarketByPair(args: {
  hubChainId: FxHubChainId;
  loanToken: `0x${string}`;
  collateralToken: `0x${string}`;
  clients?: HubClientMap;
}): Promise<LendingMarket | null> {
  const markets = await listMarkets(args.clients ? { clients: args.clients } : {});
  return (
    markets.find(
      (market) =>
        market.hubChainId === args.hubChainId &&
        market.loanToken.toLowerCase() === args.loanToken.toLowerCase() &&
        market.collateralToken.toLowerCase() === args.collateralToken.toLowerCase()
    ) ?? null
  );
}
