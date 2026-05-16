// SPDX-License-Identifier: AGPL-3.0-only
import { createConfig } from "ponder";
import { http } from "viem";

import { ChainId, FxMarketRegistryAbi, MorphoBlueAbi, telarana } from "@fx-telarana/contracts";

const databaseUrl = process.env.DATABASE_PRIVATE_URL ?? process.env.DATABASE_URL;
const database = databaseUrl
  ? { kind: "postgres" as const, connectionString: databaseUrl }
  : { kind: "pglite" as const, directory: process.env.PONDER_PGLITE_DIR ?? ".ponder/pglite" };

const hubs = telarana.hubs();

export default createConfig({
  database,
  chains: {
    fuji: {
      id: ChainId.AvalancheFuji,
      rpc: http(
        process.env.FUJI_RPC_URL ??
          process.env.MARKET_DATA_RPC_URL ??
          "https://api.avax-test.network/ext/bc/C/rpc"
      ),
    },
    arc: {
      id: ChainId.ArcTestnet,
      rpc: http(process.env.ARC_RPC_URL ?? process.env.MARKET_DATA_RPC_URL ?? "https://rpc.testnet.arc.network"),
    },
  },
  contracts: {
    FxMarketRegistry: {
      chain: {
        fuji: { address: hubs.fuji.marketRegistry, startBlock: Number(process.env.FUJI_MARKET_START_BLOCK ?? 0) },
        arc: { address: hubs.arc.marketRegistry, startBlock: Number(process.env.ARC_MARKET_START_BLOCK ?? 0) },
      },
      abi: FxMarketRegistryAbi,
    },
    MorphoBlue: {
      chain: {
        fuji: { address: hubs.fuji.morphoBlue, startBlock: Number(process.env.FUJI_MARKET_START_BLOCK ?? 0) },
        arc: { address: hubs.arc.morphoBlue, startBlock: Number(process.env.ARC_MARKET_START_BLOCK ?? 0) },
      },
      abi: MorphoBlueAbi,
    },
  },
});
