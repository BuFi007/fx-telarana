// SPDX-License-Identifier: GPL-3.0
//
// Tests for `toWithdrawProofTuple` — the snarkjs → Solidity calldata
// reshaper. Codex-r10 MED #2 regression: locks in the pB inner-pair
// reversal so the dApp glue can't drift.

import { describe, expect, test } from "bun:test";

import { toWithdrawProofTuple } from "./convert.js";

const PROOF = {
  pi_a: ["100", "101", "1"],
  pi_b: [
    ["200", "201"], // becomes [201, 200] in tuple
    ["300", "301"], // becomes [301, 300]
    ["1", "0"],     // infinity marker, discarded
  ],
  pi_c: ["400", "401", "1"],
  protocol: "groth16",
} as const;

const SIGNALS = [
  "1000", "1001", "1002", "1003",
  "1004", "1005", "1006", "1007",
];

describe("toWithdrawProofTuple", () => {
  test("reshapes pA/pB/pC into Solidity tuple shape", () => {
    const out = toWithdrawProofTuple(PROOF as any, SIGNALS);
    expect(out.pA).toEqual(["100", "101"]);
    expect(out.pC).toEqual(["400", "401"]);
  });

  test("REVERSES pB inner pairs (BN254 c0+c1·X convention)", () => {
    const out = toWithdrawProofTuple(PROOF as any, SIGNALS);
    // pi_b[0] = ["200", "201"] → pB[0] = ["201", "200"]
    expect(out.pB[0]).toEqual(["201", "200"]);
    expect(out.pB[1]).toEqual(["301", "300"]);
  });

  test("preserves pubSignals in ProofLib.WithdrawProof order", () => {
    const out = toWithdrawProofTuple(PROOF as any, SIGNALS);
    expect(out.pubSignals).toEqual([
      "1000", "1001", "1002", "1003",
      "1004", "1005", "1006", "1007",
    ]);
  });

  test("rejects publicSignals length != 8", () => {
    expect(() => toWithdrawProofTuple(PROOF as any, ["1", "2", "3"])).toThrow(/8/);
    expect(() => toWithdrawProofTuple(PROOF as any, new Array(9).fill("1"))).toThrow(/8/);
  });

  test("rejects malformed pi_b (inner pair wrong length)", () => {
    const bad = { ...PROOF, pi_b: [["200"], ["300", "301"], ["1", "0"]] } as any;
    expect(() => toWithdrawProofTuple(bad, SIGNALS)).toThrow(/pi_b/);
  });

  test("stringifies bigint inputs (snarkjs sometimes returns bigints)", () => {
    const bigProof = {
      ...PROOF,
      pi_a: [100n, 101n, 1n],
      pi_c: [400n, 401n, 1n],
    } as any;
    const bigSignals = SIGNALS.map(BigInt);
    const out = toWithdrawProofTuple(bigProof, bigSignals as any);
    expect(out.pA[0]).toBe("100");
    expect(out.pC[1]).toBe("401");
    expect(out.pubSignals[0]).toBe("1000");
  });
});
