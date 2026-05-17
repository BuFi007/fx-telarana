// SPDX-License-Identifier: AGPL-3.0-only
import { beforeEach, describe, expect, test } from "bun:test";
import { privateKeyToAccount } from "viem/accounts";

import app from "./index.js";
import { getIntent, resetIntentStoreForTests } from "./intent-store.js";

const ALICE = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000001");
const USDC = "0x5425890298aed601595a70AB815c96711a31Bc65";
const EURC = "0x5E44db7996c682E92a960b65AC713a54AD815c6B";

function supplyIntentBody(nonce = "0") {
  return {
    hubChainId: 43113,
    spokeChainId: 11155420,
    loanToken: USDC,
    collateralToken: EURC,
    assets: "1000000",
    onBehalf: ALICE.address,
    nonce,
    deadline: Math.floor(Date.now() / 1000) + 300,
  };
}

describe("api routes", () => {
  beforeEach(() => {
    resetIntentStoreForTests();
  });

  test("health returns ok", async () => {
    const res = await app.request("/health");
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toMatchObject({ ok: true });
  });

  test("rejects malformed supply quote body before live reads", async () => {
    const res = await app.request("/fx-telarana/supply/quote", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        hubChainId: 43113,
        loanToken: "not-an-address",
        collateralToken: "0x5E44db7996c682E92a960b65AC713a54AD815c6B",
        assets: "1000000",
      }),
    });
    expect(res.status).toBe(400);
  });

  test("premium routes require payment", async () => {
    const res = await app.request("/fx-telarana/liquidations/density");
    expect(res.status).toBe(402);
  });

  test("stores unsigned intents and verifies signatures with strict nonce consumption", async () => {
    const created = await app.request("/fx-telarana/supply/intents", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(supplyIntentBody()),
    });
    expect(created.status).toBe(201);
    const createdJson = (await created.json()) as { id: string };
    const intent = getIntent(createdJson.id);
    expect(intent?.status).toBe("unsigned");

    const signature = await ALICE.signTypedData(intent!.typedData as never);
    const verified = await app.request(`/fx-telarana/supply/intents/${createdJson.id}/signature`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ signer: ALICE.address, signature }),
    });
    expect(verified.status).toBe(200);
    await expect(verified.json()).resolves.toMatchObject({ status: "verified", signer: ALICE.address });

    const replayCreated = await app.request("/fx-telarana/supply/intents", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(supplyIntentBody()),
    });
    const replayIntent = getIntent(((await replayCreated.json()) as { id: string }).id)!;
    const replaySignature = await ALICE.signTypedData(replayIntent.typedData as never);
    const replay = await app.request(`/fx-telarana/supply/intents/${replayIntent.id}/signature`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ signer: ALICE.address, signature: replaySignature }),
    });
    expect(replay.status).toBe(409);
  });
});
