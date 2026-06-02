// SPDX-License-Identifier: AGPL-3.0-only
//
// Node-side prover for relayer-api /v1/relayExecute. snarkjs' worker shim can
// crash under Bun during Groth16 proving, so the Bun HTTP service delegates only
// the proof construction to this Node process.

import { readFileSync } from "node:fs";
import { createPublicClient, http } from "viem";
import { proveAndBuildRelayExecute } from "@bu/privacy-prover";

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      data += chunk;
    });
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

function bigintReplacer(_key, value) {
  return typeof value === "bigint" ? value.toString() : value;
}

const startedAt = Date.now();
function progress(event, details = {}) {
  process.stderr.write(JSON.stringify({
    kind: "relayExecuteProverProgress",
    event,
    elapsedMs: Date.now() - startedAt,
    ...details,
  }) + "\n");
}

try {
  const input = JSON.parse(await readStdin());
  progress("input:parsed", {
    hasStateLeaves: Array.isArray(input.stateLeaves),
    stateLeafCount: Array.isArray(input.stateLeaves) ? input.stateLeaves.length : 0,
    hasAspLabels: Array.isArray(input.aspLabels),
    aspLabelCount: Array.isArray(input.aspLabels) ? input.aspLabels.length : 0,
  });
  const publicClient = createPublicClient({ transport: http(input.rpcUrl) });
  const result = await proveAndBuildRelayExecute({
    publicClient,
    pool: input.pool,
    entrypoint: input.entrypoint,
    note: {
      nullifier: BigInt(input.note.nullifier),
      secret: BigInt(input.note.secret),
      value: BigInt(input.note.value),
      label: BigInt(input.note.label),
      commitmentHash: BigInt(input.note.commitmentHash),
    },
    adapterId: BigInt(input.adapterId),
    adapterData: input.adapterData,
    recipient: input.recipient,
    feeRecipient: input.feeRecipient,
    relayFeeBPS: BigInt(input.relayFeeBPS),
    stateLeaves: Array.isArray(input.stateLeaves) ? input.stateLeaves.map((leaf) => BigInt(leaf)) : undefined,
    aspLabels: Array.isArray(input.aspLabels) ? input.aspLabels.map((label) => BigInt(label)) : undefined,
    aspFromBlock: input.aspFromBlock ? BigInt(input.aspFromBlock) : undefined,
    aspMaxRangePerCall: input.aspMaxRangePerCall ? BigInt(input.aspMaxRangePerCall) : undefined,
    wasmBytes: new Uint8Array(readFileSync(`${input.circuitsDir}/withdraw.wasm`)),
    zkeyBytes: new Uint8Array(readFileSync(`${input.circuitsDir}/withdraw.zkey`)),
    searchLoBlock: input.searchLoBlock ? BigInt(input.searchLoBlock) : undefined,
    onProgress: progress,
  });
  progress("result:built", { leafCount: result.leafCount, aspLeafCount: result.aspLeafCount });
  process.stdout.write(JSON.stringify(result, bigintReplacer));
  process.exit(0);
} catch (error) {
  process.stderr.write(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
