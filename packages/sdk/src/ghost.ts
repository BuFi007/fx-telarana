// SPDX-License-Identifier: Apache-2.0
import type { Address } from "viem";
import { EligibilityReason, type EligibilityResult } from "./eligibility.js";

export enum FxRouteMode {
  Public = "PUBLIC",
  Ghost = "GHOST",
}

export enum GhostAction {
  Supply = "SUPPLY",
  SupplyCollateral = "SUPPLY_COLLATERAL",
  Borrow = "BORROW",
  Repay = "REPAY",
  Withdraw = "WITHDRAW",
  Swap = "SWAP",
  CrossChainEnter = "CROSS_CHAIN_ENTER",
}

export interface BufiWalletPass {
  holder: Address;
  issuer: Address;
  level: "KYC" | "KYB";
  valid: boolean;
  expiresAt?: number;
}

export interface GhostRouteSupport {
  action: GhostAction;
  routeAddress?: Address;
  hookAddress?: Address;
  deployed: boolean;
}

export function resolveRouteMode(
  eligibility: EligibilityResult,
  requestedMode: FxRouteMode,
  route?: Pick<GhostRouteSupport, "deployed">,
): FxRouteMode {
  if (requestedMode !== FxRouteMode.Ghost) return FxRouteMode.Public;
  if (!eligibility.ghost || eligibility.reason !== EligibilityReason.OK) return FxRouteMode.Public;
  if (route && !route.deployed) return FxRouteMode.Public;
  return FxRouteMode.Ghost;
}
