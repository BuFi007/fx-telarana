// SPDX-License-Identifier: AGPL-3.0-only
import { getAddress, verifyTypedData, type Address, type Hex } from "viem";

import { FxTelaranaError } from "./errors.js";
import type { FxTelaranaAction, FxTelaranaIntentTypedData } from "./intents.js";

export async function verifyIntentSignature(args: {
  typedData: FxTelaranaIntentTypedData;
  signature: Hex;
  signer: Address;
}): Promise<boolean> {
  return verifyTypedData({
    address: args.signer,
    domain: args.typedData.domain,
    types: args.typedData.types,
    primaryType: args.typedData.primaryType,
    message: args.typedData.message,
    signature: args.signature,
  } as never);
}

export function nonceScope(args: {
  chainId: number | bigint;
  action: FxTelaranaAction;
  account: Address;
}): string {
  return `${args.chainId}:${args.action}:${getAddress(args.account).toLowerCase()}`;
}

export class MemoryNonceStore {
  readonly #nextByScope = new Map<string, bigint>();

  peek(scope: string): bigint {
    return this.#nextByScope.get(scope) ?? 0n;
  }

  assertAndConsume(scope: string, nonce: bigint): void {
    const expected = this.peek(scope);
    if (nonce !== expected) {
      throw new FxTelaranaError(
        `Invalid nonce ${nonce}; expected ${expected}`,
        "INTENT_NONCE_MISMATCH",
        409
      );
    }
    this.#nextByScope.set(scope, expected + 1n);
  }

  reset(scope: string, nextNonce = 0n): void {
    this.#nextByScope.set(scope, nextNonce);
  }
}
