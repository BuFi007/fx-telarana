// SPDX-License-Identifier: AGPL-3.0-only
//
// SQLite-backed persistence for the ASP postman.
//
// The postman is fundamentally a single-writer per-chain process (see
// README.md `single-writer constraint`). All it needs to survive a
// restart is:
//
//   1. The cursor (highest block fully scanned + applied to tree).
//   2. The ordered leaf set (commitment labels in canonical insertion
//      order). The LeanIMT itself is deterministic from this leaf
//      sequence, so we don't need to serialize the tree's internal nodes.
//   3. The set of discovered pools (so a restart can resume watching
//      without re-scanning from FROM_BLOCK to re-emit PoolRegistered).
//
// Multi-chain note: this store is per-database-file, not per-chain.
// Operators run one postman process per chain; each process gets its
// own DB file at `${DATA_DIR}/postman-<chainName>.db`. Don't share a
// single file across chains — the cursor would collide.
//
// We use Bun's built-in `bun:sqlite` (synchronous, zero external deps).
// All writes happen inside short-lived sync calls from the postman main
// loop; no async-IO concurrency to worry about.

import { Database } from "bun:sqlite";
import { dirname } from "node:path";
import { existsSync, mkdirSync } from "node:fs";

import type { Address } from "viem";

export interface PersistedState {
  cursor: bigint;
  pools: Address[];
  /** Ordered list of (key, label) — `key` is the canonical insertion
   *  key `${blockNumber}:${txIndex}:${logIndex}`; `label` is the
   *  commitment label that was inserted into the tree at that point. */
  leaves: Array<{ key: string; label: bigint }>;
}

export class PostmanStore {
  private readonly db: Database;
  private readonly insertLeafStmt: import("bun:sqlite").Statement;
  private readonly insertPoolStmt: import("bun:sqlite").Statement;
  private readonly setCursorStmt: import("bun:sqlite").Statement;

  constructor(dbPath: string) {
    const dir = dirname(dbPath);
    if (dir && dir !== "." && !existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    this.db = new Database(dbPath, { create: true });

    // Foreign keys + WAL mode for crash-safety. The postman is the only
    // writer, so concurrency isn't the goal — durability is.
    this.db.run("PRAGMA foreign_keys = ON;");
    this.db.run("PRAGMA journal_mode = WAL;");
    this.db.run("PRAGMA synchronous = NORMAL;");

    this.db.run(`
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    `);
    this.db.run(`
      CREATE TABLE IF NOT EXISTS pools (
        address       TEXT PRIMARY KEY,
        discovered_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
    `);
    this.db.run(`
      CREATE TABLE IF NOT EXISTS leaves (
        key            TEXT    PRIMARY KEY,
        label          TEXT    NOT NULL,
        inserted_order INTEGER NOT NULL UNIQUE
      );
    `);
    this.db.run(`
      CREATE INDEX IF NOT EXISTS idx_leaves_order
        ON leaves (inserted_order);
    `);

    this.insertLeafStmt = this.db.prepare(
      `INSERT OR IGNORE INTO leaves (key, label, inserted_order)
       VALUES (?, ?, ?);`,
    );
    this.insertPoolStmt = this.db.prepare(
      `INSERT OR IGNORE INTO pools (address) VALUES (?);`,
    );
    this.setCursorStmt = this.db.prepare(
      `INSERT INTO meta (key, value) VALUES ('cursor', ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value;`,
    );
  }

  /** Load every persisted field. Returns null-cursor (= no progress yet)
   *  when the DB is empty so the caller can initialize from config. */
  load(): PersistedState {
    const cursorRow = this.db
      .query<{ value: string }, []>(
        "SELECT value FROM meta WHERE key = 'cursor';",
      )
      .get();
    const cursor = cursorRow ? BigInt(cursorRow.value) : 0n;

    const poolRows = this.db
      .query<{ address: string }, []>(
        "SELECT address FROM pools ORDER BY rowid;",
      )
      .all();

    const leafRows = this.db
      .query<{ key: string; label: string }, []>(
        "SELECT key, label FROM leaves ORDER BY inserted_order;",
      )
      .all();

    return {
      cursor,
      pools:  poolRows.map((r) => r.address as Address),
      leaves: leafRows.map((r) => ({ key: r.key, label: BigInt(r.label) })),
    };
  }

  /** Append a leaf at `inserted_order = order`. INSERT OR IGNORE so
   *  re-running the same key (idempotent recovery) is a no-op. */
  appendLeaf(key: string, label: bigint, order: number): void {
    this.insertLeafStmt.run(key, label.toString(), order);
  }

  /** Record a discovered pool. Idempotent. */
  recordPool(address: Address): void {
    this.insertPoolStmt.run(address);
  }

  /** Update the canonical cursor. */
  setCursor(cursor: bigint): void {
    this.setCursorStmt.run(cursor.toString());
  }

  /** Batch a series of mutations in a transaction for crash atomicity. */
  transaction<T>(fn: () => T): T {
    return this.db.transaction(fn)();
  }

  close(): void {
    this.db.close();
  }
}
