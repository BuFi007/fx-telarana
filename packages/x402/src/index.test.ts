// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import { defaultReceiptVerifier } from "./index.js";

describe("x402 receipt verifier", () => {
  test("accepts a matching base64 receipt", async () => {
    const header = Buffer.from(
      JSON.stringify({ payer: "0xabc", amount: "0.01", network: "arc-testnet" })
    ).toString("base64");
    await expect(
      defaultReceiptVerifier({ header, endpoint: "borrow_with_sim", priceUsdc: "0.01" })
    ).resolves.toEqual({
      ok: true,
      receipt: { payer: "0xabc", amount: "0.01", network: "arc-testnet" },
    });
  });

  test("rejects amount mismatches", async () => {
    const header = Buffer.from(
      JSON.stringify({ payer: "0xabc", amount: "0.001", network: "arc-testnet" })
    ).toString("base64");
    await expect(
      defaultReceiptVerifier({ header, endpoint: "borrow_with_sim", priceUsdc: "0.01" })
    ).resolves.toEqual({ ok: false, reason: "receipt_amount_mismatch" });
  });
});
