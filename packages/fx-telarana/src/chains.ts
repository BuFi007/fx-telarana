// SPDX-License-Identifier: AGPL-3.0-only
import type { Address } from "viem";

import { ChainId, telarana, type FxHubChainId, type HubName } from "@fx-telarana/contracts";

export type LendingHubConfig = {
  name: HubName;
  chainId: FxHubChainId;
  label: string;
  marketRegistry: Address;
  oracle: Address;
  liquidator: Address;
  morphoBlue: Address;
  rpcEnv: "FUJI_RPC_URL" | "ARC_RPC_URL" | "MARKET_DATA_RPC_URL";
  defaultRpcUrl: string;
};

const hubs = telarana.hubs();

export const LENDING_HUBS = [
  {
    name: "fuji",
    chainId: ChainId.AvalancheFuji,
    label: "Avalanche Fuji",
    marketRegistry: hubs.fuji.marketRegistry,
    oracle: hubs.fuji.oracle,
    liquidator: hubs.fuji.liquidator,
    morphoBlue: hubs.fuji.morphoBlue,
    rpcEnv: "FUJI_RPC_URL",
    defaultRpcUrl: "https://api.avax-test.network/ext/bc/C/rpc",
  },
  {
    name: "arc",
    chainId: ChainId.ArcTestnet,
    label: "Arc Testnet",
    marketRegistry: hubs.arc.marketRegistry,
    oracle: hubs.arc.oracle,
    liquidator: hubs.arc.liquidator,
    morphoBlue: hubs.arc.morphoBlue,
    rpcEnv: "ARC_RPC_URL",
    defaultRpcUrl: "https://rpc.testnet.arc.network",
  },
] as const satisfies readonly LendingHubConfig[];

export function hubByChainId(chainId: number): LendingHubConfig {
  const hub = LENDING_HUBS.find((candidate) => candidate.chainId === chainId);
  if (!hub) throw new Error(`Unsupported FX Telarana lending hub chainId ${chainId}`);
  return hub;
}

export function rpcUrlForHub(hub: LendingHubConfig): string {
  return process.env[hub.rpcEnv] ?? process.env.MARKET_DATA_RPC_URL ?? hub.defaultRpcUrl;
}
