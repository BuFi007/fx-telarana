// SPDX-License-Identifier: AGPL-3.0-only
import { z } from "zod";

const marketIdPattern = /^0x[0-9a-fA-F]{64}$/;

export type LendingRoom = {
  kind: "market";
  hubChainId: number;
  marketId: `0x${string}`;
};

export const lendingRoomSchema = z.object({
  hubChainId: z.number().int().positive(),
  marketId: z.string().regex(marketIdPattern),
});

export function lendingRoomId(input: LendingRoom): string {
  return `fx-telarana:${input.hubChainId}:${input.marketId.toLowerCase()}`;
}

export function parseLendingRoomId(roomId: string): LendingRoom | null {
  const match = /^fx-telarana:(\d+):(0x[0-9a-fA-F]{64})$/.exec(roomId);
  if (!match) return null;
  return {
    kind: "market",
    hubChainId: Number(match[1]),
    marketId: match[2] as `0x${string}`,
  };
}

export type LendingPresence = {
  userId: string;
  displayName: string;
  walletAddress: string | null;
  role: "supplier" | "borrower" | "keeper" | "operator" | "viewer";
  cursorX: number | null;
  cursorY: number | null;
  focusedPanel: "market" | "supply" | "borrow" | "position" | "liquidations" | null;
  previewAccount?: string | null;
  previewHealthFactorE18?: string | null;
  [key: string]: string | number | boolean | null | undefined;
};

export type LendingStorage = {
  selectedAccounts: string[];
  pinnedEventIds: string[];
  notes: string;
};

export const INITIAL_LENDING_STORAGE: LendingStorage = {
  selectedAccounts: [],
  pinnedEventIds: [],
  notes: "",
};
