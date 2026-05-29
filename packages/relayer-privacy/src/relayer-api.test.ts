// SPDX-License-Identifier: AGPL-3.0-only
//
// Tests for the cross-currency relayer API. Exercises the pure logic
// (request validation + rate limiter) without standing up an HTTP
// server or hitting an RPC.

import { describe, expect, test } from "bun:test";

import { RateLimiter, validateRequest, validateRelayRequest } from "./relayer-api.js";

const VALID_BODY = {
  scope: "12345",
  data: {
    recipient:    "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    feeRecipient: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    relayFeeBPS:  "50",
    buyToken:     "0xcccccccccccccccccccccccccccccccccccccccc",
    minBuyAmount: "99500000",
  },
  proof: {
    pA: ["1", "2"],
    pB: [["3", "4"], ["5", "6"]],
    pC: ["7", "8"],
    pubSignals: ["9", "10", "11", "12", "13", "14", "15", "16"],
  },
};

describe("validateRequest", () => {
  test("accepts a well-formed payload", () => {
    const r = validateRequest(VALID_BODY);
    expect(r.ok).toBe(true);
  });

  test("rejects non-object body", () => {
    const r = validateRequest("not an object");
    expect(r.ok).toBe(false);
  });

  test("rejects missing scope", () => {
    const b = { ...VALID_BODY, scope: undefined };
    const r = validateRequest(b);
    expect(r.ok).toBe(false);
  });

  test("rejects bad recipient address", () => {
    const b = JSON.parse(JSON.stringify(VALID_BODY));
    b.data.recipient = "not-an-address";
    const r = validateRequest(b);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toMatch(/recipient/);
  });

  test("rejects bad buyToken address", () => {
    const b = JSON.parse(JSON.stringify(VALID_BODY));
    b.data.buyToken = "0x123"; // too short
    const r = validateRequest(b);
    expect(r.ok).toBe(false);
  });

  test("rejects wrong pubSignals length", () => {
    const b = JSON.parse(JSON.stringify(VALID_BODY));
    b.proof.pubSignals = ["1", "2", "3"]; // only 3, need 8
    const r = validateRequest(b);
    expect(r.ok).toBe(false);
  });

  test("rejects wrong pA shape", () => {
    const b = JSON.parse(JSON.stringify(VALID_BODY));
    b.proof.pA = ["1"]; // need [string, string]
    const r = validateRequest(b);
    expect(r.ok).toBe(false);
  });

  test("rejects null proof", () => {
    const b = JSON.parse(JSON.stringify(VALID_BODY));
    b.proof = null;
    const r = validateRequest(b);
    expect(r.ok).toBe(false);
  });
});

const VALID_RELAY_BODY = {
  scope: "12345",
  data: {
    recipient:    "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    feeRecipient: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    relayFeeBPS:  "50",
  },
  proof: {
    pA: ["1", "2"],
    pB: [["3", "4"], ["5", "6"]],
    pC: ["7", "8"],
    pubSignals: ["9", "10", "11", "12", "13", "14", "15", "16"],
  },
};

describe("validateRelayRequest (same-asset)", () => {
  test("accepts a well-formed same-asset payload (no buyToken/minBuyAmount)", () => {
    const r = validateRelayRequest(VALID_RELAY_BODY);
    expect(r.ok).toBe(true);
  });

  test("rejects non-object body", () => {
    expect(validateRelayRequest("nope").ok).toBe(false);
  });

  test("rejects missing scope", () => {
    expect(validateRelayRequest({ ...VALID_RELAY_BODY, scope: undefined }).ok).toBe(false);
  });

  test("rejects bad recipient address", () => {
    const b = JSON.parse(JSON.stringify(VALID_RELAY_BODY));
    b.data.recipient = "not-an-address";
    const r = validateRelayRequest(b);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.reason).toMatch(/recipient/);
  });

  test("rejects missing feeRecipient", () => {
    const b = JSON.parse(JSON.stringify(VALID_RELAY_BODY));
    delete b.data.feeRecipient;
    expect(validateRelayRequest(b).ok).toBe(false);
  });

  test("rejects wrong pubSignals length", () => {
    const b = JSON.parse(JSON.stringify(VALID_RELAY_BODY));
    b.proof.pubSignals = ["1", "2", "3"];
    expect(validateRelayRequest(b).ok).toBe(false);
  });

  test("a cross-currency body still validates (extra fields ignored)", () => {
    // Same-asset validator only requires the 3 base fields; extra buyToken/
    // minBuyAmount on the blob don't make it invalid.
    const r = validateRelayRequest(VALID_BODY);
    expect(r.ok).toBe(true);
  });
});

describe("RateLimiter", () => {
  test("perMinute=0 means unlimited", () => {
    const rl = new RateLimiter(0);
    for (let i = 0; i < 1000; i++) expect(rl.check("1.1.1.1")).toBe(true);
  });

  test("perMinute=3 allows 3 then blocks", () => {
    const rl = new RateLimiter(3);
    expect(rl.check("1.1.1.1")).toBe(true);
    expect(rl.check("1.1.1.1")).toBe(true);
    expect(rl.check("1.1.1.1")).toBe(true);
    expect(rl.check("1.1.1.1")).toBe(false);
    expect(rl.check("1.1.1.1")).toBe(false);
  });

  test("separate IPs have separate buckets", () => {
    const rl = new RateLimiter(2);
    expect(rl.check("a")).toBe(true);
    expect(rl.check("a")).toBe(true);
    expect(rl.check("a")).toBe(false);
    expect(rl.check("b")).toBe(true);
    expect(rl.check("b")).toBe(true);
  });
});
