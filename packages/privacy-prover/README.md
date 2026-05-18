# @bu/privacy-prover

Groth16 prover for fx-Telarana Privacy Pool withdrawals.

## Why a separate package?

The public SDK `@bu/fx-engine` is Apache-2.0. The Groth16 prover relies on
[`snarkjs`](https://www.npmjs.com/package/snarkjs), which is **GPL-3.0**.
Combining GPL-licensed code into an Apache-distributed package risks
forcing GPL terms onto downstream consumers — a release-level compliance
failure (codex-r8 HIGH finding).

Splitting the prover into this separate package keeps the licensing
boundaries explicit:

| Package | License | Surface |
|---|---|---|
| `@bu/fx-engine` (`/privacy` subpath) | **Apache-2.0** | Types, crypto helpers (Poseidon, Merkle proofs, context hash), circuit-artifact loader interface, cross-currency encoding |
| `@bu/privacy-prover` (this package) | **GPL-3.0** | `WithdrawalService` — wraps `snarkjs.groth16.fullProve` / `.verify` |

dApp consumers who need to generate proofs install `@bu/privacy-prover`
explicitly and accept its GPL terms. Consumers who only need types /
encoding / commitment helpers stay on the Apache SDK alone.

## Usage

```ts
import { WithdrawalService } from "@bu/privacy-prover";
import { UrlCircuits, type WithdrawalProofInput } from "@bu/fx-engine/privacy";

const circuits = new UrlCircuits({
  baseUrl: "https://your-cdn.example/privacy-circuits/",
});
const prover = new WithdrawalService(circuits);

const proof = await prover.proveWithdrawal(commitment, input);
const ok    = await prover.verifyWithdrawal(proof);
```

## Build / test

```bash
bun install
bun run --cwd packages/privacy-prover typecheck
bun run --cwd packages/privacy-prover test
```

## Vendor lineage

Ported from
[`0xbow-io/privacy-pools-core@a80836a4`](https://github.com/0xbow-io/privacy-pools-core/tree/a80836a47451e662f127af17e11430ffa976c234)
`packages/sdk/src/core/withdrawal.service.ts`. Sole modification: import
paths now reference `@bu/fx-engine/privacy` for types + circuit interface.
No algorithmic changes.
