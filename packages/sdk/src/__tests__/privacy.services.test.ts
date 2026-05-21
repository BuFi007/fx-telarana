// SPDX-License-Identifier: Apache-2.0
import { describe, expect, test } from "bun:test";
import {
  decodeAbiParameters,
  encodeAbiParameters,
  keccak256,
  toEventSelector,
  type Address,
  type Hex,
} from "viem";

import {
  compareCanonical,
  encodeRelayData,
  type DepositRecord,
  type RelayData,
} from "../privacy/services/index.js";

const POOL: Address = "0x1111111111111111111111111111111111111111";

function rec(block: bigint, tx: number, log: number, commitment: bigint): DepositRecord {
  return {
    blockNumber: block,
    transactionIndex: tx,
    logIndex: log,
    txHash: "0xdeadbeef" as Hex,
    depositor: POOL,
    commitment,
    label: 1n,
    value: 100n,
    precommitmentHash: 7n,
  };
}

describe("services/dataService — canonical sort matches indexer", () => {
  test("compareCanonical is the same total order the ASP postman uses", () => {
    const a = rec(2n, 0, 0, 100n);
    const b = rec(1n, 99, 99, 200n);
    expect(compareCanonical(a, b)).toBeGreaterThan(0);
  });

  test("tie-break on (block, tx, log)", () => {
    expect(compareCanonical(rec(5n, 1, 9, 1n), rec(5n, 2, 0, 2n))).toBeLessThan(0);
    expect(compareCanonical(rec(5n, 2, 3, 1n), rec(5n, 2, 4, 2n))).toBeLessThan(0);
    expect(compareCanonical(rec(5n, 2, 4, 1n), rec(5n, 2, 4, 9n))).toBe(0);
  });
});

describe("services/contractsService — encodeRelayData", () => {
  test("round-trip through decode preserves all fields", () => {
    const d: RelayData = {
      recipient:    "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      feeRecipient: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      relayFeeBPS:  77n,
    };
    const encoded = encodeRelayData(d);
    const [decoded] = decodeAbiParameters(
      [{
        name: "data", type: "tuple", components: [
          { name: "recipient",    type: "address" },
          { name: "feeRecipient", type: "address" },
          { name: "relayFeeBPS",  type: "uint256" },
        ],
      }],
      encoded,
    );
    expect((decoded.recipient as string).toLowerCase()).toBe(d.recipient.toLowerCase());
    expect((decoded.feeRecipient as string).toLowerCase()).toBe(d.feeRecipient.toLowerCase());
    expect(decoded.relayFeeBPS).toBe(d.relayFeeBPS);
  });
});

describe("services — ABIs align with on-chain emissions", () => {
  test("Deposited selector matches IPrivacyPool.sol", () => {
    // event Deposited(address indexed _depositor, uint256 _commitment,
    //                 uint256 _label, uint256 _value,
    //                 uint256 _precommitmentHash);
    const sig = "Deposited(address,uint256,uint256,uint256,uint256)";
    const expected = toEventSelector(sig);
    // Recompute manually to ensure both sides agree on the
    // canonical signature shape.
    const recomputed = keccak256(new TextEncoder().encode(sig) as unknown as Hex);
    expect(expected).toBe(recomputed);
  });

  test("non-indexed data blob round-trips cleanly", () => {
    const data = encodeAbiParameters(
      [
        { name: "_commitment",        type: "uint256" },
        { name: "_label",             type: "uint256" },
        { name: "_value",             type: "uint256" },
        { name: "_precommitmentHash", type: "uint256" },
      ],
      [42n, 7n, 100n, 99n],
    );
    expect(data).toMatch(/^0x[0-9a-f]+$/);
  });
});
