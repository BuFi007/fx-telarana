// SPDX-License-Identifier: AGPL-3.0-only
import { WAD } from "./constants.js";
import type { AccountPosition } from "./types.js";

export type LiquidationCandidate = AccountPosition & {
  rank: number;
  distanceToLiquidationE18: bigint;
};

export function rankLiquidationCandidates(
  positions: AccountPosition[],
  limit = 50
): LiquidationCandidate[] {
  return positions
    .filter((position) => position.healthFactorE18 !== null)
    .sort((a, b) => {
      const ahf = a.healthFactorE18 ?? 0n;
      const bhf = b.healthFactorE18 ?? 0n;
      return ahf < bhf ? -1 : ahf > bhf ? 1 : 0;
    })
    .slice(0, limit)
    .map((position, index) => ({
      ...position,
      rank: index + 1,
      distanceToLiquidationE18:
        position.healthFactorE18 === null
          ? WAD
          : position.healthFactorE18 > WAD
            ? position.healthFactorE18 - WAD
            : 0n,
    }));
}
