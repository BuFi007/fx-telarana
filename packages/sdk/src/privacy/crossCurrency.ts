// SPDX-License-Identifier: Apache-2.0
//
// Cross-currency relay helpers for fx-Telarana — encode/decode the
// `CrossCurrencyRelayData` blob that `FxPrivacyEntrypoint.relayCrossCurrency`
// expects inside `Withdrawal.data`.

import { decodeAbiParameters, encodeAbiParameters, type Hex } from "viem";

import type { CrossCurrencyRelayData } from "./types.js";

const CROSS_CURRENCY_RELAY_ABI = [
  {
    name: "data",
    type: "tuple",
    components: [
      { name: "recipient",     type: "address" },
      { name: "feeRecipient",  type: "address" },
      { name: "relayFeeBPS",   type: "uint256" },
      { name: "buyToken",      type: "address" },
      { name: "minBuyAmount",  type: "uint256" },
    ],
  },
] as const;

/**
 * Encode {@link CrossCurrencyRelayData} as the `bytes` blob carried in
 * `Withdrawal.data`. Output is what the Groth16 `context` commits against.
 */
export function encodeCrossCurrencyRelayData(
  d: CrossCurrencyRelayData,
): Hex {
  return encodeAbiParameters(CROSS_CURRENCY_RELAY_ABI, [
    {
      recipient:    d.recipient,
      feeRecipient: d.feeRecipient,
      relayFeeBPS:  d.relayFeeBPS,
      buyToken:     d.buyToken,
      minBuyAmount: d.minBuyAmount,
    },
  ]);
}

/** Inverse of {@link encodeCrossCurrencyRelayData}. */
export function decodeCrossCurrencyRelayData(
  encoded: Hex,
): CrossCurrencyRelayData {
  const [d] = decodeAbiParameters(CROSS_CURRENCY_RELAY_ABI, encoded);
  return {
    recipient:    d.recipient,
    feeRecipient: d.feeRecipient,
    relayFeeBPS:  d.relayFeeBPS,
    buyToken:     d.buyToken,
    minBuyAmount: d.minBuyAmount,
  };
}
