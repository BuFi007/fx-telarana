// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import app from "./index.js";

describe("api routes", () => {
  test("health returns ok", async () => {
    const res = await app.request("/health");
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toMatchObject({ ok: true });
  });

  test("validates supply quote body", async () => {
    const res = await app.request("/fx-telarana/supply/quote", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        hubChainId: 43113,
        loanToken: "0x5425890298aed601595a70AB815c96711a31Bc65",
        collateralToken: "0x5E44db7996c682E92a960b65AC713a54AD815c6B",
        assets: "1000000",
      }),
    });
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toMatchObject({ assets: "1000000" });
  });

  test("premium routes require payment", async () => {
    const res = await app.request("/fx-telarana/liquidations/density");
    expect(res.status).toBe(402);
  });
});
