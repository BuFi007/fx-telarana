// SPDX-License-Identifier: GPL-3.0
//
// Standalone prover smoke. Run with `bun run scripts/smoke.ts` from the
// privacy-prover package. Logs each pipeline step so a hang can be
// localized to witness gen / proof gen / verify.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import * as snarkjs from "snarkjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

import {
  CircuitName,
  bigintToHash,
  calculateContext,
  generateMerkleProof,
  getCommitment,
  type CircuitsInterface,
  type Secret,
  type Withdrawal,
} from "@bu/fx-engine/privacy";

import { WithdrawalService } from "../src/withdrawal.js";

class FsCircuits implements CircuitsInterface {
  constructor(private readonly dir: string) {}
  private read(name: string): Uint8Array {
    return new Uint8Array(readFileSync(join(this.dir, name)));
  }
  async getWasm(c: CircuitName) { return this.read(`${c}.wasm`); }
  async getProvingKey(c: CircuitName) { return this.read(`${c}.zkey`); }
  async getVerificationKey(c: CircuitName) { return this.read(`${c}.vkey.json`); }
}

const t0 = Date.now();
const log = (msg: string) => console.log(`[${((Date.now() - t0) / 1000).toFixed(2)}s] ${msg}`);

log("loading circuits");
const circuits = new FsCircuits(join(__dirname, "..", "circuits"));
const service = new WithdrawalService(circuits);

const nullifier = 12345678901234567890n as Secret;
const secret    = 98765432109876543210n as Secret;
const value     = 1_000_000n;
const label     = 42n;

log("building commitment + state tree");
const commitment = getCommitment(value, label, nullifier, secret);
log(`commitment.hash = ${commitment.hash}`);

const stateMerkleProof = generateMerkleProof(
  [commitment.hash as unknown as bigint],
  commitment.hash as unknown as bigint,
);
log(`state root = ${stateMerkleProof.root}, siblings.length = ${stateMerkleProof.siblings.length}, index = ${stateMerkleProof.index}`);

const aspMerkleProof = generateMerkleProof([label], label);
log(`asp root = ${aspMerkleProof.root}, siblings.length = ${aspMerkleProof.siblings.length}`);

const withdrawal: Withdrawal = {
  processooor: "0x0000000000000000000000000000000000000002",
  data: "0x",
};
const scope = bigintToHash(999_999n);
const contextHex = calculateContext(withdrawal, scope);
const context = BigInt(contextHex);
log(`context = ${context}`);

const newNullifier = 11111111111111111111n as Secret;
const newSecret    = 22222222222222222222n as Secret;

// Hand-roll the input signals so we can see exactly what snarkjs gets.
const inputSignals = {
  withdrawnValue: value,
  stateRoot: BigInt(bigintToHash(stateMerkleProof.root)),
  stateTreeDepth: BigInt(stateMerkleProof.siblings.length),
  ASPRoot: BigInt(bigintToHash(aspMerkleProof.root)),
  ASPTreeDepth: BigInt(aspMerkleProof.siblings.length),
  context,

  label,
  existingValue: value,
  existingNullifier: nullifier,
  existingSecret: secret,
  newNullifier,
  newSecret,

  stateSiblings: stateMerkleProof.siblings,
  stateIndex: BigInt(stateMerkleProof.index),
  ASPSiblings: aspMerkleProof.siblings,
  ASPIndex: BigInt(aspMerkleProof.index),
};
log("input signals built — keys: " + Object.keys(inputSignals).join(", "));
log(`stateSiblings sample: [0]=${stateMerkleProof.siblings[0]}, [1]=${stateMerkleProof.siblings[1]}`);

log("loading wasm + zkey from disk");
const wasm = await circuits.getWasm(CircuitName.Withdraw);
const zkey = await circuits.getProvingKey(CircuitName.Withdraw);
log(`wasm size = ${wasm.length}, zkey size = ${zkey.length}`);

log("calling snarkjs.groth16.fullProve");
const result = await snarkjs.groth16.fullProve(inputSignals, wasm, zkey);
log("fullProve returned — verifying");

const vkeyBin = await circuits.getVerificationKey(CircuitName.Withdraw);
const vkey = JSON.parse(new TextDecoder("utf-8").decode(vkeyBin));
const ok = await snarkjs.groth16.verify(vkey, result.publicSignals, result.proof);
log(`verify result = ${ok}`);

// Note: snarkjs leaks worker threads on completion; exit explicitly.
process.exit(ok ? 0 : 1);
