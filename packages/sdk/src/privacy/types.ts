// SPDX-License-Identifier: Apache-2.0
//
// Domain types for the fx-Telarana Privacy Hook SDK. Vendored from
// 0xbow-io/privacy-pools-core (Apache-2.0). Branded `Hash` / `Secret`
// types are preserved to keep parity with the upstream type-safety model.

import type { Groth16Proof, PublicSignals } from "snarkjs";
import type { LeanIMTMerkleProof } from "@zk-kit/lean-imt";
import type { Address, Hex } from "viem";

/** Branded bigint representing a Poseidon hash. */
export type Hash = bigint & { readonly __brand: unique symbol };
/** Branded bigint representing a private secret (nullifier or secret). */
export type Secret = bigint & { readonly __brand: unique symbol };

export interface MasterKeys {
  masterNullifier: Secret;
  masterSecret: Secret;
}

export interface Precommitment {
  readonly hash: Hash;
  readonly nullifier: Secret;
  readonly secret: Secret;
}

export interface CommitmentPreimage {
  readonly value: bigint;
  readonly label: bigint;
  readonly precommitment: Precommitment;
}

export interface Commitment {
  readonly hash: Hash;
  readonly nullifierHash: Hash;
  readonly preimage: CommitmentPreimage;
}

export interface CommitmentProof {
  readonly proof: Groth16Proof;
  readonly publicSignals: PublicSignals;
}

/**
 * Mirrors `IPrivacyPool.Withdrawal`. `processooor` is the address allowed to
 * call `pool.withdraw` (always the FxPrivacyEntrypoint in our flows).
 * `data` is the ABI-encoded relay parameters — either standard {@link RelayData}
 * for plain `relay()`, or {@link CrossCurrencyRelayData} for `relayCrossCurrency()`.
 */
export interface Withdrawal {
  readonly processooor: Address;
  readonly data: Hex;
}

export interface WithdrawalProof {
  readonly proof: Groth16Proof;
  readonly publicSignals: PublicSignals;
}

export interface WithdrawalProofInput {
  readonly context: bigint;
  readonly withdrawalAmount: bigint;
  readonly stateMerkleProof: LeanIMTMerkleProof<bigint>;
  readonly aspMerkleProof: LeanIMTMerkleProof<bigint>;
  readonly stateRoot: Hash;
  readonly stateTreeDepth: bigint;
  readonly aspRoot: Hash;
  readonly aspTreeDepth: bigint;
  readonly newSecret: Secret;
  readonly newNullifier: Secret;
}

/**
 * `Withdrawal.data` shape for the vendored 0xbow `relay()` path.
 * Same currency in and out. Use {@link CrossCurrencyRelayData} for FX swaps.
 */
export interface RelayData {
  readonly recipient: Address;
  readonly feeRecipient: Address;
  readonly relayFeeBPS: bigint;
}

/**
 * `Withdrawal.data` shape for the fx-Telarana `relayCrossCurrency()` path
 * exposed by {@link contracts/src/hub/FxPrivacyEntrypoint.sol}. The user's
 * Groth16 `context` commits to the full struct — relayer cannot alter
 * `buyToken` or `minBuyAmount` without invalidating the ZK proof.
 */
export interface CrossCurrencyRelayData {
  readonly recipient: Address;
  readonly feeRecipient: Address;
  readonly relayFeeBPS: bigint;
  readonly buyToken: Address;
  readonly minBuyAmount: bigint;
}
