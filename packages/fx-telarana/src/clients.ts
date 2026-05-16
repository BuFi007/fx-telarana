// SPDX-License-Identifier: AGPL-3.0-only
import { createPublicClient, http, type PublicClient } from "viem";

import { chainForHub, type FxHubChainId } from "@fx-telarana/contracts";

import { LENDING_HUBS, rpcUrlForHub } from "./chains.js";

export type HubClientMap = Partial<Record<FxHubChainId, PublicClient>>;

export function createHubPublicClient(chainId: FxHubChainId): PublicClient {
  const hub = LENDING_HUBS.find((candidate) => candidate.chainId === chainId);
  if (!hub) throw new Error(`Unsupported hub chainId ${chainId}`);
  return createPublicClient({
    chain: chainForHub(chainId),
    transport: http(rpcUrlForHub(hub)),
  });
}

export function createHubClients(): HubClientMap {
  return Object.fromEntries(
    LENDING_HUBS.map((hub) => [hub.chainId, createHubPublicClient(hub.chainId)])
  ) as HubClientMap;
}

export function getHubClient(clients: HubClientMap | undefined, chainId: FxHubChainId): PublicClient {
  return clients?.[chainId] ?? createHubPublicClient(chainId);
}
