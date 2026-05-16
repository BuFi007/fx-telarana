// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import { ChainId } from "@fx-telarana/contracts";

import { MAX_INTENT_DEADLINE_SECONDS } from "../constants.js";
import { buildBorrowIntent, buildSupplyIntent } from "../intents.js";

const USDC = "0x5425890298aed601595a70AB815c96711a31Bc65";
const EURC = "0x5E44db7996c682E92a960b65AC713a54AD815c6B";
const ALICE = "0x000000000000000000000000000000000000a11c";

describe("EIP-712 intent builders", () => {
  test("builds unsigned supply typed data with hub verifying contract", () => {
    const typed = buildSupplyIntent({
      chainId: ChainId.AvalancheFuji,
      spokeChainId: ChainId.OpSepolia,
      loanToken: USDC,
      collateralToken: EURC,
      assets: 1_000_000n,
      onBehalf: ALICE,
      nonce: 1n,
      deadline: 1_000,
      now: 900,
    });

    expect(typed.primaryType).toBe("FxTelaranaSupplyIntent");
    expect(typed.domain.chainId).toBe(ChainId.AvalancheFuji);
    expect(typed.domain.verifyingContract).toBe("0x7ba745b979e027992ECFa51207666e3F5B46cF0a");
    expect(typed.message.assets).toBe(1_000_000n);
  });

  test("rejects deadlines past the signer window", () => {
    expect(() =>
      buildBorrowIntent({
        chainId: ChainId.AvalancheFuji,
        spokeChainId: ChainId.OpSepolia,
        loanToken: USDC,
        collateralToken: EURC,
        borrowAssets: 1_000_000n,
        receiver: ALICE,
        onBehalf: ALICE,
        nonce: 1n,
        deadline: 1_000 + MAX_INTENT_DEADLINE_SECONDS + 1,
        now: 1_000,
      })
    ).toThrow("gateway signer window");
  });
});
