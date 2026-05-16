// SPDX-License-Identifier: AGPL-3.0-only
import type { Address, TypedDataDomain } from "viem";

import { hubByChainId } from "./chains.js";
import { MAX_INTENT_DEADLINE_SECONDS } from "./constants.js";
import { FxTelaranaError } from "./errors.js";

type BaseIntentInput = {
  chainId: number;
  spokeChainId: number;
  loanToken: Address;
  collateralToken: Address;
  onBehalf: Address;
  nonce: bigint;
  deadline: number;
  now?: number;
};

export type FxTelaranaAction =
  | "Supply"
  | "Borrow"
  | "Repay"
  | "Withdraw"
  | "SupplyCollateral"
  | "WithdrawCollateral";

export const FX_TELARANA_INTENT_TYPES = {
  FxTelaranaSupplyIntent: [
    { name: "chainId", type: "uint256" },
    { name: "spokeChainId", type: "uint256" },
    { name: "loanToken", type: "address" },
    { name: "collateralToken", type: "address" },
    { name: "assets", type: "uint256" },
    { name: "onBehalf", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  FxTelaranaBorrowIntent: [
    { name: "chainId", type: "uint256" },
    { name: "spokeChainId", type: "uint256" },
    { name: "loanToken", type: "address" },
    { name: "collateralToken", type: "address" },
    { name: "borrowAssets", type: "uint256" },
    { name: "receiver", type: "address" },
    { name: "onBehalf", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  FxTelaranaRepayIntent: [
    { name: "chainId", type: "uint256" },
    { name: "spokeChainId", type: "uint256" },
    { name: "loanToken", type: "address" },
    { name: "collateralToken", type: "address" },
    { name: "assets", type: "uint256" },
    { name: "onBehalf", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  FxTelaranaWithdrawIntent: [
    { name: "chainId", type: "uint256" },
    { name: "spokeChainId", type: "uint256" },
    { name: "loanToken", type: "address" },
    { name: "collateralToken", type: "address" },
    { name: "shares", type: "uint256" },
    { name: "receiver", type: "address" },
    { name: "onBehalf", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  FxTelaranaCollateralIntent: [
    { name: "chainId", type: "uint256" },
    { name: "spokeChainId", type: "uint256" },
    { name: "loanToken", type: "address" },
    { name: "collateralToken", type: "address" },
    { name: "collateral", type: "uint256" },
    { name: "onBehalf", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export function assertDeadline(deadline: number, now = Math.floor(Date.now() / 1000)): void {
  if (deadline <= now) {
    throw new FxTelaranaError("Intent deadline is already expired", "INTENT_DEADLINE_EXPIRED", 400);
  }
  if (deadline - now > MAX_INTENT_DEADLINE_SECONDS) {
    throw new FxTelaranaError(
      `Intent deadline exceeds ${MAX_INTENT_DEADLINE_SECONDS}s gateway signer window`,
      "INTENT_DEADLINE_TOO_FAR",
      400
    );
  }
}

function domainFor(chainId: number): TypedDataDomain {
  const hub = hubByChainId(chainId);
  return {
    name: "FxTelaranaLending",
    version: "1",
    chainId,
    verifyingContract: hub.marketRegistry,
  };
}

function baseMessage(input: BaseIntentInput) {
  assertDeadline(input.deadline, input.now);
  return {
    chainId: BigInt(input.chainId),
    spokeChainId: BigInt(input.spokeChainId),
    loanToken: input.loanToken,
    collateralToken: input.collateralToken,
    onBehalf: input.onBehalf,
    nonce: input.nonce,
    deadline: BigInt(input.deadline),
  };
}

export function buildSupplyIntent(input: BaseIntentInput & { assets: bigint }) {
  return {
    domain: domainFor(input.chainId),
    types: { FxTelaranaSupplyIntent: FX_TELARANA_INTENT_TYPES.FxTelaranaSupplyIntent },
    primaryType: "FxTelaranaSupplyIntent" as const,
    message: { ...baseMessage(input), assets: input.assets },
  };
}

export function buildBorrowIntent(input: BaseIntentInput & { borrowAssets: bigint; receiver: Address }) {
  return {
    domain: domainFor(input.chainId),
    types: { FxTelaranaBorrowIntent: FX_TELARANA_INTENT_TYPES.FxTelaranaBorrowIntent },
    primaryType: "FxTelaranaBorrowIntent" as const,
    message: { ...baseMessage(input), borrowAssets: input.borrowAssets, receiver: input.receiver },
  };
}

export function buildRepayIntent(input: BaseIntentInput & { assets: bigint }) {
  return {
    domain: domainFor(input.chainId),
    types: { FxTelaranaRepayIntent: FX_TELARANA_INTENT_TYPES.FxTelaranaRepayIntent },
    primaryType: "FxTelaranaRepayIntent" as const,
    message: { ...baseMessage(input), assets: input.assets },
  };
}

export function buildWithdrawIntent(input: BaseIntentInput & { shares: bigint; receiver: Address }) {
  return {
    domain: domainFor(input.chainId),
    types: { FxTelaranaWithdrawIntent: FX_TELARANA_INTENT_TYPES.FxTelaranaWithdrawIntent },
    primaryType: "FxTelaranaWithdrawIntent" as const,
    message: { ...baseMessage(input), shares: input.shares, receiver: input.receiver },
  };
}

export function buildSupplyCollateralIntent(input: BaseIntentInput & { collateral: bigint }) {
  return {
    domain: domainFor(input.chainId),
    types: { FxTelaranaCollateralIntent: FX_TELARANA_INTENT_TYPES.FxTelaranaCollateralIntent },
    primaryType: "FxTelaranaCollateralIntent" as const,
    message: { ...baseMessage(input), collateral: input.collateral },
  };
}

export const buildWithdrawCollateralIntent = buildSupplyCollateralIntent;
