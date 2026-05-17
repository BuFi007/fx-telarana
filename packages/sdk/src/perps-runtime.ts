// SPDX-License-Identifier: Apache-2.0
import { existsSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { parseAbi, type Address, type Hex, type PublicClient } from "viem";

import { ChainId, type FxPerpsAddresses } from "./addresses/index.js";
import {
  FX_PERP_MARKET_KEYS,
  type FxPerpConfigManifest,
  assertFxPerpConfigReady,
  fxPerpsAddressesFromConfigManifest,
  parseFxPerpConfigManifest,
} from "./perps.js";

export const DEFAULT_ARC_PERP_CONFIG_PATH = "deployments/perps-config-5042002.json";

export interface FxPerpRuntimeConfig {
  manifest?: FxPerpConfigManifest;
  addresses: FxPerpsAddresses;
  source: "manifest" | "contract-addresses-json";
  configPath?: string;
}

export interface LoadFxPerpRuntimeConfigOptions {
  cwd?: string;
  env?: Record<string, string | undefined>;
  configPath?: string;
  contractAddressesJson?: string;
  requireManifest?: boolean;
}

export interface FxPerpLiveReadinessReport {
  chainId: number;
  checkedContracts: Address[];
  checkedMarkets: string[];
  protocolLiquidity: bigint;
  totalAccountMargin: bigint;
  marginUsdcBalance: bigint;
}

const ZERO_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

const erc20Abi = parseAbi(["function balanceOf(address account) view returns (uint256)"]);

const accessControlAbi = parseAbi([
  "function hasRole(bytes32 role, address account) view returns (bool)",
]);

const clearinghouseAbi = parseAbi([
  "function USDC() view returns (address)",
  "function ORACLE() view returns (address)",
  "function marginAccount() view returns (address)",
  "function fundingEngine() view returns (address)",
  "function EXECUTOR_ROLE() view returns (bytes32)",
  "function ORDER_SETTLEMENT_ROLE() view returns (bytes32)",
  "function LIQUIDATION_ENGINE_ROLE() view returns (bytes32)",
  "function marketConfig(bytes32 marketId) view returns ((address baseToken,bool enabled,uint16 initialMarginBps,uint16 maintenanceMarginBps,uint16 tradingFeeBps,uint32 maxLeverageBps,uint256 maxOpenInterestUsd,uint256 maxSkewUsd))",
]);

const marginAbi = parseAbi([
  "function USDC() view returns (address)",
  "function fundingSettlementHook() view returns (address)",
  "function CLEARINGHOUSE_ROLE() view returns (bytes32)",
  "function ACCOUNT_OPERATOR_ROLE() view returns (bytes32)",
  "function protocolLiquidity() view returns (uint256)",
  "function totalAccountMargin() view returns (uint256)",
]);

const fundingAbi = parseAbi([
  "function CLEARINGHOUSE() view returns (address)",
  "function MARGIN() view returns (address)",
  "function fundingConfig(bytes32 marketId) view returns (bool enabled,uint256 maxFundingRateBpsPerSecond,uint256 fundingVelocityBps)",
]);

const healthAbi = parseAbi([
  "function CLEARINGHOUSE() view returns (address)",
  "function MARGIN() view returns (address)",
]);

const liquidationAbi = parseAbi([
  "function HEALTH() view returns (address)",
  "function CLEARINGHOUSE() view returns (address)",
  "function MARGIN() view returns (address)",
  "function liquidationConfig() view returns (uint16 bountyBps,uint256 bountyCap,uint256 flagDelay)",
]);

const settlementAbi = parseAbi([
  "function CLEARINGHOUSE() view returns (address)",
  "function SETTLER_ROLE() view returns (bytes32)",
]);

export function loadFxPerpRuntimeConfig(options: LoadFxPerpRuntimeConfigOptions = {}): FxPerpRuntimeConfig {
  const env = options.env ?? process.env;
  const requireManifest = options.requireManifest ?? true;
  const cwd = options.cwd ?? process.cwd();
  const rawConfigPath = options.configPath ?? env.ARC_PERP_CONFIG_PATH ?? DEFAULT_ARC_PERP_CONFIG_PATH;
  const configPath = resolveConfigPath(rawConfigPath, cwd, !options.configPath && !env.ARC_PERP_CONFIG_PATH);
  const contractAddressesJson = options.contractAddressesJson ?? env.CONTRACT_ADDRESSES_JSON;

  let manifest: FxPerpConfigManifest | undefined;
  if (existsSync(configPath)) {
    manifest = parseFxPerpConfigManifest(JSON.parse(readFileSync(configPath, "utf8")) as unknown);
    assertFxPerpConfigReady(manifest);
  } else if (options.configPath || env.ARC_PERP_CONFIG_PATH || requireManifest) {
    throw new Error(`Perps config manifest not found at ${configPath}`);
  }

  const contractAddresses = contractAddressesJson
    ? parseFxPerpContractAddressesJson(contractAddressesJson, manifest?.chainId ?? ChainId.ArcTestnet)
    : undefined;

  if (manifest && contractAddresses) {
    assertFxPerpAddressesMatch("CONTRACT_ADDRESSES_JSON", contractAddresses, manifest.addresses);
  }

  if (manifest) {
    return {
      manifest,
      addresses: fxPerpsAddressesFromConfigManifest(manifest),
      source: "manifest",
      configPath,
    };
  }

  if (contractAddresses) {
    return {
      addresses: contractAddresses,
      source: "contract-addresses-json",
    };
  }

  throw new Error("Perps runtime config requires ARC_PERP_CONFIG_PATH or CONTRACT_ADDRESSES_JSON");
}

export function parseFxPerpContractAddressesJson(
  rawJson: string,
  chainId: number = ChainId.ArcTestnet,
): FxPerpsAddresses {
  const parsed = JSON.parse(rawJson) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("CONTRACT_ADDRESSES_JSON must be a JSON object");
  }
  const chainConfig = (parsed as Record<string, unknown>)[String(chainId)];
  if (!chainConfig || typeof chainConfig !== "object" || Array.isArray(chainConfig)) {
    throw new Error(`CONTRACT_ADDRESSES_JSON missing chain ${chainId}`);
  }
  const source = chainConfig as Record<string, unknown>;
  return {
    clearinghouse: requiredAddressField(source, "FxPerpClearinghouse"),
    marginAccount: requiredAddressField(source, "FxMarginAccount"),
    fundingEngine: requiredAddressField(source, "FxFundingEngine"),
    healthChecker: requiredAddressField(source, "FxHealthChecker"),
    liquidationEngine: requiredAddressField(source, "FxLiquidationEngine"),
    orderSettlement: requiredAddressField(source, "FxOrderSettlement"),
    keeperAdmin: optionalAddressField(source, "keeperAdmin") ?? optionalAddressField(source, "keeper") ?? ZERO_ADDRESS,
  };
}

export function assertFxPerpAddressesMatch(label: string, actual: FxPerpsAddresses, expected: FxPerpsAddresses): void {
  const checks: Array<[keyof FxPerpsAddresses, Address | undefined, Address | undefined]> = [
    ["clearinghouse", actual.clearinghouse, expected.clearinghouse],
    ["marginAccount", actual.marginAccount, expected.marginAccount],
    ["fundingEngine", actual.fundingEngine, expected.fundingEngine],
    ["healthChecker", actual.healthChecker, expected.healthChecker],
    ["liquidationEngine", actual.liquidationEngine, expected.liquidationEngine],
    ["orderSettlement", actual.orderSettlement, expected.orderSettlement],
  ];
  for (const [key, actualValue, expectedValue] of checks) {
    if (!sameAddress(actualValue, expectedValue)) {
      throw new Error(`${label} ${key} ${actualValue} does not match manifest ${expectedValue}`);
    }
  }
}

export async function assertFxPerpLiveReadiness(
  client: PublicClient,
  runtimeOrManifest: FxPerpRuntimeConfig | FxPerpConfigManifest,
): Promise<FxPerpLiveReadinessReport> {
  const manifest = "addresses" in runtimeOrManifest && "source" in runtimeOrManifest
    ? runtimeOrManifest.manifest
    : runtimeOrManifest;
  if (!manifest) {
    throw new Error("Live perps readiness requires deployments/perps-config-5042002.json; CONTRACT_ADDRESSES_JSON is address-only");
  }
  assertFxPerpConfigReady(manifest);

  const chainId = await client.getChainId();
  if (chainId !== manifest.chainId) {
    throw new Error(`Perps readiness wrong chain ${chainId}; expected ${manifest.chainId}`);
  }

  const addresses = manifest.addresses;
  const checkedContracts = [
    addresses.clearinghouse,
    addresses.marginAccount,
    addresses.fundingEngine,
    addresses.healthChecker,
    addresses.liquidationEngine,
    addresses.orderSettlement,
  ];
  for (const address of checkedContracts) {
    const bytecode = await client.getBytecode({ address });
    if (!bytecode || bytecode === "0x") throw new Error(`Perps readiness missing bytecode at ${address}`);
  }

  await expectAddress(
    "clearinghouse.USDC",
    read(client, addresses.clearinghouse, clearinghouseAbi, "USDC"),
    manifest.usdc,
  );
  await expectAddress(
    "clearinghouse.ORACLE",
    read(client, addresses.clearinghouse, clearinghouseAbi, "ORACLE"),
    manifest.fxOracle,
  );
  await expectAddress(
    "clearinghouse.marginAccount",
    read(client, addresses.clearinghouse, clearinghouseAbi, "marginAccount"),
    addresses.marginAccount,
  );
  await expectAddress(
    "clearinghouse.fundingEngine",
    read(client, addresses.clearinghouse, clearinghouseAbi, "fundingEngine"),
    addresses.fundingEngine,
  );
  await expectAddress("margin.USDC", read(client, addresses.marginAccount, marginAbi, "USDC"), manifest.usdc);
  await expectAddress(
    "margin.fundingSettlementHook",
    read(client, addresses.marginAccount, marginAbi, "fundingSettlementHook"),
    addresses.clearinghouse,
  );
  await expectAddress(
    "funding.CLEARINGHOUSE",
    read(client, addresses.fundingEngine, fundingAbi, "CLEARINGHOUSE"),
    addresses.clearinghouse,
  );
  await expectAddress("funding.MARGIN", read(client, addresses.fundingEngine, fundingAbi, "MARGIN"), addresses.marginAccount);
  await expectAddress(
    "health.CLEARINGHOUSE",
    read(client, addresses.healthChecker, healthAbi, "CLEARINGHOUSE"),
    addresses.clearinghouse,
  );
  await expectAddress("health.MARGIN", read(client, addresses.healthChecker, healthAbi, "MARGIN"), addresses.marginAccount);
  await expectAddress(
    "liquidation.HEALTH",
    read(client, addresses.liquidationEngine, liquidationAbi, "HEALTH"),
    addresses.healthChecker,
  );
  await expectAddress(
    "liquidation.CLEARINGHOUSE",
    read(client, addresses.liquidationEngine, liquidationAbi, "CLEARINGHOUSE"),
    addresses.clearinghouse,
  );
  await expectAddress(
    "liquidation.MARGIN",
    read(client, addresses.liquidationEngine, liquidationAbi, "MARGIN"),
    addresses.marginAccount,
  );
  await expectAddress(
    "settlement.CLEARINGHOUSE",
    read(client, addresses.orderSettlement, settlementAbi, "CLEARINGHOUSE"),
    addresses.clearinghouse,
  );

  await verifyRoles(client, manifest);
  await verifyMarketsAndFunding(client, manifest);
  await verifyLiquidation(client, manifest);

  const protocolLiquidity = await readBigint(client, addresses.marginAccount, marginAbi, "protocolLiquidity");
  const totalAccountMargin = await readBigint(client, addresses.marginAccount, marginAbi, "totalAccountMargin");
  const marginUsdcBalance = await readBigint(client, manifest.usdc, erc20Abi, "balanceOf", [addresses.marginAccount]);
  if (protocolLiquidity < manifest.minProtocolLiquidity) {
    throw new Error(`Perps protocolLiquidity ${protocolLiquidity} below minimum ${manifest.minProtocolLiquidity}`);
  }
  if (marginUsdcBalance < protocolLiquidity + totalAccountMargin) {
    throw new Error(
      `Perps margin USDC balance ${marginUsdcBalance} below protocolLiquidity + totalAccountMargin ${protocolLiquidity + totalAccountMargin}`,
    );
  }

  return {
    chainId,
    checkedContracts,
    checkedMarkets: [...FX_PERP_MARKET_KEYS],
    protocolLiquidity,
    totalAccountMargin,
    marginUsdcBalance,
  };
}

async function verifyRoles(client: PublicClient, manifest: FxPerpConfigManifest): Promise<void> {
  const { addresses, admin, keeper } = manifest;
  await expectRole(client, "clearinghouse.admin", addresses.clearinghouse, ZERO_ROLE, admin);
  await expectRole(client, "margin.admin", addresses.marginAccount, ZERO_ROLE, admin);
  await expectRole(client, "funding.admin", addresses.fundingEngine, ZERO_ROLE, admin);
  await expectRole(client, "health.admin", addresses.healthChecker, ZERO_ROLE, admin);
  await expectRole(client, "liquidation.admin", addresses.liquidationEngine, ZERO_ROLE, admin);
  await expectRole(client, "settlement.admin", addresses.orderSettlement, ZERO_ROLE, admin);

  const marginClearinghouseRole = await readHex(client, addresses.marginAccount, marginAbi, "CLEARINGHOUSE_ROLE");
  const marginAccountOperatorRole = await readHex(client, addresses.marginAccount, marginAbi, "ACCOUNT_OPERATOR_ROLE");
  const clearinghouseExecutorRole = await readHex(client, addresses.clearinghouse, clearinghouseAbi, "EXECUTOR_ROLE");
  const clearinghouseOrderSettlementRole =
    await readHex(client, addresses.clearinghouse, clearinghouseAbi, "ORDER_SETTLEMENT_ROLE");
  const clearinghouseLiquidationRole =
    await readHex(client, addresses.clearinghouse, clearinghouseAbi, "LIQUIDATION_ENGINE_ROLE");
  const settlementSettlerRole = await readHex(client, addresses.orderSettlement, settlementAbi, "SETTLER_ROLE");

  await expectRole(client, "margin.clearinghouse", addresses.marginAccount, marginClearinghouseRole, addresses.clearinghouse);
  await expectRole(client, "margin.funding", addresses.marginAccount, marginClearinghouseRole, addresses.fundingEngine);
  await expectRole(client, "margin.liquidation", addresses.marginAccount, marginClearinghouseRole, addresses.liquidationEngine);
  await expectRole(client, "margin.accountOperatorKeeper", addresses.marginAccount, marginAccountOperatorRole, keeper);
  await expectRole(
    client,
    "clearinghouse.orderSettlement",
    addresses.clearinghouse,
    clearinghouseOrderSettlementRole,
    addresses.orderSettlement,
  );
  await expectRole(
    client,
    "clearinghouse.liquidationEngine",
    addresses.clearinghouse,
    clearinghouseLiquidationRole,
    addresses.liquidationEngine,
  );
  await expectRole(client, "clearinghouse.executorKeeper", addresses.clearinghouse, clearinghouseExecutorRole, keeper);
  await expectRole(client, "settlement.settlerKeeper", addresses.orderSettlement, settlementSettlerRole, keeper);
}

async function verifyMarketsAndFunding(client: PublicClient, manifest: FxPerpConfigManifest): Promise<void> {
  for (const key of FX_PERP_MARKET_KEYS) {
    const expected = manifest.markets[key];
    const market = await read(client, manifest.addresses.clearinghouse, clearinghouseAbi, "marketConfig", [expected.marketId]);
    expectTupleAddress(`${key}.baseToken`, market, "baseToken", 0, expected.baseToken);
    expectTupleBool(`${key}.enabled`, market, "enabled", 1, expected.enabled);
    expectTupleBigint(`${key}.initialMarginBps`, market, "initialMarginBps", 2, BigInt(expected.initialMarginBps));
    expectTupleBigint(`${key}.maintenanceMarginBps`, market, "maintenanceMarginBps", 3, BigInt(expected.maintenanceMarginBps));
    expectTupleBigint(`${key}.tradingFeeBps`, market, "tradingFeeBps", 4, BigInt(expected.tradingFeeBps));
    expectTupleBigint(`${key}.maxLeverageBps`, market, "maxLeverageBps", 5, BigInt(expected.maxLeverageBps));
    expectTupleBigint(`${key}.maxOpenInterestUsd`, market, "maxOpenInterestUsd", 6, expected.maxOpenInterestUsd);
    expectTupleBigint(`${key}.maxSkewUsd`, market, "maxSkewUsd", 7, expected.maxSkewUsd);

    const funding = await read(client, manifest.addresses.fundingEngine, fundingAbi, "fundingConfig", [expected.marketId]);
    expectTupleBool(`${key}.funding.enabled`, funding, "enabled", 0, expected.fundingEnabled);
    expectTupleBigint(
      `${key}.funding.maxFundingRateBpsPerSecond`,
      funding,
      "maxFundingRateBpsPerSecond",
      1,
      expected.maxFundingRateBpsPerSecond,
    );
    expectTupleBigint(`${key}.funding.fundingVelocityBps`, funding, "fundingVelocityBps", 2, expected.fundingVelocityBps);
  }
}

async function verifyLiquidation(client: PublicClient, manifest: FxPerpConfigManifest): Promise<void> {
  const liquidation = await read(client, manifest.addresses.liquidationEngine, liquidationAbi, "liquidationConfig");
  expectTupleBigint("liquidation.bountyBps", liquidation, "bountyBps", 0, BigInt(manifest.liquidation.bountyBps));
  expectTupleBigint("liquidation.bountyCap", liquidation, "bountyCap", 1, manifest.liquidation.bountyCap);
  expectTupleBigint("liquidation.flagDelay", liquidation, "flagDelay", 2, manifest.liquidation.flagDelay);
}

async function expectRole(
  client: PublicClient,
  label: string,
  target: Address,
  role: Hex,
  account: Address,
): Promise<void> {
  const hasRole = await read(client, target, accessControlAbi, "hasRole", [role, account]);
  if (hasRole !== true) throw new Error(`Perps readiness missing role ${label} for ${account}`);
}

async function expectAddress(label: string, actualPromise: Promise<unknown>, expected: Address): Promise<void> {
  const actual = await actualPromise;
  if (typeof actual !== "string" || !sameAddress(actual as Address, expected)) {
    throw new Error(`${label} ${String(actual)} does not match expected ${expected}`);
  }
}

async function readBigint(
  client: PublicClient,
  address: Address,
  abi: ReturnType<typeof parseAbi>,
  functionName: string,
  args: readonly unknown[] = [],
): Promise<bigint> {
  const value = await read(client, address, abi, functionName, args);
  if (typeof value !== "bigint") throw new Error(`${functionName} returned non-bigint ${String(value)}`);
  return value;
}

async function readHex(
  client: PublicClient,
  address: Address,
  abi: ReturnType<typeof parseAbi>,
  functionName: string,
): Promise<Hex> {
  const value = await read(client, address, abi, functionName);
  if (typeof value !== "string" || !value.startsWith("0x")) {
    throw new Error(`${functionName} returned non-hex ${String(value)}`);
  }
  return value as Hex;
}

async function read(
  client: PublicClient,
  address: Address,
  abi: ReturnType<typeof parseAbi>,
  functionName: string,
  args: readonly unknown[] = [],
): Promise<unknown> {
  return (client as unknown as { readContract(input: unknown): Promise<unknown> }).readContract({
    address,
    abi,
    functionName,
    args,
  });
}

function expectTupleAddress(label: string, tuple: unknown, key: string, index: number, expected: Address): void {
  const actual = tupleField(tuple, key, index);
  if (typeof actual !== "string" || !sameAddress(actual as Address, expected)) {
    throw new Error(`${label} ${String(actual)} does not match expected ${expected}`);
  }
}

function expectTupleBool(label: string, tuple: unknown, key: string, index: number, expected: boolean): void {
  const actual = tupleField(tuple, key, index);
  if (actual !== expected) throw new Error(`${label} ${String(actual)} does not match expected ${expected}`);
}

function expectTupleBigint(label: string, tuple: unknown, key: string, index: number, expected: bigint): void {
  const actual = tupleField(tuple, key, index);
  const actualBigint = integerToBigint(actual);
  if (actualBigint !== expected) {
    throw new Error(`${label} ${String(actual)} does not match expected ${expected}`);
  }
}

function integerToBigint(value: unknown): bigint {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return BigInt(value);
  throw new Error(`Expected non-negative integer, got ${String(value)}`);
}

function tupleField(tuple: unknown, key: string, index: number): unknown {
  if (Array.isArray(tuple)) return tuple[index];
  if (tuple && typeof tuple === "object") return (tuple as Record<string, unknown>)[key];
  throw new Error(`Expected tuple object for ${key}`);
}

function requiredAddressField(source: Record<string, unknown>, key: string): Address {
  const value = optionalAddressField(source, key);
  if (value === undefined) throw new Error(`${key} must be an EVM address`);
  return value;
}

function optionalAddressField(source: Record<string, unknown>, key: string): Address | undefined {
  const value = source[key];
  if (value === undefined) return undefined;
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(value)) {
    throw new Error(`${key} must be an EVM address`);
  }
  return value as Address;
}

function sameAddress(a: Address | undefined, b: Address | undefined): boolean {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

function resolveConfigPath(rawPath: string, cwd: string, allowFindUp: boolean): string {
  const candidate = isAbsolute(rawPath) ? rawPath : resolve(cwd, rawPath);
  if (existsSync(candidate) || !allowFindUp) return candidate;

  let current = resolve(cwd);
  for (;;) {
    const found = resolve(current, DEFAULT_ARC_PERP_CONFIG_PATH);
    if (existsSync(found)) return found;
    const parent = dirname(current);
    if (parent === current) return candidate;
    current = parent;
  }
}
