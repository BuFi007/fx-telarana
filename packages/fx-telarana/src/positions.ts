// SPDX-License-Identifier: AGPL-3.0-only
import type { Address, Hex, PublicClient } from "viem";

import {
  MorphoBlueAbi,
  type FxHubChainId,
  type MorphoMarketState,
  type MorphoPositionState,
} from "@fx-telarana/contracts";

import { hubByChainId } from "./chains.js";
import { getHubClient, type HubClientMap } from "./clients.js";
import { WAD } from "./constants.js";
import { FxTelaranaError } from "./errors.js";
import { getMarketById, listMarkets, readMarketState } from "./market-view.js";
import { toAssetsDown, toAssetsUp } from "./morpho-math.js";
import { readFxOracleMid } from "./oracle.js";
import { calculateHealthFactorE18 } from "./quote-engine.js";
import type { AccountPosition, LendingMarket, OracleQuote } from "./types.js";

export async function readMorphoPosition(args: {
  client: PublicClient;
  morpho: Address;
  marketId: Hex;
  account: Address;
}): Promise<MorphoPositionState> {
  return args.client.readContract({
    address: args.morpho,
    abi: MorphoBlueAbi,
    functionName: "position",
    args: [args.marketId, args.account],
  }) as Promise<MorphoPositionState>;
}

export async function ensureMarketState(args: {
  market: LendingMarket;
  clients?: HubClientMap;
}): Promise<MorphoMarketState> {
  if (args.market.state) return args.market.state;
  const hub = hubByChainId(args.market.hubChainId);
  return readMarketState({
    client: getHubClient(args.clients, args.market.hubChainId),
    morpho: hub.morphoBlue,
    marketId: args.market.id,
  }) as Promise<MorphoMarketState>;
}

export async function readMarketOracleQuote(args: {
  market: LendingMarket;
  clients?: HubClientMap;
  staleAfterSeconds?: number;
  now?: number;
}): Promise<OracleQuote> {
  const hub = hubByChainId(args.market.hubChainId);
  return readFxOracleMid({
    client: getHubClient(args.clients, args.market.hubChainId),
    fxOracle: hub.oracle,
    base: args.market.collateralToken,
    quote: args.market.loanToken,
    ...(args.staleAfterSeconds !== undefined ? { staleAfterSeconds: args.staleAfterSeconds } : {}),
    ...(args.now !== undefined ? { now: args.now } : {}),
  });
}

export function buildAccountPositionView(args: {
  market: LendingMarket;
  state: MorphoMarketState;
  position: MorphoPositionState;
  account: Address;
  oracle?: OracleQuote;
}): AccountPosition {
  const supplyAssets = toAssetsDown(
    args.position.supplyShares,
    args.state.totalSupplyAssets,
    args.state.totalSupplyShares
  );
  const borrowAssets = toAssetsUp(
    args.position.borrowShares,
    args.state.totalBorrowAssets,
    args.state.totalBorrowShares
  );
  const collateralPriceE36 = args.oracle ? args.oracle.midE18 * WAD : null;
  const healthFactorE18 =
    borrowAssets > 0n && collateralPriceE36 !== null
      ? calculateHealthFactorE18({
          collateralAssets: args.position.collateral,
          collateralPriceE36,
          borrowAssetsE18: borrowAssets,
          lltv: args.market.lltv,
        })
      : null;

  return {
    id: `${args.market.hubChainId}:${args.market.id}:${args.account.toLowerCase()}`,
    marketId: args.market.id,
    hubChainId: args.market.hubChainId,
    account: args.account,
    supplyShares: args.position.supplyShares,
    borrowShares: args.position.borrowShares,
    collateral: args.position.collateral,
    supplyAssets,
    borrowAssets,
    collateralPriceE36,
    oraclePublishedAt: args.oracle?.publishedAt ?? null,
    healthFactorE18,
    liquidatable: healthFactorE18 !== null && healthFactorE18 < WAD,
  };
}

export function hasPositionExposure(position: AccountPosition): boolean {
  return position.supplyShares > 0n || position.borrowShares > 0n || position.collateral > 0n;
}

export async function getAccountPosition(args: {
  account: Address;
  hubChainId: FxHubChainId;
  marketId: Hex;
  clients?: HubClientMap;
  staleAfterSeconds?: number;
  now?: number;
}): Promise<AccountPosition | null> {
  const market = await getMarketById({
    hubChainId: args.hubChainId,
    marketId: args.marketId,
    ...(args.clients ? { clients: args.clients } : {}),
  });
  if (!market) return null;

  const hub = hubByChainId(market.hubChainId);
  const client = getHubClient(args.clients, market.hubChainId);
  const [state, position] = await Promise.all([
    ensureMarketState({ market, ...(args.clients ? { clients: args.clients } : {}) }),
    readMorphoPosition({
      client,
      morpho: hub.morphoBlue,
      marketId: market.id,
      account: args.account,
    }),
  ]);
  const needsOracle = position.borrowShares > 0n || position.collateral > 0n;
  const oracle = needsOracle
      ? await readMarketOracleQuote({
          market,
          ...(args.clients ? { clients: args.clients } : {}),
          ...(args.staleAfterSeconds !== undefined ? { staleAfterSeconds: args.staleAfterSeconds } : {}),
          ...(args.now !== undefined ? { now: args.now } : {}),
        })
      : undefined;
  return buildAccountPositionView({ market, state, position, account: args.account, ...(oracle ? { oracle } : {}) });
}

export async function listAccountPositions(args: {
  account: Address;
  hubChainId?: FxHubChainId;
  marketId?: Hex;
  clients?: HubClientMap;
  includeEmpty?: boolean;
  staleAfterSeconds?: number;
  now?: number;
}): Promise<AccountPosition[]> {
  const markets = (await listMarkets(args.clients ? { clients: args.clients } : {})).filter(
    (market) =>
      (args.hubChainId === undefined || market.hubChainId === args.hubChainId) &&
      (args.marketId === undefined || market.id.toLowerCase() === args.marketId.toLowerCase())
  );

  const positions = await Promise.all(
    markets.map((market) =>
      getAccountPosition({
        account: args.account,
        hubChainId: market.hubChainId,
        marketId: market.id,
        ...(args.clients ? { clients: args.clients } : {}),
        ...(args.staleAfterSeconds !== undefined ? { staleAfterSeconds: args.staleAfterSeconds } : {}),
        ...(args.now !== undefined ? { now: args.now } : {}),
      })
    )
  );

  return positions.filter((position): position is AccountPosition => {
    if (!position) return false;
    return args.includeEmpty === true || hasPositionExposure(position);
  });
}

export function assertMarketStateAvailable(state: MorphoMarketState | undefined): asserts state is MorphoMarketState {
  if (!state) {
    throw new FxTelaranaError("Morpho market state is unavailable", "MARKET_STATE_UNAVAILABLE", 503);
  }
}
