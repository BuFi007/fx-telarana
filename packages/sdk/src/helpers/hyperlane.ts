// SPDX-License-Identifier: Apache-2.0
import {
  encodeFunctionData,
  getAddress,
  isAddress,
  type Address,
  type Hex,
} from "viem";
import {
  FxHyperlaneHubReceiverAbi,
  FxSpokeIntentRouterAbi,
  HyperlaneInterchainAccountRouterAbi,
  HyperlaneWarpRouteAbi,
} from "../abis/index.js";

export interface HyperlaneWarpTransferParams {
  destinationDomain: number;
  recipient: Address | Hex;
  amount: bigint;
}

export interface HyperlaneIcaCall {
  to: Address | Hex;
  value?: bigint;
  data: Hex;
}

export interface HyperlaneIcaCallRemoteParams {
  destinationDomain: number;
  calls: readonly HyperlaneIcaCall[];
}

export const FxHyperlaneAction = {
  Supply: 0,
  SupplyCollateral: 1,
  Repay: 2,
  Borrow: 3,
} as const;

export type FxHyperlaneAction = (typeof FxHyperlaneAction)[keyof typeof FxHyperlaneAction];

export interface FxSpokeIntentParams {
  action: FxHyperlaneAction;
  beneficiary: Address;
  inputToken: Address;
  inputAmount: bigint;
  loanToken: Address;
  collateralToken: Address;
  route: Address;
}

/// Hyperlane EVM addresses are encoded as left-padded bytes32 for cross-VM
/// compatibility.
export function hyperlaneAddressToBytes32(value: Address | Hex): Hex {
  if (isAddress(value)) {
    return `0x${getAddress(value).slice(2).toLowerCase().padStart(64, "0")}` as Hex;
  }
  if (/^0x[0-9a-fA-F]{64}$/.test(value)) return value as Hex;
  throw new Error("invalid Hyperlane bytes32 address");
}

export function planHyperlaneWarpTransferRemote(p: HyperlaneWarpTransferParams): Hex {
  return encodeFunctionData({
    abi: HyperlaneWarpRouteAbi,
    functionName: "transferRemote",
    args: [
      p.destinationDomain,
      hyperlaneAddressToBytes32(p.recipient),
      p.amount,
    ],
  });
}

export function planHyperlaneIcaCallRemote(p: HyperlaneIcaCallRemoteParams): Hex {
  return encodeFunctionData({
    abi: HyperlaneInterchainAccountRouterAbi,
    functionName: "callRemote",
    args: [
      p.destinationDomain,
      p.calls.map((call) => ({
        to: hyperlaneAddressToBytes32(call.to),
        value: call.value ?? 0n,
        data: call.data,
      })),
    ],
  });
}

export function planFxSpokeIntent(p: FxSpokeIntentParams): Hex {
  return encodeFunctionData({
    abi: FxSpokeIntentRouterAbi,
    functionName: "sendIntent",
    args: [
      p.action,
      p.beneficiary,
      p.inputToken,
      p.inputAmount,
      p.loanToken,
      p.collateralToken,
      p.route,
    ],
  });
}

export function planExecuteHyperlaneIntent(intentId: Hex): Hex {
  return encodeFunctionData({
    abi: FxHyperlaneHubReceiverAbi,
    functionName: "executeIntent",
    args: [intentId],
  });
}
