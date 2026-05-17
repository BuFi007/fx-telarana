// SPDX-License-Identifier: Apache-2.0
//
// Vendored from 0xbow-io/privacy-pools-core sdk/src/crypto.ts (Apache-2.0).
// Modifications:
//   - Import paths localized to this SDK.
//   - File-private validateNonZero unchanged.
// No algorithmic changes.

import { LeanIMT, type LeanIMTMerkleProof } from "@zk-kit/lean-imt";
import { poseidon } from "maci-crypto/build/ts/hashing.js";
import {
  encodeAbiParameters,
  keccak256,
  numberToHex,
  type Hex,
} from "viem";
import { mnemonicToAccount } from "viem/accounts";
import { bytesToBigInt } from "viem/utils";

import { SNARK_SCALAR_FIELD } from "./constants.js";
import { ErrorCode, PrivacyPoolError } from "./exceptions.js";
import type {
  Commitment,
  Hash,
  MasterKeys,
  Secret,
  Withdrawal,
} from "./types.js";

function validateNonZero(value: bigint, name: string): void {
  if (value === 0n) {
    throw new PrivacyPoolError(
      ErrorCode.INVALID_VALUE,
      `Invalid input: '${name}' cannot be zero.`,
    );
  }
}

/** Derive (masterNullifier, masterSecret) from a BIP-39 mnemonic. */
export function generateMasterKeys(mnemonic: string): MasterKeys {
  if (!mnemonic) {
    throw new PrivacyPoolError(
      ErrorCode.INVALID_VALUE,
      "Invalid input: mnemonic phrase is required.",
    );
  }
  // NB: 0xbow original used viem's `bytesToNumber`, which throws on bigints
  // outside Number.MAX_SAFE_INTEGER. Modern viem renamed the bigint variant
  // to `bytesToBigInt`. Functionally identical to the upstream intent —
  // we just read the full 32-byte private key as a bigint.
  const key1 = bytesToBigInt(
    mnemonicToAccount(mnemonic, { accountIndex: 0 }).getHdKey().privateKey!,
  );
  const key2 = bytesToBigInt(
    mnemonicToAccount(mnemonic, { accountIndex: 1 }).getHdKey().privateKey!,
  );
  return {
    masterNullifier: poseidon([key1]) as Secret,
    masterSecret: poseidon([key2]) as Secret,
  };
}

/** Derive a deposit (nullifier, secret) pair from master keys + scope + index. */
export function generateDepositSecrets(
  keys: MasterKeys,
  scope: Hash,
  index: bigint,
): { nullifier: Secret; secret: Secret } {
  const nullifier = poseidon([keys.masterNullifier, scope, index]) as Secret;
  const secret = poseidon([keys.masterSecret, scope, index]) as Secret;
  return { nullifier, secret };
}

/** Derive a withdrawal (nullifier, secret) pair from master keys + label + index. */
export function generateWithdrawalSecrets(
  keys: MasterKeys,
  label: Hash,
  index: bigint,
): { nullifier: Secret; secret: Secret } {
  const nullifier = poseidon([keys.masterNullifier, label, index]) as Secret;
  const secret = poseidon([keys.masterSecret, label, index]) as Secret;
  return { nullifier, secret };
}

/** Poseidon([nullifier, secret]) — the precommitment hash deposited on-chain. */
export function hashPrecommitment(nullifier: Secret, secret: Secret): Hash {
  return poseidon([nullifier, secret]) as Hash;
}

/** Build a full Commitment given (value, label, nullifier, secret). */
export function getCommitment(
  value: bigint,
  label: bigint,
  nullifier: Secret,
  secret: Secret,
): Commitment {
  validateNonZero(nullifier as bigint, "nullifier");
  validateNonZero(label, "label");
  validateNonZero(secret as bigint, "secret");

  const precommitment = {
    hash: hashPrecommitment(nullifier, secret),
    nullifier,
    secret,
  };
  const hash = poseidon([value, label, precommitment.hash]) as Hash;
  return {
    hash,
    nullifierHash: precommitment.hash,
    preimage: { value, label, precommitment },
  };
}

/** Generate a LeanIMT inclusion proof for `leaf` over `leaves`. Pads siblings to 32. */
export function generateMerkleProof(
  leaves: bigint[],
  leaf: bigint,
): LeanIMTMerkleProof<bigint> {
  const tree = new LeanIMT<bigint>((a: bigint, b: bigint) => poseidon([a, b]));
  tree.insertMany(leaves);
  const idx = tree.indexOf(leaf);
  if (idx === -1) {
    throw new PrivacyPoolError(
      ErrorCode.MERKLE_ERROR,
      "Leaf not found in the leaves array.",
    );
  }
  const proof = tree.generateProof(idx);
  if (proof.siblings.length < 32) {
    proof.siblings = [
      ...proof.siblings,
      ...Array<bigint>(32 - proof.siblings.length).fill(0n),
    ];
  }
  return proof;
}

/** Format a bigint as a 0x-prefixed 32-byte hex string, branded as Hash. */
export function bigintToHash(value: bigint): Hash {
  return `0x${value.toString(16).padStart(64, "0")}` as unknown as Hash;
}

/** Format a bigint (or string) as a 0x-prefixed 32-byte hex string. */
export function bigintToHex(num: bigint | string | undefined): Hex {
  if (num === undefined) throw new Error("Undefined bigint value!");
  return `0x${BigInt(num).toString(16).padStart(64, "0")}`;
}

/**
 * Match `PrivacyPool.validWithdrawal`:
 *   context = keccak256(abi.encode(_withdrawal, SCOPE)) % SNARK_SCALAR_FIELD
 * The user's Groth16 proof binds against this hash, so the relayer cannot
 * alter `processooor` or `data` between proof gen and on-chain call.
 */
export function calculateContext(
  withdrawal: Withdrawal,
  scope: Hash,
): Hex {
  const hash =
    BigInt(
      keccak256(
        encodeAbiParameters(
          [
            {
              name: "withdrawal",
              type: "tuple",
              components: [
                { name: "processooor", type: "address" },
                { name: "data", type: "bytes" },
              ],
            },
            { name: "scope", type: "uint256" },
          ],
          [
            { processooor: withdrawal.processooor, data: withdrawal.data },
            scope,
          ],
        ),
      ),
    ) % SNARK_SCALAR_FIELD;
  return numberToHex(hash);
}
