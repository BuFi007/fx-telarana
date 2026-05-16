// SPDX-License-Identifier: Apache-2.0
import { defineChain } from "viem";
import { avalancheFuji } from "viem/chains";

import { ChainId } from "@bu/fx-engine/addresses";

export const arcTestnet = defineChain({
  id: ChainId.ArcTestnet,
  name: "Arc Testnet",
  nativeCurrency: {
    decimals: 18,
    name: "USDC",
    symbol: "USDC",
  },
  rpcUrls: {
    default: { http: ["https://rpc.testnet.arc.network"] },
  },
  blockExplorers: {
    default: {
      name: "Arc Testnet Explorer",
      url: "https://testnet.arcscan.app",
    },
  },
  testnet: true,
});

export const fxHubChains = {
  [ChainId.AvalancheFuji]: avalancheFuji,
  [ChainId.ArcTestnet]: arcTestnet,
} as const;

export type FxHubChainId = keyof typeof fxHubChains;

export function chainForHub(chainId: FxHubChainId) {
  return fxHubChains[chainId];
}
