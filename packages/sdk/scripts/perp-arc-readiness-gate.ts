#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, defineChain, http } from "viem";

import {
  assertFxPerpLiveReadiness,
  loadFxPerpRuntimeConfig,
} from "../src/perps-runtime.js";

const ARC_RPC_URL = process.env.ARC_RPC_URL ?? "https://rpc.testnet.arc.network";
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const PERP_CONFIG_PATH =
  process.env.ARC_PERP_CONFIG_PATH ?? resolve(REPO_ROOT, "deployments/perps-config-5042002.json");

const arcTestnet = defineChain({
  id: 5_042_002,
  name: "Arc Testnet",
  nativeCurrency: { name: "Arc Testnet Gas", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [ARC_RPC_URL] } },
});

const runtime = loadFxPerpRuntimeConfig({
  configPath: PERP_CONFIG_PATH,
  contractAddressesJson: process.env.CONTRACT_ADDRESSES_JSON,
});

const publicClient = createPublicClient({ chain: arcTestnet, transport: http(ARC_RPC_URL) });

const report = await assertFxPerpLiveReadiness(publicClient, runtime);

console.log("Arc Phase B-E perp readiness gate passed");
console.log(`source=${runtime.source}`);
console.log(`configPath=${runtime.configPath}`);
console.log(`chainId=${report.chainId}`);
console.log(`checkedContracts=${report.checkedContracts.length}`);
console.log(`checkedMarkets=${report.checkedMarkets.join(",")}`);
console.log(`protocolLiquidity=${report.protocolLiquidity}`);
console.log(`totalAccountMargin=${report.totalAccountMargin}`);
console.log(`marginUsdcBalance=${report.marginUsdcBalance}`);
