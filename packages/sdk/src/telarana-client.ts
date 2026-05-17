// SPDX-License-Identifier: Apache-2.0
/**
 * Telarana — a single entry-point API client for the FX Telaraña Protocol.
 *
 * Hides the dual-spoke + dual-hub topology behind intent-based methods so
 * downstream consumers (BUFX, frontend POC, integrators) don't have to
 * reason about which hub they should land on or which spoke to call.
 *
 * Usage:
 *
 *   import { Telarana } from "@bu/fx-engine";
 *
 *   const client = new Telarana();
 *
 *   // "I want to lend or borrow — give me the right Fuji-routed spoke for Ethereum"
 *   const lend = client.route({ chain: ChainId.Sepolia, intent: "lend" });
 *
 *   // "I want to trade fast on Arc — give me the Arc-routed spoke for Ethereum"
 *   const trade = client.route({ chain: ChainId.Sepolia, intent: "trade" });
 *
 *   // Get full hub addresses (any consumer of the borrow/lend / liquidator surface)
 *   const fuji = client.hub("fuji");
 *
 *   // Gateway helpers (BUFX calls `hub.relayToRemoteHub` once whitelisted)
 *   const gw = client.gateway();
 *
 * Mental model:
 *   - Two hubs (Fuji = money market, Arc = HFT execution). Both are full
 *     Morpho-Blue lend/borrow stacks; Arc just has lower latency.
 *   - 16 spokes (8 chains × 2 routes per chain). User picks per intent.
 *   - Stage 6 plumbing on each hub bridges cross-hub USDC via Circle Gateway
 *     at the protocol level (never user-initiated).
 */
import type { Address } from "viem";

import { ChainId, addresses, type ChainIdValue, type FxAddresses } from "./addresses/index.js";
import {
  TELARANA_GATEWAY_HUB_ROUTES,
  TELARANA_GATEWAY_TESTNET_CHAINS,
  type GatewayHubRouteConfig,
  type CircleGatewayChainConfig,
} from "./gateway.js";

// ── HUB CANONICAL ADDRESSES ────────────────────────────────────────────────
// Current hub addresses. Kept in this file so the client doesn't have to read
// deployment JSON at runtime — these are the deployed truths.

const FUJI_HUB: HubAddresses = {
  name: "fuji",
  chainId: ChainId.AvalancheFuji,
  cctpDomain: 1,
  gatewayDomain: 1,
  receiver: "0xbBc9AE9dbd3F6D3dB672F0CA2419d0f4C8513062",
  hook: "0x1527f0230e07B202812A0F0E437995323A1a98cB",
  marketRegistry: "0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9",
  oracle: "0x4178F9D64F64eD05C25B0D6284f64522436A2a1F",
  liquidator: "0x113A539625D208b5EcC59f300Be14b9b3508E559",
  fxReceiptUSDC: "0x629144FDC1d0A6f9F2B12d9747557Cc508728739",
  fxReceiptEURC: "0x971b6ED14521f354eD13d64506Bf47D84E70F4fc",
  morphoBlue: "0xeF64621D41093144D9ED8aB8327eE381ECdB79E6",
  marketIds: {
    M1_EURC_USDC: "0x164ab95c126ae7f5227bc5026e66642ea05b41f3ab50d086704bc7f1dd6470a1",
    M2_USDC_EURC: "0x77bae5f5fb07741f0873c163edfa5573e7136cb690bb1deff35aa3e664a37a75",
  },
};

const ARC_HUB: HubAddresses = {
  name: "arc",
  chainId: ChainId.ArcTestnet,
  cctpDomain: 26,
  gatewayDomain: 26,
  receiver: "0xED8D2F831A8b7EbF7eb86a52323D23e2277F26b6",
  hook: "0x6a134214303136Ea8aa1cfA054Baf3ca74eCdad9",
  marketRegistry: "0x1126aA03E678f2bc87A936AA63Df972c7c338b8b",
  oracle: "0x217860736E626781f9AaA91731b307619f90f65B",
  liquidator: "0x4dB43e41420ACC39ee88dBc1cB868567968C0F12",
  fxReceiptUSDC: "0x9559A55Ea94aF58002a857f73B15c8EF4E850Fd8",
  fxReceiptEURC: "0x7926D3b1D1360632e81F811FE9a39866Fe16074F",
  morphoBlue: "0x3c9b95C6E7B23f094f066733E7797C8680760830",
  marketIds: {
    M1_EURC_USDC: "0x8c98b07503c850a4e3c8b0f214c6c36efae7b029e2a7a00489ff16716921d980",
    M2_USDC_EURC: "0x76f3a09ff7ce186a9184838eb6f9c13c8e89b1d87b2b2f438cc2844502c07f49",
  },
};

// ── SPOKE ROUTE TABLE ──────────────────────────────────────────────────────
// Map chainId → { fujiRoutedSpoke, arcRoutedSpoke }. Source: deployments/*.json
// routes block. Kept here for fast client-side resolution.

// Synced to deployments/<chain>.json `routes` blocks after the 2026-05-17
// canonical-Fuji-EURC receiver migration.
const SPOKES_BY_CHAIN: Record<ChainIdValue, { fuji?: Address; arc?: Address }> = {
  [ChainId.Sepolia]:            { fuji: "0xf4556f31cace9a80aa584059c81638a5cd344dde", arc: "0xabc638aad2c4cacfbab54b38101025789c261c05" },
  [ChainId.OpSepolia]:          { fuji: "0x2552e1027ff27a285635a9593825e3da8f25808b", arc: "0x50c4ba39caa7f56152d0df4914e1f6b907194992" },
  [ChainId.ArbitrumSepolia]:    { fuji: "0xaa875a68b0155da4bd6a528ee9e1137017d18b41", arc: "0x3f5d9b44aa1d59d26b20862d91533d60B32d9aFa" },
  [ChainId.PolygonAmoy]:        { fuji: "0x58c1a04bc4e25db2f8474c9df41907cffc894a4b", arc: "0x068cd7d70d37acfb58413422c584fc295c08db12" },
  [ChainId.UnichainSepolia]:    { fuji: "0x58c1a04bc4e25db2f8474c9df41907cffc894a4b", arc: "0x068cd7d70d37acfb58413422c584fc295c08db12" },
  [ChainId.WorldChainSepolia]:  { fuji: "0x2552e1027ff27a285635a9593825e3da8f25808b", arc: "0x50c4ba39caa7f56152d0df4914e1f6b907194992" },
  [ChainId.AvalancheFuji]:      { fuji: "0x6EC2197aC1c35Fbe64533101a3DFf081BD45Ed99", arc: "0x77b3A3B420dB98B01085b8C46a753Ed9879e2865" },
  [ChainId.ArcTestnet]:         { fuji: "0xf93834070e4e4e7ff0e161feca2aeba65c2c6a38", arc: "0xb7bda9e3a09c91be6e616b58e1d855850ff46aed" },
  [ChainId.BaseSepolia]:        {},
  [ChainId.LineaSepolia]:       {},
  [ChainId.EthereumMainnet]:    {},
  [ChainId.AvalancheMainnet]:   {},
};

// ── PUBLIC TYPES ───────────────────────────────────────────────────────────

export type HubName = "fuji" | "arc";

export type UserIntent = "lend" | "trade";

export interface HubAddresses {
  name: HubName;
  chainId: ChainIdValue;
  cctpDomain: number;
  gatewayDomain: number;
  receiver: Address;        // FxHubMessageReceiver (Stage 6, with relay surface)
  hook: Address;            // FxGatewayHook
  marketRegistry: Address;
  oracle: Address;
  liquidator: Address;
  fxReceiptUSDC: Address;
  fxReceiptEURC: Address;
  morphoBlue: Address;
  marketIds: {
    M1_EURC_USDC: `0x${string}`;
    M2_USDC_EURC: `0x${string}`;
  };
}

export interface RouteInfo {
  hub: HubAddresses;
  spoke: Address;
  cctpDomain: number;
  chain: ChainIdValue;
  intent: UserIntent;
  reasoning: string;
}

export interface GatewayInfo {
  wallet: Address;
  minter: Address;
  authority: Address;
  authorityType: "EOA" | "contract-1271";
  routes: readonly GatewayHubRouteConfig[];
  chains: readonly CircleGatewayChainConfig[];
}

// ── CLIENT ─────────────────────────────────────────────────────────────────

export class Telarana {
  /** Pick the right hub + spoke for a (chain, intent) pair. */
  route(opts: { chain: ChainIdValue; intent: UserIntent }): RouteInfo {
    const spokes = SPOKES_BY_CHAIN[opts.chain];
    if (!spokes) {
      throw new Error(`Telarana: no spoke configured for chainId ${opts.chain}`);
    }

    // Routing rule:
    //   lend  → land on Fuji (money-market substrate, deeper supply pools today)
    //   trade → land on Arc (sub-second finality, native USDC gas, HFT-friendly)
    // Both hubs run identical Morpho stacks, so lending IS possible on Arc too —
    // but we default lend → Fuji for consistency. Override by calling `routeExplicit`.
    if (opts.intent === "lend") {
      const spoke = spokes.fuji;
      if (!spoke) throw new Error(`Telarana: no Fuji-routed spoke on chainId ${opts.chain}`);
      return {
        hub: FUJI_HUB,
        spoke,
        cctpDomain: FUJI_HUB.cctpDomain,
        chain: opts.chain,
        intent: opts.intent,
        reasoning: "lend → Fuji hub (money-market substrate)",
      };
    }

    const spoke = spokes.arc;
    if (!spoke) throw new Error(`Telarana: no Arc-routed spoke on chainId ${opts.chain}`);
    return {
      hub: ARC_HUB,
      spoke,
      cctpDomain: ARC_HUB.cctpDomain,
      chain: opts.chain,
      intent: opts.intent,
      reasoning: "trade → Arc hub (sub-second finality + native USDC gas)",
    };
  }

  /** Explicitly pick a hub destination for a chain (overrides intent heuristic). */
  routeExplicit(opts: { chain: ChainIdValue; hub: HubName }): RouteInfo {
    const spokes = SPOKES_BY_CHAIN[opts.chain];
    if (!spokes) throw new Error(`Telarana: no spoke configured for chainId ${opts.chain}`);
    const hub = opts.hub === "fuji" ? FUJI_HUB : ARC_HUB;
    const spoke = opts.hub === "fuji" ? spokes.fuji : spokes.arc;
    if (!spoke) throw new Error(`Telarana: no ${opts.hub}-routed spoke on chainId ${opts.chain}`);
    return {
      hub,
      spoke,
      cctpDomain: hub.cctpDomain,
      chain: opts.chain,
      intent: opts.hub === "fuji" ? "lend" : "trade",
      reasoning: `explicit pick → ${opts.hub} hub`,
    };
  }

  /** Get full hub address book by name. */
  hub(name: HubName): HubAddresses {
    return name === "fuji" ? FUJI_HUB : ARC_HUB;
  }

  /** Get both hubs. */
  hubs(): { fuji: HubAddresses; arc: HubAddresses } {
    return { fuji: FUJI_HUB, arc: ARC_HUB };
  }

  /** Gateway primitives (BUFX + signer service use these). */
  gateway(): GatewayInfo {
    return {
      wallet: "0x0077777d7EBA4688BDeF3E311b846F25870A19B9",
      minter: "0x0022222ABE238Cc2C7Bb1f21003F0a260052475B",
      authority: "0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69",
      authorityType: "EOA",
      routes: TELARANA_GATEWAY_HUB_ROUTES,
      chains: TELARANA_GATEWAY_TESTNET_CHAINS,
    };
  }

  /** Raw per-chain address slice from `packages/sdk/src/addresses` — for SDK consumers that want everything. */
  chainAddresses(chainId: ChainIdValue): Partial<FxAddresses> {
    return addresses[chainId] ?? {};
  }

  /** All chains that have at least one spoke deployed. */
  supportedChains(): ChainIdValue[] {
    return (Object.entries(SPOKES_BY_CHAIN) as [string, { fuji?: Address; arc?: Address }][])
      .filter(([, v]) => v.fuji || v.arc)
      .map(([k]) => Number(k) as ChainIdValue);
  }

  /** Show both routes available from a chain (for UI route-pickers). */
  availableRoutes(chain: ChainIdValue): { fuji?: RouteInfo; arc?: RouteInfo } {
    const spokes = SPOKES_BY_CHAIN[chain];
    if (!spokes) return {};
    return {
      fuji: spokes.fuji ? this.routeExplicit({ chain, hub: "fuji" }) : undefined,
      arc:  spokes.arc  ? this.routeExplicit({ chain, hub: "arc"  }) : undefined,
    };
  }
}

/** Convenience singleton — `import { telarana } from "@bu/fx-engine"`. */
export const telarana = new Telarana();
