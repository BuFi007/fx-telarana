// SPDX-License-Identifier: AGPL-3.0-only
//
// Restart-resume coverage for the ASP postman's SQLite layer. Track C1.

import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { LeanIMT } from "@zk-kit/lean-imt";
import { poseidon } from "maci-crypto/build/ts/hashing.js";

import { applyDeposits, newState, type CanonicalDeposit } from "./asp-postman.js";
import { PostmanStore } from "./persistence.js";

function tmpDbPath(): { path: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "asp-postman-test-"));
  return {
    path: join(dir, "postman.db"),
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}

const POOL_A = "0xAaaaaAAAaAaAAaAAaAaAaAAAaaaaaaAAaAaAaAAa" as const;
const POOL_B = "0xbBBbBbbBbBbBbBBbBBbbBbBBbBbBbBbBbbbbbBbB" as const;

const dep = (block: bigint, txIdx: number, logIdx: number, pool: string, label: bigint): CanonicalDeposit => ({
  blockNumber:      block,
  transactionIndex: txIdx,
  logIndex:         logIdx,
  pool:             pool as `0x${string}`,
  label,
});

const cleanups: Array<() => void> = [];
afterEach(() => {
  while (cleanups.length > 0) cleanups.pop()!();
});

describe("PostmanStore", () => {
  test("empty load returns zero cursor + empty leaves", () => {
    const { path, cleanup } = tmpDbPath();
    cleanups.push(cleanup);
    const store = new PostmanStore(path);
    const loaded = store.load();
    expect(loaded.cursor).toBe(0n);
    expect(loaded.leaves).toHaveLength(0);
    expect(loaded.pools).toHaveLength(0);
    store.close();
  });

  test("appendLeaf + setCursor + recordPool persist and survive close/reopen", () => {
    const { path, cleanup } = tmpDbPath();
    cleanups.push(cleanup);

    // Session 1: write some state.
    {
      const store = new PostmanStore(path);
      store.transaction(() => {
        store.recordPool(POOL_A);
        store.recordPool(POOL_B);
        store.appendLeaf("100:0:0", 12345n, 0);
        store.appendLeaf("100:0:1", 67890n, 1);
        store.appendLeaf("101:2:5", 99999n, 2);
        store.setCursor(101n);
      });
      store.close();
    }

    // Session 2: re-open and read back.
    {
      const store = new PostmanStore(path);
      const loaded = store.load();
      expect(loaded.cursor).toBe(101n);
      expect(loaded.pools).toEqual([POOL_A, POOL_B]);
      expect(loaded.leaves).toEqual([
        { key: "100:0:0", label: 12345n },
        { key: "100:0:1", label: 67890n },
        { key: "101:2:5", label: 99999n },
      ]);
      store.close();
    }
  });

  test("appendLeaf is idempotent on duplicate key (replay-safe)", () => {
    const { path, cleanup } = tmpDbPath();
    cleanups.push(cleanup);
    const store = new PostmanStore(path);
    store.appendLeaf("100:0:0", 12345n, 0);
    // Replay the same insertion (e.g. recovery path).
    store.appendLeaf("100:0:0", 12345n, 0);
    const loaded = store.load();
    expect(loaded.leaves).toHaveLength(1);
    store.close();
  });
});

describe("applyDeposits + persistence round-trip", () => {
  test("LeanIMT root after restart matches root before restart", () => {
    const { path, cleanup } = tmpDbPath();
    cleanups.push(cleanup);

    // Session 1: build a tree of three deposits.
    let rootBefore = 0n;
    {
      const store = new PostmanStore(path);
      const state = newState();
      const knownPoolsBefore = state.pools.length;
      state.pools.push(POOL_A as `0x${string}`, POOL_B as `0x${string}`);

      const deposits: CanonicalDeposit[] = [
        dep(100n, 0, 0, POOL_A, 12345n),
        dep(101n, 1, 0, POOL_B, 67890n),
        dep(102n, 0, 0, POOL_A, 99999n),
      ];
      const applied = applyDeposits(state, deposits);
      state.cursor = 102n;
      rootBefore = state.tree.root;

      store.transaction(() => {
        for (let i = knownPoolsBefore; i < state.pools.length; i++) {
          store.recordPool(state.pools[i]!);
        }
        for (const leaf of applied) {
          store.appendLeaf(leaf.key, leaf.label, leaf.order);
        }
        store.setCursor(state.cursor);
      });
      store.close();
    }

    // Session 2: open a fresh store + fresh state, hydrate.
    {
      const store = new PostmanStore(path);
      const state = newState();
      const persisted = store.load();
      state.cursor = persisted.cursor;
      state.pools = persisted.pools.slice();
      for (const leaf of persisted.leaves) {
        state.applied.add(leaf.key);
        state.tree.insert(leaf.label);
      }
      expect(state.cursor).toBe(102n);
      expect(state.pools).toEqual([POOL_A, POOL_B]);
      expect(state.tree.size).toBe(3);
      expect(state.tree.root).toBe(rootBefore);
      store.close();
    }
  });

  test("post-hydration applyDeposits skips already-applied keys (no double insert)", () => {
    const { path, cleanup } = tmpDbPath();
    cleanups.push(cleanup);

    // Build session 1, then restart and replay the SAME deposits.
    const deposits: CanonicalDeposit[] = [
      dep(50n, 0, 0, POOL_A, 11n),
      dep(50n, 0, 1, POOL_A, 22n),
    ];

    let rootBefore = 0n;
    {
      const store = new PostmanStore(path);
      const state = newState();
      const applied = applyDeposits(state, deposits);
      store.transaction(() => {
        for (const leaf of applied) {
          store.appendLeaf(leaf.key, leaf.label, leaf.order);
        }
        store.setCursor(50n);
      });
      rootBefore = state.tree.root;
      store.close();
    }

    {
      const store = new PostmanStore(path);
      const state = newState();
      const persisted = store.load();
      for (const leaf of persisted.leaves) {
        state.applied.add(leaf.key);
        state.tree.insert(leaf.label);
      }
      // Replay — applied set already covers them; no leaves should be added.
      const reapplied = applyDeposits(state, deposits.slice());
      expect(reapplied).toHaveLength(0);
      expect(state.tree.size).toBe(2);
      expect(state.tree.root).toBe(rootBefore);
      store.close();
    }
  });

  test("hand-rolled LeanIMT replay produces same root as direct construction", () => {
    // Sanity that LeanIMT is order-stable for our hash function.
    const labels = [3n, 5n, 7n, 11n];
    const a = new LeanIMT<bigint>((x, y) => poseidon([x, y]));
    for (const l of labels) a.insert(l);
    const b = new LeanIMT<bigint>((x, y) => poseidon([x, y]));
    for (const l of labels) b.insert(l);
    expect(a.root).toBe(b.root);
  });
});
