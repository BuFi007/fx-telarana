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
// Stage 6 (post-relay surface). Kept in this file so the client doesn't
// have to read deployment JSON at runtime — these are the deployed truths.

const FUJI_HUB: HubAddresses = {
  name: "fuji",
  chainId: ChainId.AvalancheFuji,
  cctpDomain: 1,
  gatewayDomain: 1,
  receiver: "0x7eAdfD0c08dd6544f763285bBD31be14179d594B",
  hook: "0x7dA191bfB85D9F14069228cf618519BFb41f371E",
  marketRegistry: "0x7ba745b979e027992ECFa51207666e3F5B46cF0a",
  oracle: "0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b",
  liquidator: "0x2900599ff0e6dd057493d62fac856e5a8f93c6eb",
  fxReceiptUSDC: "0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e",
  fxReceiptEURC: "0xefd7cf5ad5a2db9a3c23e2807f2279de92c730d2",
  morphoBlue: "0xeF64621D41093144D9ED8aB8327eE381ECdB79E6",
  marketIds: {
    M1_EURC_USDC: "0x7d99088a9fe61331c49a92eb16fa3794b0bc2862b211f5a70f31a64cef25029e",
    M2_USDC_EURC: "0x1700104cf29eceb113e01a1bcdc913e5e10d3d37314cee235752aa88bf153197",
  },
};

const ARC_HUB: HubAddresses = {
  name: "arc",
  chainId: ChainId.ArcTestnet,
  cctpDomain: 26,
  gatewayDomain: 26,
  receiver: "0x44B50E93eCC7775aF99bcd04c30e1A00da80F63C",
  hook: "0x2931C50745334d6DFf9eC4E3106fE05b49717DF1",
  marketRegistry: "0x813232259c9b922e7571F15220617C80581f1464",
  oracle: "0x77b3A3B420dB98B01085b8C46a753Ed9879e2865",
  liquidator: "0xa50f7D4D4a1A0D3CF418515973545b80E037B379",
  fxReceiptUSDC: "0xdd22365Bba7330BE537c9BC26da9b1b4Db9aC431",
  fxReceiptEURC: "0xF829f57Db8530fa93FCD6e13b00193cbe8cE1493",
  morphoBlue: "0x3c9b95C6E7B23f094f066733E7797C8680760830",
  marketIds: {
    M1_EURC_USDC: "0xf6fac2b9b801a7ae3deeccfa95a7f1e768b4873a22f0def0d93f7f0172cc2da2",
    M2_USDC_EURC: "0x9e187a5f252de56b9ffe35f72cdc4137568f9d51698560751cdaff3df60cb5d3",
  },
};

// ── SPOKE ROUTE TABLE ──────────────────────────────────────────────────────
// Map chainId → { fujiRoutedSpoke, arcRoutedSpoke }. Source: deployments/*.json
// routes block. Kept here for fast client-side resolution.

// Synced to deployments/<chain>.json `routes` blocks as of 2026-05-15 (Stage 6
// post-migration). Codex adversarial-review v3 round 5 finding: every Fuji
// entry had drifted to pre-migration spoke addresses. Source-of-truth audit
// via `jq -r '.routes' deployments/*.json` confirms every value below.
const SPOKES_BY_CHAIN: Record<ChainIdValue, { fuji?: Address; arc?: Address }> = {
  [ChainId.Sepolia]:            { fuji: "0xf6d845da2051183b9519ca1806c39040ba5e71ba", arc: "0x4e63954685241c4469f02fec3761ff1d4f34ffa9" },
  [ChainId.OpSepolia]:          { fuji: "0x0b5d18bbe92f07ec0111ae6d2e102858268d6aca", arc: "0x579fccdebb1f7e983c4ead27aa300d3b5397e28c" },
  [ChainId.ArbitrumSepolia]:    { fuji: "0x2900599ff0e6dd057493d62fac856e5a8f93c6eb", arc: "0x365de300dda61c81a33bce3606a5d524ed964362" },
  [ChainId.PolygonAmoy]:        { fuji: "0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b", arc: "0x7882d3f0e210128a4dce51e1af1ec801e21e1e5a" },
  [ChainId.UnichainSepolia]:    { fuji: "0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b", arc: "0x7882d3f0e210128a4dce51e1af1ec801e21e1e5a" },
  [ChainId.WorldChainSepolia]:  { fuji: "0x0b5d18bbe92f07ec0111ae6d2e102858268d6aca", arc: "0x579fccdebb1f7e983c4ead27aa300d3b5397e28c" },
  [ChainId.AvalancheFuji]:      { fuji: "0xb7fc291c27f6a7a659d4d229e5d8a55e58f26ab1", arc: "0xe22ef07a0996df9ae6252cc9bf491fbe13fd6575" },
  [ChainId.ArcTestnet]:         { fuji: "0x13c8463589d460db6f21235eedfd678c22a1ea25", arc: "0x5d10d2c3b9951054845534b2f60a68ebc0898cd3" },
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
