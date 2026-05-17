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
  receiver: "0x4FBe4cc4ab09648d65195f5B9490D20D12D49a2c",
  hook: "0x412f0CE9cb7697458dF3804d56de259c3e38371B",
  marketRegistry: "0xdB59d712a3cD19DccD98F5a245302a94d43f9A8c",
  oracle: "0x625e2870a94F67F575Ed82678C2c619994721D29",
  liquidator: "0x3DD99ace9ab896C613b47749e6Daae84ceF0433B",
  fxReceiptUSDC: "0x3b94E6A9Dc100CC390B56D1f0BB6a0B706ad3aAA",
  fxReceiptEURC: "0x8A88024AE640B26b082E5D01BF0BDea9e0F89f3d",
  morphoBlue: "0x3c9b95C6E7B23f094f066733E7797C8680760830",
  marketIds: {
    M1_EURC_USDC: "0xfd39280abf7d487fdacb075964282ef40cfbc05d29f3dd0de33fd106f999e321",
    M2_USDC_EURC: "0xcd92ddbcde6eac8b696f8f55cff1e0a397c43a10b9c5ea62d3a134333961853b",
    M1_AUDF_USDC: "0xdecc6eac359fccc90312bcc10d4e3f041b24499e6f5fc6c9b979c63ed3324827",
    M2_USDC_AUDF: "0x30b2b4f9a060a4106af7d648ee2997af663dba4a13a80bdaa3b7dcdd86ad024e",
    M1_JPYC_USDC: "0x45af7bde15cc90c3d746c5c33ffe8f841d9a13691d4b61b37488f0728c6d3c4b",
    M2_USDC_JPYC: "0x85bd7c3e24560aa9e9e92b38b343f30e7699bd40b5c8623a9da6dddb3fa37c61",
    M1_MXNB_USDC: "0x2a9537d6924829e4885754f4d5bc162540c85215edcd2a617e4b44237ceb5b03",
    M2_USDC_MXNB: "0x44cd73ea5727fab16c3f4eeb4e33d61e3679709ec026423a7cedd135b0fd2a9c",
    M1_KRW1_USDC: "0x9128daa773043c0356fd98ff060eef6cc149eca6efb55b147c600d62d170d379",
    M2_USDC_KRW1: "0x19a08dbc14b7db6dbe151ac2bdc5fb7490acc8e2f95ccb8eea768486c93b0b89",
    M1_ZCHF_USDC: "0x175e4e8d24841d73e51f118e6318e429ff9c772df512de1168a3b8f666647ae3",
    M2_USDC_ZCHF: "0xa900dd90f3d9e8de4546a2be44c54ff6d0ece155766cd4480e5ec9b20c2e98bb",
  },
};

// ── SPOKE ROUTE TABLE ──────────────────────────────────────────────────────
// Map chainId → { fujiRoutedSpoke, arcRoutedSpoke }. Source: deployments/*.json
// routes block. Kept here for fast client-side resolution.

// Synced to deployments/<chain>.json `routes` blocks after the 2026-05-17
// Fuji EURC and Arc basket receiver migrations.
const SPOKES_BY_CHAIN: Record<ChainIdValue, { fuji?: Address; arc?: Address }> = {
  [ChainId.Sepolia]:            { fuji: "0xf4556f31cace9a80aa584059c81638a5cd344dde", arc: "0xb912a78e5dbb0848501e1d643bda2193ec64aebc" },
  [ChainId.OpSepolia]:          { fuji: "0x2552e1027ff27a285635a9593825e3da8f25808b", arc: "0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b" },
  [ChainId.ArbitrumSepolia]:    { fuji: "0xaa875a68b0155da4bd6a528ee9e1137017d18b41", arc: "0xfa999ca0392523a915e6bbc0026825090ed1a207" },
  [ChainId.PolygonAmoy]:        { fuji: "0x58c1a04bc4e25db2f8474c9df41907cffc894a4b", arc: "0x71e85194f57338d854eabd158f0cd2c376b9f966" },
  [ChainId.UnichainSepolia]:    { fuji: "0x58c1a04bc4e25db2f8474c9df41907cffc894a4b", arc: "0x71e85194f57338d854eabd158f0cd2c376b9f966" },
  [ChainId.WorldChainSepolia]:  { fuji: "0x2552e1027ff27a285635a9593825e3da8f25808b", arc: "0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b" },
  [ChainId.AvalancheFuji]:      { fuji: "0x6EC2197aC1c35Fbe64533101a3DFf081BD45Ed99", arc: "0x225cca22879593b41c7dcceb9e961b7881061368" },
  [ChainId.ArcTestnet]:         { fuji: "0xf93834070e4e4e7ff0e161feca2aeba65c2c6a38", arc: "0x10b1ddc4a061991d44643893a24b754b8fc0dc98" },
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
  marketIds: Record<string, `0x${string}`> & {
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
