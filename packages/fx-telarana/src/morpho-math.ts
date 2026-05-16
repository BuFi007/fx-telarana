// SPDX-License-Identifier: AGPL-3.0-only
/**
 * TypeScript port of Morpho Blue's SharesMathLib ratios.
 * Constants match Morpho's virtual-share defense: +1 virtual asset and
 * +1e6 virtual shares. Keep this file small and covered by tests.
 */
export const MORPHO_VIRTUAL_ASSETS = 1n;
export const MORPHO_VIRTUAL_SHARES = 1_000_000n;

export function mulDivDown(x: bigint, y: bigint, denominator: bigint): bigint {
  if (denominator === 0n) throw new Error("mulDivDown denominator is zero");
  return (x * y) / denominator;
}

export function mulDivUp(x: bigint, y: bigint, denominator: bigint): bigint {
  if (denominator === 0n) throw new Error("mulDivUp denominator is zero");
  const product = x * y;
  return product === 0n ? 0n : ((product - 1n) / denominator) + 1n;
}

export function toSharesDown(assets: bigint, totalAssets: bigint, totalShares: bigint): bigint {
  return mulDivDown(
    assets,
    totalShares + MORPHO_VIRTUAL_SHARES,
    totalAssets + MORPHO_VIRTUAL_ASSETS
  );
}

export function toAssetsDown(shares: bigint, totalAssets: bigint, totalShares: bigint): bigint {
  return mulDivDown(
    shares,
    totalAssets + MORPHO_VIRTUAL_ASSETS,
    totalShares + MORPHO_VIRTUAL_SHARES
  );
}

export function toAssetsUp(shares: bigint, totalAssets: bigint, totalShares: bigint): bigint {
  return mulDivUp(
    shares,
    totalAssets + MORPHO_VIRTUAL_ASSETS,
    totalShares + MORPHO_VIRTUAL_SHARES
  );
}
