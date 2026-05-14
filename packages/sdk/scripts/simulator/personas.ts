/**
 * Persona definitions for the Tenderly simulator test suite.
 *
 * Each persona is an EOA we pretend has a certain pre-loaded USDC + EURC
 * balance on each chain. We don't actually move funds — we use Tenderly's
 * `state_objects` to override the storage slots that hold those balances
 * for the duration of one simulation.
 */
import type { Address, Hex } from "viem";
import { balanceSlot, allowanceSlot, valueHex } from "./client.js";

export type Persona = {
  name: string;
  address: Address;
  /** USDC balance to pre-load (6 decimals). */
  usdc: bigint;
  /** EURC balance to pre-load (6 decimals). */
  eurc: bigint;
};

/// USDC is FiatTokenV2_2 on Base Sepolia + most testnets. `_balances`
/// lives at storage slot 9, `_allowed` (allowances) at slot 10.
/// Verified against on-chain bytecode of Circle's testnet USDC.
export const USDC_BALANCES_SLOT = 9;
export const USDC_ALLOWED_SLOT = 10;

/// EURC contract layout matches Circle's USDC (same FiatToken codebase).
export const EURC_BALANCES_SLOT = 9;
export const EURC_ALLOWED_SLOT = 10;

export const PERSONAS: Record<string, Persona> = {
  whale: {
    name: "whale",
    address: "0x1111111111111111111111111111111111111111",
    usdc: 1_000_000_000_000n,  // 1,000,000 USDC (6 dec)
    eurc: 1_000_000_000_000n,  // 1,000,000 EURC
  },
  mid: {
    name: "mid",
    address: "0x2222222222222222222222222222222222222222",
    usdc: 1_000_000_000n,      // 1,000 USDC
    eurc: 1_000_000_000n,
  },
  small: {
    name: "small",
    address: "0x3333333333333333333333333333333333333333",
    usdc: 1_000_000n,          // 1 USDC
    eurc: 1_000_000n,
  },
  empty: {
    name: "empty",
    address: "0x4444444444444444444444444444444444444444",
    usdc: 0n,
    eurc: 0n,
  },
};

/**
 * Build a Tenderly `state_objects` override that pre-loads:
 *  - the persona's USDC balance at `usdc._balances[persona]`
 *  - if `approveSpender` is set, the persona's USDC allowance to that spender
 *  - same pair for EURC if `eurc` address is provided
 */
export function personaState(
  persona: Persona,
  usdc: Address,
  approveSpender?: Address,
  eurc?: Address,
): Record<Address, { storage: Record<Hex, Hex> }> {
  const out: Record<Address, { storage: Record<Hex, Hex> }> = {};

  const usdcStorage: Record<Hex, Hex> = {
    [balanceSlot(persona.address, USDC_BALANCES_SLOT)]: valueHex(persona.usdc),
  };
  if (approveSpender) {
    usdcStorage[
      allowanceSlot(persona.address, approveSpender, USDC_ALLOWED_SLOT)
    ] = valueHex(2n ** 256n - 1n);
  }
  out[usdc] = { storage: usdcStorage };

  if (eurc) {
    const eurcStorage: Record<Hex, Hex> = {
      [balanceSlot(persona.address, EURC_BALANCES_SLOT)]: valueHex(persona.eurc),
    };
    if (approveSpender) {
      eurcStorage[
        allowanceSlot(persona.address, approveSpender, EURC_ALLOWED_SLOT)
      ] = valueHex(2n ** 256n - 1n);
    }
    out[eurc] = { storage: eurcStorage };
  }

  return out;
}
