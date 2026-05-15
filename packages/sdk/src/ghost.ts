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

export type Hex32 = `0x${string}`;

export type GhostPassLevel = 1 | 2;

export interface GhostSpokeRouteConfig {
  routeId: Hex32;
  token: Address;
  minPassLevel: GhostPassLevel;
  enabled: boolean;
  metadataRef: Hex32;
}

export interface GhostSpokeEntryRequest {
  routeId: Hex32;
  commitment: Hex32;
  token: Address;
  amount: bigint;
  beneficiary: Address;
  hubCalldata: `0x${string}`;
}

export interface GhostHookContext {
  account: Address;
  commitment: Hex32;
  nullifierHash?: Hex32;
}

export interface GhostWithdrawalRouteConfig {
  routeId: Hex32;
  token: Address;
  minPassLevel: GhostPassLevel;
  enabled: boolean;
  metadataRef: Hex32;
}

export interface GhostWithdrawalRequest {
  routeId: Hex32;
  root: Hex32;
  nullifierHash: Hex32;
  passAccount: Address;
  recipient: Address;
  token: Address;
  amount: bigint;
  metadataRef: Hex32;
  proof: `0x${string}`;
}

export const GHOST_MODE_EVENT_NAMES = [
  "GhostCommitmentRegistered",
  "GhostNullifierConsumed",
  "GhostSpokeEntered",
  "GhostRouteConfigured",
  "GhostWithdrawalRouteConfigured",
  "GhostWithdrawalCompleted",
] as const;

export const GHOST_MODE_INDEXER_SCHEMA = [
  {
    name: "GhostCommitmentRegistered",
    indexed: ["commitment", "routeId", "account"],
    data: ["beneficiary", "token", "amount", "metadataRef"],
  },
  {
    name: "GhostNullifierConsumed",
    indexed: ["nullifierHash", "consumer"],
    data: [],
  },
  {
    name: "GhostSpokeEntered",
    indexed: ["messageNonce", "routeId", "commitment"],
    data: ["account", "beneficiary", "token", "amount", "passLevel", "metadataRef"],
  },
  {
    name: "GhostRouteConfigured",
    indexed: ["routeId", "token"],
    data: ["minPassLevel", "enabled", "metadataRef"],
  },
  {
    name: "GhostWithdrawalRouteConfigured",
    indexed: ["routeId", "token"],
    data: ["minPassLevel", "enabled", "metadataRef"],
  },
  {
    name: "GhostWithdrawalCompleted",
    indexed: ["nullifierHash", "routeId", "recipient"],
    data: ["token", "amount", "passLevel", "root", "metadataRef"],
  },
] as const;

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
