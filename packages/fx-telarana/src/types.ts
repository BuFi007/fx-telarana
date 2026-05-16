// SPDX-License-Identifier: AGPL-3.0-only
import type { Address, Hex } from "viem";

import type { FxHubChainId, MorphoMarketState, MorphoPositionState } from "@fx-telarana/contracts";

export type MarketParams = {
  loanToken: Address;
  collateralToken: Address;
  oracle: Address;
  irm: Address;
  lltv: bigint;
};

export type LendingMarket = MarketParams & {
  id: Hex;
  hubChainId: FxHubChainId;
  hubName: "fuji" | "arc";
  isLive: boolean;
  state?: MorphoMarketState;
};

export type AccountPosition = MorphoPositionState & {
  id: string;
  marketId: Hex;
  hubChainId: FxHubChainId;
  account: Address;
  supplyAssets: bigint;
  borrowAssets: bigint;
  healthFactorE18: bigint | null;
  liquidatable: boolean;
};

export type OracleQuote = {
  midE18: bigint;
  publishedAt: bigint;
};

export type BorrowQuote = {
  market: LendingMarket;
  collateral: bigint;
  borrowAmount: bigint;
  healthFactorE18: bigint;
  liquidatable: boolean;
  maxBorrowAssets: bigint;
};
