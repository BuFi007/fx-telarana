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

## Circuit artifacts

The Groth16 prover needs four binary files at runtime:

| File | Purpose | Size | Shipped how |
|---|---|---:|---|
| `commitment.vkey.json` | Verifying key (commitment circuit) | 3 KB | ✅ committed to `circuits/` |
| `withdraw.vkey.json` | Verifying key (withdraw circuit) | 4 KB | ✅ committed to `circuits/` |
| `commitment.wasm` | Witness generator (commitment) | 2.3 MB | downloaded by `circuits:fetch` |
| `withdraw.wasm` | Witness generator (withdraw) | 2.5 MB | downloaded by `circuits:fetch` |
| `commitment.zkey` | Proving key (commitment) | 901 KB | downloaded by `circuits:fetch` |
| `withdraw.zkey` | Proving key (withdraw) | 17.8 MB | downloaded by `circuits:fetch` |

Verifying keys are tiny + committed so an integrator can validate proofs
without fetching anything. The .wasm + .zkey files are too large for git;
`scripts/fetch-circuits.sh` downloads them from the upstream 0xbow
ceremony output (commit `a80836a4`, pinned in
`docs/PRIVACY_HOOK_VENDOR_MAP.md`) and verifies SHA-256.

```bash
# One-shot fetch (uses raw.githubusercontent default URL)
bun run --cwd packages/privacy-prover circuits:fetch

# Or mirror to your own CDN/R2/IPFS and override
PROVER_CIRCUITS_BASE=https://my.cdn.example/v1/ \
  bun run --cwd packages/privacy-prover circuits:fetch
```

The script checks SHA-256 against the known-good values before accepting
a download, so a tampered mirror cannot poison your local cache.

## Usage

```ts
import { WithdrawalService } from "@bu/privacy-prover";
import { UrlCircuits, type WithdrawalProofInput } from "@bu/fx-engine/privacy";

// In a Node/Bun runtime — point at the local fetched copy.
const circuits = new UrlCircuits({
  baseUrl: "file:///" +
    `${__dirname}/../../packages/privacy-prover/circuits/`,
});

// In a browser — point at your hosted CDN (or IPFS gateway):
// const circuits = new UrlCircuits({
//   baseUrl: "https://cdn.example.com/fx-privacy-circuits/v1/",
// });

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
