// SPDX-License-Identifier: Apache-2.0
import {
  encodeFunctionData,
  type Address,
  type Hex,
} from "viem";
import { FxMarketRegistryAbi, FxSpokeAbi } from "../abis/index.js";

export interface SupplyParams {
  loanToken: Address;
  collateralToken: Address;
  assets: bigint;
  onBehalf: Address;
}

export interface WithdrawParams {
  loanToken: Address;
  collateralToken: Address;
  shares: bigint;
  onBehalf: Address;
  receiver: Address;
}

export interface SupplyCollateralParams {
  loanToken: Address;
  collateralToken: Address;
  collateral: bigint;
  onBehalf: Address;
}

export interface BorrowParams {
  loanToken: Address;
  collateralToken: Address;
  assets: bigint;
  onBehalf: Address;
  receiver: Address;
}

export interface RepayParams {
  loanToken: Address;
  collateralToken: Address;
  assets: bigint;
  onBehalf: Address;
}

/// Build calldata to call `FxMarketRegistry.supply(...)`. Caller must approve
/// the registry to pull `assets` of `loanToken` before invoking.
export function planSupply(p: SupplyParams): Hex {
  return encodeFunctionData({
    abi: FxMarketRegistryAbi,
    functionName: "supply",
    args: [p.loanToken, p.collateralToken, p.assets, p.onBehalf],
  });
}

export function planWithdraw(p: WithdrawParams): Hex {
  return encodeFunctionData({
    abi: FxMarketRegistryAbi,
    functionName: "withdraw",
    args: [p.loanToken, p.collateralToken, p.shares, p.onBehalf, p.receiver],
  });
}

export function planSupplyCollateral(p: SupplyCollateralParams): Hex {
  return encodeFunctionData({
    abi: FxMarketRegistryAbi,
    functionName: "supplyCollateral",
    args: [p.loanToken, p.collateralToken, p.collateral, p.onBehalf],
  });
}

export function planBorrow(p: BorrowParams): Hex {
  return encodeFunctionData({
    abi: FxMarketRegistryAbi,
    functionName: "borrow",
    args: [p.loanToken, p.collateralToken, p.assets, p.onBehalf, p.receiver],
  });
}

export function planRepay(p: RepayParams): Hex {
  return encodeFunctionData({
    abi: FxMarketRegistryAbi,
    functionName: "repay",
    args: [p.loanToken, p.collateralToken, p.assets, p.onBehalf],
  });
}

/// Build calldata for `FxSpoke.enterHub`. The Hub-side `hubCalldata` is usually
/// the output of one of the `plan*` builders above, addressed at FxMarketRegistry
/// on Arc.
export interface EnterHubParams {
  token: Address;
  amount: bigint;
  beneficiary: Address;
  hubCalldata: Hex;
}

export function planEnterHub(p: EnterHubParams): Hex {
  return encodeFunctionData({
    abi: FxSpokeAbi,
    functionName: "enterHub",
    args: [p.token, p.amount, p.beneficiary, p.hubCalldata],
  });
}
