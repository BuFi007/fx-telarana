#!/usr/bin/env bun
// SPDX-License-Identifier: Apache-2.0
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { createPublicClient, http, parseAbi, type Address } from "viem";

import { FxMarketRegistryAbi } from "../src/abis/FxMarketRegistry";

type DeploymentManifest = {
  network?: string;
  chainId: number;
  rpcUrl?: string;
  contracts?: Record<string, Address>;
  hubStack?: Record<string, Address>;
};

const receiverAbi = parseAbi(["function MARKET_REGISTRY() view returns (address)"]);
const liquidatorAbi = parseAbi(["function REGISTRY() view returns (address)"]);

const DEFAULT_MANIFESTS = ["deployments/avalanche-fuji.json", "deployments/arc-testnet.json"];
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const DEFAULT_RPC_BY_CHAIN: Record<number, string> = {
  43113: "https://api.avax-test.network/ext/bc/C/rpc",
  5042002: "https://rpc.testnet.arc.network",
};

function manifestAddress(manifest: DeploymentManifest, name: string): Address | undefined {
  return manifest.contracts?.[name] ?? manifest.hubStack?.[name];
}

function rpcUrl(manifest: DeploymentManifest): string {
  if (manifest.chainId === 43113 && process.env.FUJI_RPC_URL) return process.env.FUJI_RPC_URL;
  if (manifest.chainId === 5042002 && process.env.ARC_RPC_URL) return process.env.ARC_RPC_URL;
  if (manifest.chainId === 5042002 && process.env.ARC_TESTNET_RPC_URL) return process.env.ARC_TESTNET_RPC_URL;
  return manifest.rpcUrl ?? DEFAULT_RPC_BY_CHAIN[manifest.chainId] ?? "";
}

async function assertManifest(path: string): Promise<void> {
  const manifest = JSON.parse(readFileSync(resolve(REPO_ROOT, path), "utf8")) as DeploymentManifest;
  const registry = manifestAddress(manifest, "FxMarketRegistry");
  const receiver = manifestAddress(manifest, "FxHubMessageReceiver");
  const liquidator = manifestAddress(manifest, "FxLiquidator");
  const rpc = rpcUrl(manifest);
  const expectedMinPools = Number(process.env.FXT_EXPECTED_MIN_POOLS ?? 2);

  if (!registry) throw new Error(`${path}: missing FxMarketRegistry`);
  if (!rpc) throw new Error(`${path}: missing RPC URL for chain ${manifest.chainId}`);

  const client = createPublicClient({
    chain: {
      id: manifest.chainId,
      name: manifest.network ?? String(manifest.chainId),
      nativeCurrency: { name: "Native", symbol: "NATIVE", decimals: 18 },
      rpcUrls: { default: { http: [rpc] } },
    },
    transport: http(rpc),
  });

  const code = await client.getBytecode({ address: registry });
  if (!code || code === "0x") throw new Error(`${path}: registry has no code at ${registry}`);

  await client.readContract({ address: registry, abi: FxMarketRegistryAbi, functionName: "DEFAULT_ADMIN_ROLE" });
  const paused = await client.readContract({ address: registry, abi: FxMarketRegistryAbi, functionName: "paused" });
  const pools = await client.readContract({ address: registry, abi: FxMarketRegistryAbi, functionName: "listPools" });
  if (pools.length < expectedMinPools) {
    throw new Error(`${path}: expected at least ${expectedMinPools} pools, got ${pools.length}`);
  }

  for (const pool of pools) {
    const marketId = await client.readContract({
      address: registry,
      abi: FxMarketRegistryAbi,
      functionName: "marketIdOf",
      args: [pool.loanToken, pool.collateralToken],
    });
    const isLive = await client.readContract({
      address: registry,
      abi: FxMarketRegistryAbi,
      functionName: "isPoolLive",
      args: [pool.loanToken, pool.collateralToken],
    });
    if (!isLive) {
      throw new Error(`${path}: pool ${marketId} is not live`);
    }
  }

  if (receiver) {
    const boundRegistry = await client.readContract({ address: receiver, abi: receiverAbi, functionName: "MARKET_REGISTRY" });
    if (boundRegistry.toLowerCase() !== registry.toLowerCase()) {
      throw new Error(`${path}: receiver ${receiver} points at ${boundRegistry}, expected ${registry}`);
    }
  }

  if (liquidator) {
    const boundRegistry = await client.readContract({ address: liquidator, abi: liquidatorAbi, functionName: "REGISTRY" });
    if (boundRegistry.toLowerCase() !== registry.toLowerCase()) {
      throw new Error(`${path}: liquidator ${liquidator} points at ${boundRegistry}, expected ${registry}`);
    }
  }

  console.log(
    JSON.stringify({
      manifest: path,
      chainId: manifest.chainId,
      registry,
      pools: pools.length,
      paused,
      receiver,
      liquidator,
    })
  );
}

const manifests = process.argv.slice(2);
let failed = false;
for (const manifest of manifests.length > 0 ? manifests : DEFAULT_MANIFESTS) {
  try {
    await assertManifest(manifest);
  } catch (error) {
    failed = true;
    console.error(
      JSON.stringify({
        manifest,
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      })
    );
  }
}
if (failed) {
  process.exit(1);
}
