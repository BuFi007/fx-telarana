// SPDX-License-Identifier: Apache-2.0
//
// Lean ContractsService for the fx-Telarana Privacy Hook SDK.
//
// Adapted from 0xbow's `contracts.service.ts` (Apache-2.0, commit
// a80836a4). 0xbow ships 442 lines with multi-chain dispatch + relayer
// gas-swap helpers; this version is the LEAN surface a dApp needs:
//
//   - deposit (ERC20 path; wraps Entrypoint.deposit + approve)
//   - relay (vendored same-currency)
//   - relayCrossCurrency (fx-Telarana addition)
//   - latestRoot / scopeToPool / poolAsset reads
//
// No snarkjs dependency.

import {
  encodeAbiParameters,
  erc20Abi,
  type Address,
  type Hash as ViemHash,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";

import { encodeCrossCurrencyRelayData } from "../crossCurrency.js";
import type { CrossCurrencyRelayData, RelayData, Withdrawal } from "../types.js";

/** Trimmed ABI fragments — only the calls we wrap. */
const ENTRYPOINT_ABI = [
  {
    type: "function", stateMutability: "view", name: "latestRoot",
    inputs: [], outputs: [{ name: "_root", type: "uint256" }],
  },
  {
    type: "function", stateMutability: "view", name: "scopeToPool",
    inputs:  [{ name: "_scope", type: "uint256" }],
    outputs: [{ name: "_pool",  type: "address" }],
  },
  {
    type: "function", stateMutability: "nonpayable", name: "deposit",
    inputs: [
      { name: "_asset",        type: "address" },
      { name: "_value",        type: "uint256" },
      { name: "_precommitment",type: "uint256" },
    ],
    outputs: [{ name: "_commitment", type: "uint256" }],
  },
  {
    type: "function", stateMutability: "nonpayable", name: "relay",
    inputs: [
      { name: "_withdrawal", type: "tuple", components: [
        { name: "processooor", type: "address" },
        { name: "data",        type: "bytes"   },
      ]},
      { name: "_proof", type: "tuple", components: [
        { name: "pA",         type: "uint256[2]"     },
        { name: "pB",         type: "uint256[2][2]"  },
        { name: "pC",         type: "uint256[2]"     },
        { name: "pubSignals", type: "uint256[8]"     },
      ]},
      { name: "_scope", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function", stateMutability: "nonpayable", name: "relayExecute",
    inputs: [
      { name: "_withdrawal", type: "tuple", components: [
        { name: "processooor", type: "address" },
        { name: "data",        type: "bytes"   },
      ]},
      { name: "_proof", type: "tuple", components: [
        { name: "pA",         type: "uint256[2]"     },
        { name: "pB",         type: "uint256[2][2]"  },
        { name: "pC",         type: "uint256[2]"     },
        { name: "pubSignals", type: "uint256[8]"     },
      ]},
      { name: "_scope", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function", stateMutability: "nonpayable", name: "relayCrossCurrency",
    inputs: [
      { name: "_withdrawal", type: "tuple", components: [
        { name: "processooor", type: "address" },
        { name: "data",        type: "bytes"   },
      ]},
      { name: "_proof", type: "tuple", components: [
        { name: "pA",         type: "uint256[2]"     },
        { name: "pB",         type: "uint256[2][2]"  },
        { name: "pC",         type: "uint256[2]"     },
        { name: "pubSignals", type: "uint256[8]"     },
      ]},
      { name: "_scope", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

const POOL_ABI = [
  {
    type: "function", stateMutability: "view", name: "ASSET",
    inputs: [], outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function", stateMutability: "view", name: "SCOPE",
    inputs: [], outputs: [{ name: "", type: "uint256" }],
  },
] as const;

/**
 * Mirrors the on-chain `ProofLib.WithdrawProof` struct that the
 * vendored entrypoint expects. Consumers normally get this from
 * `WithdrawalService.proveWithdrawal()` in `@bu/privacy-prover` —
 * the field names here match what snarkjs.groth16.fullProve returns,
 * but we declare them as plain `string` to keep the SDK GPL-free.
 */
export interface WithdrawProofTuple {
  readonly pA: [string, string];
  readonly pB: [[string, string], [string, string]];
  readonly pC: [string, string];
  readonly pubSignals: [string, string, string, string, string, string, string, string];
}

/// Encoder for the vendored 0xbow same-currency `RelayData` blob.
export function encodeRelayData(d: RelayData): Hex {
  return encodeAbiParameters(
    [{
      name: "data", type: "tuple", components: [
        { name: "recipient",    type: "address" },
        { name: "feeRecipient", type: "address" },
        { name: "relayFeeBPS",  type: "uint256" },
      ],
    }],
    [{
      recipient:    d.recipient,
      feeRecipient: d.feeRecipient,
      relayFeeBPS:  d.relayFeeBPS,
    }],
  );
}

export class PrivacyContractsService {
  constructor(
    private readonly publicClient: PublicClient,
    private readonly entrypoint:   Address,
  ) {}

  /*//////////////////////////////////////////////////////////////
                            READS
  //////////////////////////////////////////////////////////////*/

  /** Latest ASP root published via `Entrypoint.updateRoot`. Reverts
   *  with `NoRootsAvailable` if none have been pushed yet. */
  async latestRoot(): Promise<bigint> {
    return this.publicClient.readContract({
      address:      this.entrypoint,
      abi:          ENTRYPOINT_ABI,
      functionName: "latestRoot",
    });
  }

  /** Pool address for a given scope (or zero-address if unregistered). */
  async scopeToPool(scope: bigint): Promise<Address> {
    return this.publicClient.readContract({
      address:      this.entrypoint,
      abi:          ENTRYPOINT_ABI,
      functionName: "scopeToPool",
      args:         [scope],
    });
  }

  /** ASSET immutable on a pool — what currency this pool holds. */
  async poolAsset(pool: Address): Promise<Address> {
    return this.publicClient.readContract({
      address:      pool,
      abi:          POOL_ABI,
      functionName: "ASSET",
    });
  }

  /** SCOPE immutable on a pool — what the ZK proof's `scope` signal is. */
  async poolScope(pool: Address): Promise<bigint> {
    return this.publicClient.readContract({
      address:      pool,
      abi:          POOL_ABI,
      functionName: "SCOPE",
    });
  }

  /*//////////////////////////////////////////////////////////////
                            WRITES
  //////////////////////////////////////////////////////////////*/

  /**
   * Approve (if needed) then deposit `value` of `asset` into the
   * privacy pool wired to `asset` on `this.entrypoint`. Returns the
   * resulting commitment hash from the Deposited event after waiting
   * one confirmation.
   */
  async deposit(
    wallet:        WalletClient,
    args: {
      asset: Address;
      value: bigint;
      precommitment: bigint;
      /** Optional approval target check — pass the actual allowance
       *  read result; the helper skips approve if already sufficient. */
      currentAllowance?: bigint;
    },
  ): Promise<ViemHash> {
    if ((args.currentAllowance ?? 0n) < args.value) {
      const approveTx = await wallet.writeContract({
        chain: null,
        account: wallet.account!,
        address: args.asset,
        abi: erc20Abi,
        functionName: "approve",
        args: [this.entrypoint, args.value],
      });
      await this.publicClient.waitForTransactionReceipt({ hash: approveTx });
    }
    return wallet.writeContract({
      chain: null,
      account: wallet.account!,
      address: this.entrypoint,
      abi: ENTRYPOINT_ABI,
      functionName: "deposit",
      args: [args.asset, args.value, args.precommitment],
    });
  }

  /**
   * Same-currency relay. Caller assembles {@link Withdrawal} +
   * {@link WithdrawProofTuple} via `@bu/privacy-prover` and signs
   * via their own relayer. This helper just submits.
   */
  async relay(
    wallet: WalletClient,
    args: {
      withdrawal: Withdrawal;
      proof:      WithdrawProofTuple;
      scope:      bigint;
    },
  ): Promise<ViemHash> {
    return wallet.writeContract({
      chain: null,
      account: wallet.account!,
      address: this.entrypoint,
      abi: ENTRYPOINT_ABI,
      functionName: "relay",
      args: [
        { processooor: args.withdrawal.processooor, data: args.withdrawal.data },
        proofToTuple(args.proof),
        args.scope,
      ],
    });
  }

  /**
   * Submit `relayExecute` — withdraw a shielded note and atomically run a
   * registered execution adapter (Morpho supply / perp margin / spot swap)
   * funded from it. `withdrawal.data` is the ABI-encoded ExecutionRelayData,
   * bound into the proof context so the adapter call can't be redirected.
   * Same proof shape + circuit as `relay` (no new ceremony).
   */
  async relayExecute(
    wallet: WalletClient,
    args: {
      withdrawal: Withdrawal;
      proof:      WithdrawProofTuple;
      scope:      bigint;
    },
  ): Promise<ViemHash> {
    return wallet.writeContract({
      chain: null,
      account: wallet.account!,
      address: this.entrypoint,
      abi: ENTRYPOINT_ABI,
      functionName: "relayExecute",
      args: [
        { processooor: args.withdrawal.processooor, data: args.withdrawal.data },
        proofToTuple(args.proof),
        args.scope,
      ],
    });
  }

  /**
   * Cross-currency relay — fx-Telarana addition (slice 3).
   * The withdrawal.data blob must be the ABI-encoded
   * {@link CrossCurrencyRelayData} that the user's Groth16 `context`
   * commits to.
   */
  async relayCrossCurrency(
    wallet: WalletClient,
    args: {
      proof: WithdrawProofTuple;
      scope: bigint;
      /** processooor MUST be `this.entrypoint`; the helper sets it. */
      data:  CrossCurrencyRelayData;
    },
  ): Promise<ViemHash> {
    const withdrawal: Withdrawal = {
      processooor: this.entrypoint,
      data:        encodeCrossCurrencyRelayData(args.data),
    };
    return wallet.writeContract({
      chain: null,
      account: wallet.account!,
      address: this.entrypoint,
      abi: ENTRYPOINT_ABI,
      functionName: "relayCrossCurrency",
      args: [
        { processooor: withdrawal.processooor, data: withdrawal.data },
        proofToTuple(args.proof),
        args.scope,
      ],
    });
  }
}

/** Convert string-typed proof fields to the bigint tuples viem expects. */
function proofToTuple(p: WithdrawProofTuple): {
  pA: readonly [bigint, bigint];
  pB: readonly [readonly [bigint, bigint], readonly [bigint, bigint]];
  pC: readonly [bigint, bigint];
  pubSignals: readonly [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];
} {
  return {
    pA: [BigInt(p.pA[0]), BigInt(p.pA[1])] as const,
    pB: [
      [BigInt(p.pB[0][0]), BigInt(p.pB[0][1])] as const,
      [BigInt(p.pB[1][0]), BigInt(p.pB[1][1])] as const,
    ] as const,
    pC: [BigInt(p.pC[0]), BigInt(p.pC[1])] as const,
    pubSignals: [
      BigInt(p.pubSignals[0]), BigInt(p.pubSignals[1]),
      BigInt(p.pubSignals[2]), BigInt(p.pubSignals[3]),
      BigInt(p.pubSignals[4]), BigInt(p.pubSignals[5]),
      BigInt(p.pubSignals[6]), BigInt(p.pubSignals[7]),
    ] as const,
  };
}
