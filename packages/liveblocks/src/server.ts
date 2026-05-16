// SPDX-License-Identifier: AGPL-3.0-only
import { Liveblocks } from "@liveblocks/node";

import { lendingRoomId, parseLendingRoomId, type LendingRoom } from "./rooms.js";

let client: Liveblocks | null | undefined;

function liveblocksClient(): Liveblocks | null {
  if (client !== undefined) return client;
  const secret = process.env.LIVEBLOCKS_SECRET_KEY;
  client = secret ? new Liveblocks({ secret }) : null;
  return client;
}

export type IssueLendingSessionInput = {
  userId: string;
  displayName: string;
  walletAddress?: string | null;
  roomIds: string[];
};

export async function issueLendingSession(input: IssueLendingSessionInput): Promise<{ token: string }> {
  const lb = liveblocksClient();
  if (!lb) throw new Error("LIVEBLOCKS_SECRET_KEY is not configured");

  for (const roomId of input.roomIds) {
    if (!parseLendingRoomId(roomId)) {
      throw new Error(`Invalid FX Telarana lending room id: ${roomId}`);
    }
  }

  const session = lb.prepareSession(input.userId, {
    userInfo: {
      name: input.displayName,
      walletAddress: input.walletAddress ?? undefined,
      kind: "human",
    },
  });

  for (const roomId of input.roomIds) {
    session.allow(roomId, session.FULL_ACCESS);
  }

  const response = await session.authorize();
  if (response.status !== 200) throw new Error(`Liveblocks authorize failed: ${response.status}`);
  return { token: JSON.parse(response.body).token };
}

export async function ensureLendingRoom(input: LendingRoom & { title?: string; url?: string }): Promise<void> {
  const lb = liveblocksClient();
  if (!lb) return;
  const roomId = lendingRoomId(input);
  await lb.getOrCreateRoom(roomId, {
    defaultAccesses: [],
    metadata: {
      kind: "fx-telarana-market",
      hubChainId: String(input.hubChainId),
      marketId: input.marketId,
      title: input.title ?? `Market ${input.marketId.slice(0, 10)}`,
      url: input.url ?? `/fx-telarana/markets/${input.hubChainId}/${input.marketId}`,
    },
  });
}
