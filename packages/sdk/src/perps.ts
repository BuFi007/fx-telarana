// SPDX-License-Identifier: Apache-2.0
import { isAddress, isHex, type Address, type Hex } from "viem";

import { ChainId, type ChainIdValue, type FxPerpsAddresses } from "./addresses/index.js";

export const FX_PERP_MARKET_KEYS = [
  "EURC_USDC",
  "TJPYC_USDC",
  "TMXNB_USDC",
  "TCHFC_USDC",
] as const;

export type FxPerpMarketKey = (typeof FX_PERP_MARKET_KEYS)[number];

export const FX_PERP_ROLE_KEYS = [
  "role_clearinghouse_admin",
  "role_clearinghouse_executorKeeper",
  "role_clearinghouse_liquidationEngine",
  "role_clearinghouse_orderSettlement",
  "role_funding_admin",
  "role_health_admin",
  "role_liquidation_admin",
  "role_margin_accountOperatorKeeper",
  "role_margin_admin",
  "role_margin_clearinghouse",
  "role_margin_funding",
  "role_margin_liquidation",
  "role_settlement_admin",
  "role_settlement_settlerKeeper",
] as const;

export type FxPerpRoleKey = (typeof FX_PERP_ROLE_KEYS)[number];

export interface FxPerpMarketManifest {
  key: FxPerpMarketKey;
  marketId: Hex;
  baseToken: Address;
  enabled: boolean;
  initialMarginBps: number;
  maintenanceMarginBps: number;
  tradingFeeBps: number;
  maxLeverageBps: number;
  maxOpenInterestUsd: bigint;
  maxSkewUsd: bigint;
  openInterestLong: bigint;
  openInterestShort: bigint;
  fundingEnabled: boolean;
  maxFundingRateBpsPerSecond: bigint;
  fundingVelocityBps: bigint;
}

export interface FxPerpConfigManifest {
  chainId: ChainIdValue;
  exportedBlockNumber: bigint;
  exportedBlockTimestamp: bigint;
  admin: Address;
  keeper: Address;
  usdc: Address;
  fxOracle: Address;
  addresses: FxPerpsAddresses;
  protocolLiquidity: bigint;
  totalAccountMargin: bigint;
  marginUsdcBalance: bigint;
  minProtocolLiquidity: bigint;
  liquidation: {
    bountyBps: number;
    bountyCap: bigint;
    flagDelay: bigint;
  };
  markets: Record<FxPerpMarketKey, FxPerpMarketManifest>;
  roles: Record<FxPerpRoleKey, boolean>;
}

export function parseFxPerpConfigManifest(input: unknown): FxPerpConfigManifest {
  const source = objectField(input, "manifest");
  const chainId = numberField(source, "chainId");
  if (chainId !== ChainId.ArcTestnet) {
    throw new Error(`Unsupported perps config chainId ${chainId}; expected Arc testnet ${ChainId.ArcTestnet}`);
  }

  const keeper = addressField(source, "keeper");
  const manifest: FxPerpConfigManifest = {
    chainId,
    exportedBlockNumber: bigintField(source, "exportedBlockNumber"),
    exportedBlockTimestamp: bigintField(source, "exportedBlockTimestamp"),
    admin: addressField(source, "admin"),
    keeper,
    usdc: addressField(source, "USDC"),
    fxOracle: addressField(source, "FxOracle"),
    addresses: {
      clearinghouse: addressField(source, "FxPerpClearinghouse"),
      marginAccount: addressField(source, "FxMarginAccount"),
      fundingEngine: addressField(source, "FxFundingEngine"),
      healthChecker: addressField(source, "FxHealthChecker"),
      liquidationEngine: addressField(source, "FxLiquidationEngine"),
      orderSettlement: addressField(source, "FxOrderSettlement"),
      keeperAdmin: keeper,
    },
    protocolLiquidity: bigintField(source, "protocolLiquidity"),
    totalAccountMargin: bigintField(source, "totalAccountMargin"),
    marginUsdcBalance: bigintField(source, "marginUsdcBalance"),
    minProtocolLiquidity: bigintField(source, "minProtocolLiquidity"),
    liquidation: {
      bountyBps: numberField(source, "liquidation_bountyBps"),
      bountyCap: bigintField(source, "liquidation_bountyCap"),
      flagDelay: bigintField(source, "liquidation_flagDelay"),
    },
    markets: {
      EURC_USDC: marketField(source, "EURC_USDC"),
      TJPYC_USDC: marketField(source, "TJPYC_USDC"),
      TMXNB_USDC: marketField(source, "TMXNB_USDC"),
      TCHFC_USDC: marketField(source, "TCHFC_USDC"),
    },
    roles: roleFields(source),
  };

  return manifest;
}

export function assertFxPerpConfigReady(manifest: FxPerpConfigManifest): void {
  const missingRoles = FX_PERP_ROLE_KEYS.filter((key) => !manifest.roles[key]);
  if (missingRoles.length !== 0) {
    throw new Error(`Perps config manifest has failing role checks: ${missingRoles.join(", ")}`);
  }
  const disabledMarkets = FX_PERP_MARKET_KEYS.filter((key) => {
    const market = manifest.markets[key];
    return !market.enabled || !market.fundingEnabled;
  });
  if (disabledMarkets.length !== 0) {
    throw new Error(`Perps config manifest has disabled market/funding checks: ${disabledMarkets.join(", ")}`);
  }
  if (manifest.protocolLiquidity < manifest.minProtocolLiquidity) {
    throw new Error(
      `Perps protocolLiquidity ${manifest.protocolLiquidity} below minimum ${manifest.minProtocolLiquidity}`,
    );
  }
  if (manifest.marginUsdcBalance < manifest.protocolLiquidity + manifest.totalAccountMargin) {
    throw new Error(
      `Perps margin USDC balance ${manifest.marginUsdcBalance} below ` +
        `protocolLiquidity + totalAccountMargin ${manifest.protocolLiquidity + manifest.totalAccountMargin}`,
    );
  }
}

export function fxPerpsAddressesFromConfigManifest(manifest: FxPerpConfigManifest): FxPerpsAddresses {
  return manifest.addresses;
}

export function fxPerpContractAddressesJson(manifest: FxPerpConfigManifest): string {
  return JSON.stringify({
    [manifest.chainId]: {
      FxPerpClearinghouse: manifest.addresses.clearinghouse,
      FxMarginAccount: manifest.addresses.marginAccount,
      FxFundingEngine: manifest.addresses.fundingEngine,
      FxHealthChecker: manifest.addresses.healthChecker,
      FxLiquidationEngine: manifest.addresses.liquidationEngine,
      FxOrderSettlement: manifest.addresses.orderSettlement,
    },
  });
}

export function getFxPerpMarket(
  manifest: FxPerpConfigManifest,
  marketKey: FxPerpMarketKey,
): FxPerpMarketManifest {
  return manifest.markets[marketKey];
}

function marketField(source: Record<string, unknown>, key: FxPerpMarketKey): FxPerpMarketManifest {
  return {
    key,
    marketId: hexField(source, `${key}_marketId`, 32),
    baseToken: addressField(source, `${key}_baseToken`),
    enabled: boolField(source, `${key}_enabled`),
    initialMarginBps: numberField(source, `${key}_initialMarginBps`),
    maintenanceMarginBps: numberField(source, `${key}_maintenanceMarginBps`),
    tradingFeeBps: numberField(source, `${key}_tradingFeeBps`),
    maxLeverageBps: numberField(source, `${key}_maxLeverageBps`),
    maxOpenInterestUsd: bigintField(source, `${key}_maxOpenInterestUsd`),
    maxSkewUsd: bigintField(source, `${key}_maxSkewUsd`),
    openInterestLong: bigintField(source, `${key}_openInterestLong`),
    openInterestShort: bigintField(source, `${key}_openInterestShort`),
    fundingEnabled: boolField(source, `${key}_fundingEnabled`),
    maxFundingRateBpsPerSecond: bigintField(source, `${key}_maxFundingRateBpsPerSecond`),
    fundingVelocityBps: bigintField(source, `${key}_fundingVelocityBps`),
  };
}

function roleFields(source: Record<string, unknown>): Record<FxPerpRoleKey, boolean> {
  return FX_PERP_ROLE_KEYS.reduce(
    (roles, key) => {
      roles[key] = boolField(source, key);
      return roles;
    },
    {} as Record<FxPerpRoleKey, boolean>,
  );
}

function objectField(input: unknown, label: string): Record<string, unknown> {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new Error(`${label} must be a JSON object`);
  }
  return input as Record<string, unknown>;
}

function addressField(source: Record<string, unknown>, key: string): Address {
  const value = stringField(source, key);
  if (!isAddress(value)) throw new Error(`${key} must be an EVM address`);
  return value;
}

function hexField(source: Record<string, unknown>, key: string, byteLength: number): Hex {
  const value = stringField(source, key);
  if (!isHex(value, { strict: true }) || value.length !== 2 + byteLength * 2) {
    throw new Error(`${key} must be ${byteLength} bytes of hex`);
  }
  return value;
}

function stringField(source: Record<string, unknown>, key: string): string {
  const value = source[key];
  if (typeof value !== "string") throw new Error(`${key} must be a string`);
  return value;
}

function boolField(source: Record<string, unknown>, key: string): boolean {
  const value = source[key];
  if (typeof value !== "boolean") throw new Error(`${key} must be a boolean`);
  return value;
}

function numberField(source: Record<string, unknown>, key: string): number {
  const value = source[key];
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${key} must be a non-negative safe integer`);
  }
  return value;
}

function bigintField(source: Record<string, unknown>, key: string): bigint {
  const value = source[key];
  if (typeof value === "bigint") {
    if (value < 0n) throw new Error(`${key} must be non-negative`);
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < 0) throw new Error(`${key} must be a non-negative safe integer`);
    return BigInt(value);
  }
  if (typeof value === "string" && /^\d+$/.test(value)) {
    return BigInt(value);
  }
  throw new Error(`${key} must be a non-negative integer`);
}
