// SPDX-License-Identifier: AGPL-3.0-only
import { randomUUID } from "node:crypto";

export type StoredIntent = {
  id: string;
  kind: string;
  createdAt: string;
  typedData: unknown;
  status: "unsigned";
};

const intents = new Map<string, StoredIntent>();

export function storeIntent(kind: string, typedData: unknown): StoredIntent {
  const intent = {
    id: randomUUID(),
    kind,
    createdAt: new Date().toISOString(),
    typedData,
    status: "unsigned" as const,
  };
  intents.set(intent.id, intent);
  return intent;
}

export function getIntent(id: string): StoredIntent | null {
  return intents.get(id) ?? null;
}
