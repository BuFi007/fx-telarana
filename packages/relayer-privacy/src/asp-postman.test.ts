// SPDX-License-Identifier: AGPL-3.0-only
//
// Unit tests for the canonical-ordering core of the ASP postman.
// Codex-r2 HIGH regression: deposits across pools must enter the LeanIMT
// in canonical `(block, txIndex, logIndex)` order so the published root is
// reproducible from chain history alone.

import { describe, expect, test } from "bun:test";
import type { Address } from "viem";

import {
  applyDeposits,
  compareCanonical,
  newState,
  type CanonicalDeposit,
} from "./asp-postman.js";

const POOL_A: Address = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const POOL_B: Address = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

function dep(
  block: bigint,
  txIndex: number,
  logIndex: number,
  pool: Address,
  label: bigint,
): CanonicalDeposit {
  return { blockNumber: block, transactionIndex: txIndex, logIndex, pool, label };
}

describe("compareCanonical", () => {
  test("sorts primarily by block", () => {
    expect(
      compareCanonical(dep(2n, 0, 0, POOL_A, 1n), dep(1n, 99, 99, POOL_B, 2n)),
    ).toBeGreaterThan(0);
  });

  test("breaks ties with transactionIndex", () => {
    expect(
      compareCanonical(dep(5n, 1, 9, POOL_A, 1n), dep(5n, 2, 0, POOL_A, 2n)),
    ).toBeLessThan(0);
  });

  test("breaks deeper ties with logIndex", () => {
    expect(
      compareCanonical(dep(5n, 2, 3, POOL_A, 1n), dep(5n, 2, 4, POOL_B, 2n)),
    ).toBeLessThan(0);
  });

  test("returns 0 for identical position", () => {
    expect(
      compareCanonical(dep(7n, 1, 1, POOL_A, 100n), dep(7n, 1, 1, POOL_B, 200n)),
    ).toBe(0);
  });
});

describe("applyDeposits — canonical insertion across pools", () => {
  test("two pools, interleaved blocks, end up in canonical order", () => {
    // Chain history:
    //   block 1, tx 0, log 0  pool A label 10
    //   block 1, tx 1, log 0  pool B label 20
    //   block 2, tx 0, log 0  pool A label 30
    //   block 2, tx 0, log 1  pool B label 40
    // We feed them in REVERSED order to the indexer to prove sort works.
    const state = newState();
    const reversed: CanonicalDeposit[] = [
      dep(2n, 0, 1, POOL_B, 40n),
      dep(2n, 0, 0, POOL_A, 30n),
      dep(1n, 1, 0, POOL_B, 20n),
      dep(1n, 0, 0, POOL_A, 10n),
    ];
    applyDeposits(state, reversed);

    // Build a reference tree by inserting in canonical order and check
    // roots match.
    const reference = newState();
    applyDeposits(reference, [
      dep(1n, 0, 0, POOL_A, 10n),
      dep(1n, 1, 0, POOL_B, 20n),
      dep(2n, 0, 0, POOL_A, 30n),
      dep(2n, 0, 1, POOL_B, 40n),
    ]);

    expect(state.tree.size).toBe(4);
    expect(state.tree.root).toBe(reference.tree.root);
  });

  test("duplicate (block, txIndex, logIndex) inserts only once", () => {
    const state = newState();
    applyDeposits(state, [
      dep(1n, 0, 0, POOL_A, 10n),
      dep(1n, 0, 0, POOL_A, 10n), // exact duplicate
    ]);
    expect(state.tree.size).toBe(1);
  });

  test("subsequent applyDeposits calls extend the tree without re-inserting", () => {
    const state = newState();
    applyDeposits(state, [dep(1n, 0, 0, POOL_A, 10n)]);
    const rootAfter1 = state.tree.root;

    applyDeposits(state, [dep(1n, 0, 0, POOL_A, 10n)]); // duplicate
    expect(state.tree.size).toBe(1);
    expect(state.tree.root).toBe(rootAfter1);

    applyDeposits(state, [dep(2n, 0, 0, POOL_B, 20n)]); // new leaf
    expect(state.tree.size).toBe(2);
    expect(state.tree.root).not.toBe(rootAfter1);
  });

  test("dirty flag only set when a real insertion happens", () => {
    const state = newState();
    expect(state.dirty).toBe(false);

    applyDeposits(state, [dep(1n, 0, 0, POOL_A, 7n)]);
    expect(state.dirty).toBe(true);

    state.dirty = false;
    applyDeposits(state, [dep(1n, 0, 0, POOL_A, 7n)]); // duplicate only
    expect(state.dirty).toBe(false);
  });
});
