// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import { ChainId } from "@fx-telarana/contracts";
import type { LendingMarket } from "@fx-telarana/core";

import { buildInternalDefiLlamaPayload } from "./internal.js";

describe("internal DefiLlama payload", () => {
  test("reports net TVL and borrowed separately", () => {
    const token = "0x0000000000000000000000000000000000000001";
    const payload = buildInternalDefiLlamaPayload([
      {
        id: "0xabc0000000000000000000000000000000000000000000000000000000000000",
        hubChainId: ChainId.AvalancheFuji,
        hubName: "fuji",
        loanToken: token,
        collateralToken: "0x0000000000000000000000000000000000000002",
        oracle: "0x0000000000000000000000000000000000000003",
        irm: "0x0000000000000000000000000000000000000004",
        lltv: 860_000_000_000_000_000n,
        isLive: true,
        state: {
          totalSupplyAssets: 100n,
          totalSupplyShares: 100n,
          totalBorrowAssets: 40n,
          totalBorrowShares: 40n,
          lastUpdate: 1n,
          fee: 0n,
        },
      } satisfies LendingMarket,
    ]);

    expect(payload.tvl[token]).toBe("60");
    expect(payload.borrowed[token]).toBe("40");
  });
});
