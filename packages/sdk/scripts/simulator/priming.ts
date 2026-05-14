/**
 * Drop 9 — primed-state helpers for the simulator matrix.
 *
 * Tenderly's legacy Fork API ("snapshots") was deprecated in 2025 — the
 * recommended replacement is a Virtual TestNet that you mutate via admin
 * RPC (tenderly_setBalance, tenderly_setErc20Balance, …) once and then
 * point every simulation at via its RPC URL.
 *
 * Project-level note: we're already at 2/2 vnets on the free plan, so the
 * vnet-priming workflow needs a slot freed before it can run. The shell
 * helper `scripts/tenderly-prime-vnet.sh` automates that whole flow.
 *
 * What this TypeScript module gives you TODAY (no operational prerequisites):
 *
 *   * `commonPriming()` — a reusable `state_objects` object that pre-loads
 *     the whale persona's USDC + EURC balances and ERC-20 allowances to
 *     every contract the matrix touches (Permit2, Universal Router,
 *     FxMarketRegistry, FxLiquidator, FxSwapHook, Morpho). One declaration,
 *     used by every relevant case.
 *
 *   * `withPriming(state, ...spreads)` — merges a per-case override map on
 *     top of the common one without mutating either.
 *
 * Down the line: when the vnet slot is freed and the prime-vnet script
 * has run, swap `run-matrix.ts` over to `simulate-against-vnet` endpoints
 * and drop the per-case `state_objects` entirely. The patterns below stay
 * useful in either world — they just become defaults instead of overrides.
 */
import type { Address, Hex } from "viem";
import { balanceSlot, allowanceSlot, valueHex as hex32 } from "./client.js";
import { PERSONAS } from "./personas.js";

export type StateMap = Record<Address, { balance?: Hex; storage?: Record<Hex, Hex>; code?: Hex }>;

/**
 * Build the standard "primed hub" state: whale has 1M USDC + 1M EURC, plus
 * unlimited ERC-20 allowances to every spender the matrix uses. ETH balance
 * is set high enough to cover any Pyth fee.
 */
export function commonPriming(opts: {
  usdc: Address;
  eurc: Address;
  permit2?: Address;
  spenders?: Address[];
}): StateMap {
  const whale = PERSONAS.whale;
  const usdcStorage: Record<Hex, Hex> = {
    [balanceSlot(whale.address, 9)]: hex32(whale.usdc),
  };
  const eurcStorage: Record<Hex, Hex> = {
    [balanceSlot(whale.address, 9)]: hex32(whale.eurc),
  };
  const MAX = 2n ** 256n - 1n;
  for (const spender of opts.spenders ?? []) {
    usdcStorage[allowanceSlot(whale.address, spender, 10)] = hex32(MAX);
    eurcStorage[allowanceSlot(whale.address, spender, 10)] = hex32(MAX);
  }
  if (opts.permit2) {
    usdcStorage[allowanceSlot(whale.address, opts.permit2, 10)] = hex32(MAX);
    eurcStorage[allowanceSlot(whale.address, opts.permit2, 10)] = hex32(MAX);
  }

  return {
    [opts.usdc]: { storage: usdcStorage },
    [opts.eurc]: { storage: eurcStorage },
    // 10 ETH for the whale — comfortable headroom for Pyth update fees.
    [whale.address]: { balance: "0x8AC7230489E80000" },
  };
}

/**
 * Merge per-case storage overrides on top of a base StateMap without
 * mutating either side. Storage maps are merged key-by-key; balance and
 * code overrides on the right side win.
 */
export function withPriming(base: StateMap, ...overrides: Array<StateMap | undefined>): StateMap {
  const out: StateMap = {};
  for (const map of [base, ...overrides]) {
    if (!map) continue;
    for (const [addr, ov] of Object.entries(map) as Array<[Address, StateMap[Address]]>) {
      const prev = out[addr] ?? {};
      out[addr] = {
        balance: ov.balance ?? prev.balance,
        code: ov.code ?? prev.code,
        storage: { ...(prev.storage ?? {}), ...(ov.storage ?? {}) },
      };
    }
  }
  return out;
}
