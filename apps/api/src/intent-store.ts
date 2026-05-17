// SPDX-License-Identifier: AGPL-3.0-only
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";

import {
  FxTelaranaError,
  nonceScope,
  verifyIntentSignature,
  type FxTelaranaAction,
  type FxTelaranaIntentTypedData,
} from "@fx-telarana/core";
import type { Address, Hex } from "viem";

export type StoredIntentStatus = "unsigned" | "verified";

export type StoredIntent = {
  id: string;
  kind: FxTelaranaAction;
  createdAt: string;
  updatedAt: string;
  typedData: FxTelaranaIntentTypedData;
  status: StoredIntentStatus;
  signer?: Address;
  signature?: Hex;
  verifiedAt?: string;
};

type PersistedState = {
  intents: StoredIntent[];
  nonceByScope: Record<string, string>;
};

function defaultStorePath(): string {
  return process.env.FX_TELARANA_INTENT_STORE_PATH ?? join(process.cwd(), ".data", "fx-telarana-intents.json");
}

function encodeBigInt(_key: string, value: unknown) {
  return typeof value === "bigint" ? { $bigint: value.toString() } : value;
}

function decodeBigInt(_key: string, value: unknown) {
  if (
    value &&
    typeof value === "object" &&
    "$bigint" in value &&
    typeof (value as { $bigint?: unknown }).$bigint === "string"
  ) {
    return BigInt((value as { $bigint: string }).$bigint);
  }
  return value;
}

export class DurableIntentStore {
  readonly #path: string;
  readonly #intents = new Map<string, StoredIntent>();
  readonly #nonceByScope = new Map<string, bigint>();
  #loaded = false;

  constructor(path = defaultStorePath()) {
    this.#path = path;
  }

  get path(): string {
    return this.#path;
  }

  create(kind: FxTelaranaAction, typedData: FxTelaranaIntentTypedData): StoredIntent {
    this.#load();
    const now = new Date().toISOString();
    const intent: StoredIntent = {
      id: randomUUID(),
      kind,
      createdAt: now,
      updatedAt: now,
      typedData,
      status: "unsigned",
    };
    this.#intents.set(intent.id, intent);
    this.#persist();
    return intent;
  }

  get(id: string): StoredIntent | null {
    this.#load();
    return this.#intents.get(id) ?? null;
  }

  async verify(id: string, args: { signer: Address; signature: Hex }): Promise<StoredIntent> {
    this.#load();
    const intent = this.#intents.get(id);
    if (!intent) {
      throw new FxTelaranaError("Intent not found", "INTENT_NOT_FOUND", 404);
    }
    if (intent.status === "verified") {
      if (intent.signer?.toLowerCase() === args.signer.toLowerCase() && intent.signature === args.signature) {
        return intent;
      }
      throw new FxTelaranaError("Intent has already been verified", "INTENT_ALREADY_VERIFIED", 409);
    }

    const valid = await verifyIntentSignature({
      typedData: intent.typedData,
      signer: args.signer,
      signature: args.signature,
    });
    if (!valid) {
      throw new FxTelaranaError("Intent signature is invalid", "INTENT_SIGNATURE_INVALID", 401);
    }
    if (args.signer.toLowerCase() !== intent.typedData.message.onBehalf.toLowerCase()) {
      throw new FxTelaranaError("Intent signer must match onBehalf", "INTENT_SIGNER_MISMATCH", 403);
    }

    const scope = nonceScope({
      chainId: intent.typedData.message.chainId,
      action: intent.kind,
      account: intent.typedData.message.onBehalf,
    });
    const expectedNonce = this.#nonceByScope.get(scope) ?? 0n;
    const nonce = intent.typedData.message.nonce;
    if (nonce !== expectedNonce) {
      throw new FxTelaranaError(
        `Invalid nonce ${nonce}; expected ${expectedNonce}`,
        "INTENT_NONCE_MISMATCH",
        409
      );
    }

    const now = new Date().toISOString();
    const verified: StoredIntent = {
      ...intent,
      status: "verified",
      signer: args.signer,
      signature: args.signature,
      verifiedAt: now,
      updatedAt: now,
    };
    this.#nonceByScope.set(scope, expectedNonce + 1n);
    this.#intents.set(id, verified);
    this.#persist();
    return verified;
  }

  resetForTests(): void {
    this.#loaded = true;
    this.#intents.clear();
    this.#nonceByScope.clear();
  }

  #load(): void {
    if (this.#loaded) return;
    this.#loaded = true;
    if (!existsSync(this.#path)) return;
    const parsed = JSON.parse(readFileSync(this.#path, "utf8"), decodeBigInt) as PersistedState;
    for (const intent of parsed.intents ?? []) {
      this.#intents.set(intent.id, intent);
    }
    for (const [scope, nonce] of Object.entries(parsed.nonceByScope ?? {})) {
      this.#nonceByScope.set(scope, BigInt(nonce));
    }
  }

  #persist(): void {
    const state: PersistedState = {
      intents: [...this.#intents.values()],
      nonceByScope: Object.fromEntries([...this.#nonceByScope.entries()].map(([scope, nonce]) => [scope, nonce.toString()])),
    };
    mkdirSync(dirname(this.#path), { recursive: true });
    const tempPath = `${this.#path}.${process.pid}.${Date.now()}.tmp`;
    writeFileSync(tempPath, `${JSON.stringify(state, encodeBigInt, 2)}\n`);
    renameSync(tempPath, this.#path);
  }
}

export const intentStore = new DurableIntentStore();

export function storeIntent(kind: FxTelaranaAction, typedData: FxTelaranaIntentTypedData): StoredIntent {
  return intentStore.create(kind, typedData);
}

export function getIntent(id: string): StoredIntent | null {
  return intentStore.get(id);
}

export function verifyStoredIntent(id: string, args: { signer: Address; signature: Hex }): Promise<StoredIntent> {
  return intentStore.verify(id, args);
}

export function resetIntentStoreForTests(): void {
  intentStore.resetForTests();
}
