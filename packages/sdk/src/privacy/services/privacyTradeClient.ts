// SPDX-License-Identifier: Apache-2.0
//
// PrivacyTradeClient — the integrator-ergonomic facade over the Privacy
// Hook deploys on fx-Telaraña. Designed for a Synthra-style "trade tab"
// where a frontend needs to:
//
//   1. Shield USDC (or EURC) into a privacy pool.
//   2. Replay the pool's state tree to build a Merkle inclusion proof.
//   3. Get a quote for what the cross-currency adapter will deliver.
//   4. Relay the withdrawal — same-currency or cross-currency — to a
//      fresh recipient.
//
// What this class is NOT:
//   * A prover. Groth16 proving lives in @bu/privacy-prover (GPL-3.0).
//     Consumers wire an IWithdrawalProver implementation themselves;
//     this SDK stays Apache-2.0.
//   * An ASP postman. For testnet integration the bundled `relayer-privacy`
//     service publishes roots; for self-service workflows ops can call
//     `publishAspRootForLabel` (requires ASP_POSTMAN role).
//
// What this class IS:
//   * Bundled deployment metadata (no JSON discovery dance).
//   * A single concrete `shield`, `relay`, `relayCrossCurrency` flow
//     that closes the b5-deposit/b5-withdraw/b5-cross-currency loops
//     into ~3 method calls.
//   * The state-tree replay logic from b5-cross-currency promoted to a
//     reusable `buildStateMerkleProof` helper.
//   * JSON-serializable `ShieldedNote` shape so frontends can stash
//     notes in IndexedDB / localStorage / wallet metadata.

import {
  decodeEventLog,
  parseAbi,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";

import {
  bigintToHash,
  calculateContext,
  generateMerkleProof,
  getCommitment,
} from "../crypto.js";
import { encodeCrossCurrencyRelayData } from "../crossCurrency.js";
import type {
  Commitment,
  Secret,
  Withdrawal,
  WithdrawalProofInput,
} from "../types.js";
import {
  PrivacyContractsService,
  type WithdrawProofTuple,
} from "./contractsService.js";

/*//////////////////////////////////////////////////////////////
                    BUNDLED DEPLOYMENT METADATA
//////////////////////////////////////////////////////////////*/

export interface PrivacyPoolEntry {
  asset: Address;
  pool: Address;
  /** Pool's SCOPE() — the scalar the ZK circuit binds withdrawals to.
   *  Cached here so callers don't pay a chain round-trip per shield. */
  scope: bigint;
}

export interface PrivacyChainConfig {
  chainId: number;
  /** UUPS proxy address — what every dApp call routes through. */
  entrypoint: Address;
  /** Asset-symbol → pool entry. Keys are the user-facing symbol
   *  ("USDC", "EURC"); values include the canonical token address. */
  pools: Record<string, PrivacyPoolEntry>;
  /** Earliest block that the entrypoint or any registered pool emitted
   *  a `LeafInserted` event. Used as the lower bound of state-tree
   *  replay scans. Set to a few blocks before the pool's deploy. */
  poolDeployBlock: bigint;
  /** Max blocks per `eth_getLogs` call when scanning. Fuji caps at 2048;
   *  Arc accepts 5000. Lower if a slower RPC provider is in use. */
  maxRangePerCall: bigint;
}

/** Live testnet configs as of 2026-05-19. Pulled from
 *  `deployments/privacy-hook-{fuji,arc}.json`. The intent is that this
 *  table moves with each deploy: new chain, new pool — extend here. */
export const PRIVACY_CHAIN_CONFIGS: Record<number, PrivacyChainConfig> = {
  // Arc Testnet (chainId 5042002) — both USDC + EURC pools live, plus
  // the FxFixedRateSwapAdapter wired for cross-currency relay.
  5042002: {
    chainId: 5042002,
    entrypoint: "0xD11cDdd1f04e850d3810a71608A49907c80f2736",
    pools: {
      USDC: {
        asset: "0x3600000000000000000000000000000000000000",
        pool:  "0xC11C216C9C7A36848b1d4276d223160C8b51988f",
        scope: 13628782019290114344365157513531312776376936678300719745279061801973571818236n,
      },
      EURC: {
        asset: "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a",
        pool:  "0x7B4582CDE65c8cC00fE24B16dBA60472242d234c",
        scope: 10011405322814872543637273959896594613590433782049698944750253296575874394014n,
      },
    },
    poolDeployBlock: 43028000n,
    maxRangePerCall: 5000n,
  },
  // Avalanche Fuji (chainId 43113) — USDC pool only; cross-currency
  // NOT wired yet (the EURC leg uses MockEURC which isn't user-
  // acquirable). Keep here so dApp consumers can still surface
  // shield/unshield USDC on Fuji.
  43113: {
    chainId: 43113,
    entrypoint: "0x6d5e3D5bE0Be2B29D48EDa2FA35Fa8d787D3C953",
    pools: {
      USDC: {
        asset: "0x5425890298aed601595a70AB815c96711a31Bc65",
        pool:  "0xc490be46d2b87b92f146ab4dd907784d9658ec7f",
        scope: 5594775015131676537123875777635026991245615980477498729933033198192734863221n,
      },
    },
    poolDeployBlock: 55529759n,
    // Avalanche Fuji's public RPC caps eth_getLogs at 2048 blocks per
    // call (see packages/relayer-privacy/.env.fuji.example).
    maxRangePerCall: 2000n,
  },
};

/*//////////////////////////////////////////////////////////////
                        PROVER INTERFACE
//////////////////////////////////////////////////////////////*/

/** What the trade client needs from a prover. Consumers wire the GPL
 *  `@bu/privacy-prover` package (or a hosted proving service) and
 *  inject it here — keeps PrivacyTradeClient itself Apache-clean. */
export interface IWithdrawalProver {
  proveWithdrawal(
    commitment: Commitment,
    input: WithdrawalProofInput,
  ): Promise<{
    proof: {
      pi_a: string[];
      pi_b: string[][];
      pi_c: string[];
      [k: string]: unknown;
    };
    publicSignals: string[];
  }>;
}

/*//////////////////////////////////////////////////////////////
                        SHIELDED NOTE
//////////////////////////////////////////////////////////////*/

/** Portable shape of a deposit position. JSON-safe via
 *  `PrivacyTradeClient.serializeNote` / `deserializeNote`. dApps
 *  typically persist this in IndexedDB or encrypted local storage. */
export interface ShieldedNote {
  asset: Address;
  pool: Address;
  scope: bigint;
  value: bigint;
  nullifier: bigint;
  secret: bigint;
  /** Pool-assigned label (parsed from Deposited event). Required for
   *  ASP-tree inclusion at withdraw time. */
  label: bigint;
  /** Pool's commitment hash from the Deposited event. Equals
   *  poseidon([value, label, poseidon([nullifier, secret])]). */
  commitmentHash: bigint;
}

/*//////////////////////////////////////////////////////////////
                        INTERNAL ABIS
//////////////////////////////////////////////////////////////*/

const POOL_ABI = parseAbi([
  "function SCOPE() view returns (uint256)",
  "function currentRoot() view returns (uint256)",
  "event LeafInserted(uint256 _index, uint256 _leaf, uint256 _root)",
  "event Deposited(address indexed depositor, uint256 commitment, uint256 label, uint256 value, uint256 precommitmentHash)",
]);

const ENTRYPOINT_ABI = parseAbi([
  "function updateRoot(uint256 root, string ipfsCID) returns (uint256 index)",
  "function latestRoot() view returns (uint256)",
  "function swapAdapter() view returns (address)",
]);

const ADAPTER_ABI = parseAbi([
  "function rate(address sellToken, address buyToken) view returns (uint256)",
  "function enabled(address sellToken, address buyToken) view returns (bool)",
]);

const ERC20_ABI = parseAbi([
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
]);

/*//////////////////////////////////////////////////////////////
                        UTILITIES
//////////////////////////////////////////////////////////////*/

/** Generates a uniformly-random field element under BN254's scalar
 *  field. Uses `crypto.getRandomValues` so it works in both Node and
 *  browsers. 248 bits — comfortably below 2^252 (the field max). */
function randomFieldElement(): bigint {
  const buf = new Uint8Array(31);
  crypto.getRandomValues(buf);
  let v = 0n;
  for (const b of buf) v = (v << 8n) | BigInt(b);
  return v;
}

/*//////////////////////////////////////////////////////////////
                    PRIVACY TRADE CLIENT
//////////////////////////////////////////////////////////////*/

export class PrivacyTradeClient {
  private readonly contracts: PrivacyContractsService;

  constructor(
    public readonly config: PrivacyChainConfig,
    private readonly publicClient: PublicClient,
    private readonly walletClient: WalletClient,
    private readonly prover: IWithdrawalProver,
  ) {
    this.contracts = new PrivacyContractsService(
      publicClient,
      config.entrypoint,
    );
  }

  /** Bundled-metadata factory. Throws if the chainId isn't registered
   *  in `PRIVACY_CHAIN_CONFIGS`. */
  static forChain(opts: {
    chainId: number;
    publicClient: PublicClient;
    walletClient: WalletClient;
    prover: IWithdrawalProver;
  }): PrivacyTradeClient {
    const config = PRIVACY_CHAIN_CONFIGS[opts.chainId];
    if (!config) {
      throw new Error(
        `PrivacyTradeClient: no config for chainId ${opts.chainId}. ` +
        `Known: ${Object.keys(PRIVACY_CHAIN_CONFIGS).join(", ")}`,
      );
    }
    return new PrivacyTradeClient(
      config,
      opts.publicClient,
      opts.walletClient,
      opts.prover,
    );
  }

  /** Pool entry for a user-facing asset symbol. */
  pool(symbol: string): PrivacyPoolEntry {
    const e = this.config.pools[symbol];
    if (!e) {
      throw new Error(
        `PrivacyTradeClient: no pool for ${symbol} on chain ${this.config.chainId}. ` +
        `Available: ${Object.keys(this.config.pools).join(", ")}`,
      );
    }
    return e;
  }

  /*//////////////////////////////////////////////////////////
                            SHIELD
  //////////////////////////////////////////////////////////*/

  /**
   * Shield `value` units of the asset whose user-facing symbol is
   * `assetSymbol`. Generates fresh secrets, approves the entrypoint,
   * calls `Entrypoint.deposit`, parses the `Deposited` event from the
   * pool to recover the assigned label, and returns a `ShieldedNote`.
   *
   * The note must be stored by the dApp — this SDK doesn't persist
   * anything. Without the (nullifier, secret) pair the deposit is
   * unrecoverable (other than via ragequit, which costs the funds).
   */
  async shield(args: {
    assetSymbol: string;
    value: bigint;
  }): Promise<{ note: ShieldedNote; txHash: Hex }> {
    const entry = this.pool(args.assetSymbol);

    const nullifier = randomFieldElement() as Secret;
    const secret    = randomFieldElement() as Secret;

    // The pool stamps the label itself (poseidon over scope + index);
    // we don't know it yet. Use any placeholder for the local stub —
    // we only need the precommitment hash now, and the canonical hash
    // we re-derive after the Deposited event arrives.
    const stub = getCommitment(args.value, 1n, nullifier, secret);
    const precommitmentHash = stub.preimage.precommitment.hash as unknown as bigint;

    const allowance = await this.publicClient.readContract({
      address: entry.asset,
      abi: ERC20_ABI,
      functionName: "allowance",
      args: [this.walletClient.account!.address, this.config.entrypoint],
    }) as bigint;

    const depositTx = await this.contracts.deposit(this.walletClient, {
      asset: entry.asset,
      value: args.value,
      precommitment: precommitmentHash,
      currentAllowance: allowance,
    });
    const receipt = await this.publicClient.waitForTransactionReceipt({
      hash: depositTx,
    });

    // Parse Deposited event from the pool — gives us the assigned label.
    let label: bigint | null = null;
    let commitmentHash: bigint | null = null;
    for (const l of receipt.logs) {
      if (l.address.toLowerCase() !== entry.pool.toLowerCase()) continue;
      try {
        const decoded = decodeEventLog({
          abi: POOL_ABI,
          data: l.data,
          topics: l.topics,
        });
        if (decoded.eventName === "Deposited") {
          const a = decoded.args as {
            label: bigint;
            commitment: bigint;
            value: bigint;
            precommitmentHash: bigint;
          };
          if (a.precommitmentHash !== precommitmentHash) continue;
          label = a.label;
          commitmentHash = a.commitment;
          break;
        }
      } catch {
        /* not a Deposited log */
      }
    }
    if (label === null || commitmentHash === null) {
      throw new Error(
        "PrivacyTradeClient.shield: failed to decode Deposited event " +
        "for our precommitment from receipt logs",
      );
    }

    // Sanity: local commitment must match the chain's.
    const local = getCommitment(
      args.value,
      label,
      nullifier,
      secret,
    );
    if ((local.hash as unknown as bigint) !== commitmentHash) {
      throw new Error(
        `PrivacyTradeClient.shield: local commitment ${local.hash} ` +
        `disagrees with chain commitment ${commitmentHash}`,
      );
    }

    return {
      note: {
        asset:          entry.asset,
        pool:           entry.pool,
        scope:          entry.scope,
        value:          args.value,
        nullifier:      nullifier as unknown as bigint,
        secret:         secret as unknown as bigint,
        label,
        commitmentHash,
      },
      txHash: depositTx,
    };
  }

  /*//////////////////////////////////////////////////////////
                    STATE-TREE REPLAY
  //////////////////////////////////////////////////////////*/

  /**
   * Reconstruct the pool's on-chain state tree by replaying
   * `LeafInserted` events from `config.poolDeployBlock` to head. Returns
   * the Merkle inclusion proof for the given commitment. Validates the
   * resulting local root against `pool.currentRoot()` — divergence
   * means the scan missed leaves (raise `poolDeployBlock` lookback or
   * widen `maxRangePerCall`).
   */
  async buildStateMerkleProof(note: ShieldedNote) {
    const head = await this.publicClient.getBlockNumber();
    const leaves: bigint[] = [];
    let cursor = this.config.poolDeployBlock;
    while (cursor <= head) {
      const end =
        cursor + this.config.maxRangePerCall - 1n > head
          ? head
          : cursor + this.config.maxRangePerCall - 1n;
      const logs = await this.publicClient.getContractEvents({
        address:   note.pool,
        abi:       POOL_ABI,
        eventName: "LeafInserted",
        fromBlock: cursor,
        toBlock:   end,
      });
      for (const ev of logs) {
        const args = ev.args as { _leaf?: bigint };
        if (typeof args._leaf === "bigint") leaves.push(args._leaf);
      }
      cursor = end + 1n;
    }
    const proof = generateMerkleProof(leaves, note.commitmentHash);
    const onChainRoot = await this.publicClient.readContract({
      address:      note.pool,
      abi:          POOL_ABI,
      functionName: "currentRoot",
    }) as bigint;
    if (onChainRoot !== proof.root) {
      throw new Error(
        `PrivacyTradeClient.buildStateMerkleProof: local root ${proof.root} ` +
        `≠ on-chain root ${onChainRoot}. Replay missed leaves; ` +
        `raise lookback or check maxRangePerCall.`,
      );
    }
    return proof;
  }

  /*//////////////////////////////////////////////////////////
                    ASP ROOT PUBLISHING
  //////////////////////////////////////////////////////////*/

  /**
   * Publish a single-leaf ASP root that approves `label`. Requires the
   * wallet's account to hold the entrypoint's `ASP_POSTMAN` role.
   *
   * Production: a dedicated postman process handles this. This helper
   * is for testnet / self-service flows.
   */
  async publishAspRootForLabel(
    label: bigint,
    cidPrefix?: string,
  ): Promise<{ root: bigint; cid: string; txHash: Hex }> {
    const cid = (cidPrefix ?? `permissive-root-${Date.now().toString(36)}`)
      .padEnd(40, "x")
      .slice(0, 64);
    const txHash = await this.walletClient.writeContract({
      chain:        null,
      account:      this.walletClient.account!,
      address:      this.config.entrypoint,
      abi:          ENTRYPOINT_ABI,
      functionName: "updateRoot",
      args:         [label, cid],
    });
    await this.publicClient.waitForTransactionReceipt({ hash: txHash });
    return { root: label, cid, txHash };
  }

  /*//////////////////////////////////////////////////////////
                    QUOTES
  //////////////////////////////////////////////////////////*/

  /**
   * Quote the buy-token amount a cross-currency relay would deliver
   * BEFORE the relayer fee skim. Reads `entrypoint.swapAdapter()`, then
   * the adapter's `rate(sellToken, buyToken)` and `enabled(...)` map.
   *
   * Returns null when the pair isn't enabled or the rate isn't set.
   */
  async quoteCrossCurrency(args: {
    note: ShieldedNote;
    buyAssetSymbol: string;
  }): Promise<{ rate: bigint; expectedBuy: bigint } | null> {
    const buyEntry = this.pool(args.buyAssetSymbol);
    const adapter = await this.publicClient.readContract({
      address:      this.config.entrypoint,
      abi:          ENTRYPOINT_ABI,
      functionName: "swapAdapter",
    });
    if (adapter === "0x0000000000000000000000000000000000000000") return null;

    const [rate, enabled] = await Promise.all([
      this.publicClient.readContract({
        address:      adapter,
        abi:          ADAPTER_ABI,
        functionName: "rate",
        args:         [args.note.asset, buyEntry.asset],
      }) as Promise<bigint>,
      this.publicClient.readContract({
        address:      adapter,
        abi:          ADAPTER_ABI,
        functionName: "enabled",
        args:         [args.note.asset, buyEntry.asset],
      }) as Promise<boolean>,
    ]);
    if (!enabled || rate === 0n) return null;
    const expectedBuy = (args.note.value * rate) / 10n ** 18n;
    return { rate, expectedBuy };
  }

  /*//////////////////////////////////////////////////////////
                    SAME-CURRENCY RELAY
  //////////////////////////////////////////////////////////*/

  /** Full same-currency withdraw flow: build proof, submit
   *  `relay()`. Caller is responsible for ensuring ASP root coverage
   *  (call `publishAspRootForLabel` first or wait for the postman). */
  async relay(args: {
    note: ShieldedNote;
    recipient: Address;
    feeRecipient?: Address;
    relayFeeBPS?: bigint;
  }): Promise<{ txHash: Hex }> {
    const { proof, withdrawal, scope } = await this._buildWithdrawalProof({
      note: args.note,
      crossCurrency: null,
      sameCurrency: {
        recipient:    args.recipient,
        feeRecipient: args.feeRecipient ?? args.recipient,
        relayFeeBPS:  args.relayFeeBPS  ?? 0n,
      },
    });
    const txHash = await this.contracts.relay(this.walletClient, {
      withdrawal,
      proof,
      scope,
    });
    return { txHash };
  }

  /*//////////////////////////////////////////////////////////
                    CROSS-CURRENCY RELAY
  //////////////////////////////////////////////////////////*/

  /** Full cross-currency withdraw flow: shield in `note.asset`, deliver
   *  in `buyAssetSymbol` to a fresh `recipient`. `minBuyAmount` is
   *  proof-bound; choose tight enough to defend against owner-side
   *  rate manipulation (see codex-r11 MED on rate front-run). */
  async relayCrossCurrency(args: {
    note: ShieldedNote;
    recipient: Address;
    buyAssetSymbol: string;
    minBuyAmount: bigint;
    feeRecipient?: Address;
    relayFeeBPS?: bigint;
  }): Promise<{ txHash: Hex }> {
    const buyEntry = this.pool(args.buyAssetSymbol);
    const crossData = {
      recipient:    args.recipient,
      feeRecipient: args.feeRecipient ?? args.recipient,
      relayFeeBPS:  args.relayFeeBPS  ?? 0n,
      buyToken:     buyEntry.asset,
      minBuyAmount: args.minBuyAmount,
    };
    const { proof, scope } = await this._buildWithdrawalProof({
      note: args.note,
      crossCurrency: crossData,
      sameCurrency:  null,
    });
    const txHash = await this.contracts.relayCrossCurrency(this.walletClient, {
      data: crossData,
      proof,
      scope,
    });
    return { txHash };
  }

  /*//////////////////////////////////////////////////////////
                    INTERNAL — PROOF ASSEMBLY
  //////////////////////////////////////////////////////////*/

  /** Common path for both relay flavors: build state + ASP proofs,
   *  encode RelayData OR CrossCurrencyRelayData, hash context, drive
   *  the prover, reshape for Solidity. */
  private async _buildWithdrawalProof(args: {
    note: ShieldedNote;
    sameCurrency: {
      recipient:    Address;
      feeRecipient: Address;
      relayFeeBPS:  bigint;
    } | null;
    crossCurrency: {
      recipient:    Address;
      feeRecipient: Address;
      relayFeeBPS:  bigint;
      buyToken:     Address;
      minBuyAmount: bigint;
    } | null;
  }): Promise<{
    proof: WithdrawProofTuple;
    withdrawal: Withdrawal;
    scope: bigint;
  }> {
    // Build state + ASP proofs.
    const stateMerkleProof = await this.buildStateMerkleProof(args.note);
    // ASP tree is single-leaf with just our note's label. Caller must
    // have published this as the latestRoot before this call.
    const aspMerkleProof = generateMerkleProof([args.note.label], args.note.label);

    // Build the Withdrawal blob (and the encoded `data`).
    let data: Hex;
    if (args.crossCurrency) {
      data = encodeCrossCurrencyRelayData(args.crossCurrency);
    } else if (args.sameCurrency) {
      // Same shape as encodeRelayData in contractsService; inline to
      // avoid import cycles. RelayData {recipient, feeRecipient,
      // relayFeeBPS}.
      const { encodeAbiParameters } = await import("viem");
      data = encodeAbiParameters(
        [
          { type: "address", name: "recipient" },
          { type: "address", name: "feeRecipient" },
          { type: "uint256", name: "relayFeeBPS" },
        ],
        [
          args.sameCurrency.recipient,
          args.sameCurrency.feeRecipient,
          args.sameCurrency.relayFeeBPS,
        ],
      );
    } else {
      throw new Error("PrivacyTradeClient: must supply sameCurrency XOR crossCurrency");
    }
    const withdrawal: Withdrawal = {
      processooor: this.config.entrypoint,
      data,
    };
    const contextHex = calculateContext(withdrawal, bigintToHash(args.note.scope));
    const context = BigInt(contextHex);

    // Fresh post-withdraw secrets (for the change note).
    const newNullifier = randomFieldElement() as Secret;
    const newSecret    = randomFieldElement() as Secret;

    // Drive the prover.
    const commitment = getCommitment(
      args.note.value,
      args.note.label,
      args.note.nullifier as unknown as Secret,
      args.note.secret as unknown as Secret,
    );
    const input: WithdrawalProofInput = {
      context,
      withdrawalAmount: args.note.value, // full withdraw
      stateMerkleProof,
      aspMerkleProof,
      stateRoot:       bigintToHash(stateMerkleProof.root),
      stateTreeDepth:  BigInt(stateMerkleProof.siblings.length),
      aspRoot:         bigintToHash(aspMerkleProof.root),
      aspTreeDepth:    BigInt(aspMerkleProof.siblings.length),
      newSecret,
      newNullifier,
    };
    const { proof, publicSignals } = await this.prover.proveWithdrawal(commitment, input);
    if (publicSignals.length !== 8) {
      throw new Error(`Unexpected publicSignals length ${publicSignals.length}, want 8`);
    }

    // Reshape for Solidity. pi_b inner pairs reversed for BN254
    // pairing (codex-r10 MED #2).
    const tuple: WithdrawProofTuple = {
      pA: [proof.pi_a[0]!, proof.pi_a[1]!],
      pB: [
        [proof.pi_b[0]![1]!, proof.pi_b[0]![0]!],
        [proof.pi_b[1]![1]!, proof.pi_b[1]![0]!],
      ],
      pC: [proof.pi_c[0]!, proof.pi_c[1]!],
      pubSignals: publicSignals as unknown as WithdrawProofTuple["pubSignals"],
    };

    return { proof: tuple, withdrawal, scope: args.note.scope };
  }

  /*//////////////////////////////////////////////////////////
                    SERIALIZE / DESERIALIZE
  //////////////////////////////////////////////////////////*/

  /** JSON-safe serialization. All bigints become decimal strings. */
  static serializeNote(n: ShieldedNote): string {
    return JSON.stringify({
      asset:          n.asset,
      pool:           n.pool,
      scope:          n.scope.toString(),
      value:          n.value.toString(),
      nullifier:      n.nullifier.toString(),
      secret:         n.secret.toString(),
      label:          n.label.toString(),
      commitmentHash: n.commitmentHash.toString(),
    });
  }

  /** Inverse of {@link serializeNote}. Throws if any required field
   *  is missing or malformed. */
  static deserializeNote(s: string): ShieldedNote {
    const o = JSON.parse(s);
    const need = ["asset", "pool", "scope", "value", "nullifier", "secret", "label", "commitmentHash"];
    for (const k of need) {
      if (typeof o[k] !== "string") {
        throw new Error(`deserializeNote: field "${k}" must be a string, got ${typeof o[k]}`);
      }
    }
    return {
      asset:          o.asset as Address,
      pool:           o.pool  as Address,
      scope:          BigInt(o.scope),
      value:          BigInt(o.value),
      nullifier:      BigInt(o.nullifier),
      secret:         BigInt(o.secret),
      label:          BigInt(o.label),
      commitmentHash: BigInt(o.commitmentHash),
    };
  }
}
