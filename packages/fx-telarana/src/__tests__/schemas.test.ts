// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import { quoteBorrowSchema } from "../schemas.js";

describe("route validators", () => {
  test("parses bigint amount strings", () => {
    const parsed = quoteBorrowSchema.parse({
      hubChainId: 43113,
      loanToken: "0x5425890298aed601595a70AB815c96711a31Bc65",
      collateralToken: "0x5E44db7996c682E92a960b65AC713a54AD815c6B",
      collateral: "1000000",
      borrowAmount: "500000",
    });

    expect(parsed.borrowAmount).toBe(500000n);
  });

  test("rejects malformed addresses", () => {
    expect(() =>
      quoteBorrowSchema.parse({
        hubChainId: 43113,
        loanToken: "not-an-address",
        collateralToken: "0x5E44db7996c682E92a960b65AC713a54AD815c6B",
        collateral: "1000000",
        borrowAmount: "500000",
      })
    ).toThrow();
  });
});
