// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, test } from "bun:test";

import { lendingRoomId, parseLendingRoomId } from "./rooms.js";

describe("FX Telarana Liveblocks room ids", () => {
  test("builds and parses market rooms", () => {
    const marketId = "0xabc0000000000000000000000000000000000000000000000000000000000000";
    const room = lendingRoomId({ kind: "market", hubChainId: 43113, marketId });
    expect(room).toBe(`fx-telarana:43113:${marketId}`);
    expect(parseLendingRoomId(room)).toEqual({ kind: "market", hubChainId: 43113, marketId });
  });

  test("rejects unrelated rooms", () => {
    expect(parseLendingRoomId("sendero:tenant:workspace")).toBeNull();
  });
});
