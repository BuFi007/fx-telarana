// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";
import { privateKeyToAccount } from "viem/accounts";

import { ChainId } from "@fx-telarana/contracts";

import { FxTelaranaError } from "../errors.js";
import { MemoryNonceStore, nonceScope, verifyIntentSignature } from "../intent-verification.js";
import { buildSupplyIntent } from "../intents.js";

const USDC = "0x5425890298aed601595a70AB815c96711a31Bc65";
const EURC = "0x5E44db7996c682E92a960b65AC713a54AD815c6B";
const ALICE = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000001");
const BOB = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000002");

describe("intent verification", () => {
  test("verifies a signed supply intent against the expected wallet", async () => {
    const typedData = buildSupplyIntent({
      chainId: ChainId.AvalancheFuji,
      spokeChainId: ChainId.OpSepolia,
      loanToken: USDC,
      collateralToken: EURC,
      assets: 1_000_000n,
      onBehalf: ALICE.address,
      nonce: 0n,
      deadline: 1_000,
      now: 900,
    });
    const signature = await ALICE.signTypedData(typedData);

    await expect(verifyIntentSignature({ typedData, signature, signer: ALICE.address })).resolves.toBe(true);
    await expect(verifyIntentSignature({ typedData, signature, signer: BOB.address })).resolves.toBe(false);
  });

  test("enforces strictly increasing per-scope nonces", () => {
    const store = new MemoryNonceStore();
    const scope = nonceScope({
      chainId: ChainId.AvalancheFuji,
      action: "Supply",
      account: ALICE.address,
    });

    expect(store.peek(scope)).toBe(0n);
    store.assertAndConsume(scope, 0n);
    expect(store.peek(scope)).toBe(1n);
    expect(() => store.assertAndConsume(scope, 0n)).toThrow(FxTelaranaError);
  });
});
