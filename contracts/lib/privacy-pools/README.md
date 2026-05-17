# Privacy Pools (vendored)

Vendored Solidity contracts from
[`0xbow-io/privacy-pools-core`](https://github.com/0xbow-io/privacy-pools-core),
the production Privacy Pools deployment on Ethereum mainnet (live since
April 2025, Vitalik-backed via the Buterin/Illum/Nadler/Schär/Soleimani 2023
paper [_Blockchain Privacy and Regulatory Compliance: Towards a Practical
Equilibrium_](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4563364)).

Apache-2.0. SPDX headers preserved on every file.

## Manifest

| File | Source | Status |
|---|---|---|
| `Constants.sol` | `src/contracts/lib/Constants.sol` | unchanged |
| `ProofLib.sol` | `src/contracts/lib/ProofLib.sol` | pragma `0.8.28→^0.8.26` |
| `State.sol` | `src/contracts/State.sol` | pragma `0.8.28→^0.8.26` |
| `PrivacyPool.sol` | `src/contracts/PrivacyPool.sol` | pragma `0.8.28→^0.8.26` |
| `Entrypoint.sol` | `src/contracts/Entrypoint.sol` | pragma `0.8.28→^0.8.26` |
| `verifiers/WithdrawalVerifier.sol` | `src/contracts/verifiers/WithdrawalVerifier.sol` | unchanged (auto-gen Groth16) |
| `verifiers/CommitmentVerifier.sol` | `src/contracts/verifiers/CommitmentVerifier.sol` | unchanged (auto-gen Groth16) |
| `interfaces/IPrivacyPool.sol` | `src/interfaces/IPrivacyPool.sol` | pragma bump |
| `interfaces/IEntrypoint.sol` | `src/interfaces/IEntrypoint.sol` | pragma bump |
| `interfaces/IState.sol` | `src/interfaces/IState.sol` | pragma bump |
| `interfaces/IVerifier.sol` | `src/interfaces/IVerifier.sol` | pragma bump |

## Modification log

Only deviations from upstream:
1. **Pragma**: `pragma solidity 0.8.28;` → `pragma solidity ^0.8.26;`
   This codebase pins `0.8.26` (cancun); 0.8.28 is binary-compatible — no language
   features used in these files differ between the two compiler versions.
2. **Import remappings**: 0xbow uses `poseidon/PoseidonT4.sol` (their remapping points
   into `node_modules/poseidon-solidity`). We remap `poseidon/=lib/poseidon-solidity/`
   which resolves identically. Same for `lean-imt/=lib/lean-imt/`.
3. **Skipped files**: `lib/DeployLib.sol` (CreateX deploy helper — not used),
   `implementations/PrivacyPoolSimple.sol` (native-asset variant — not needed),
   `implementations/PrivacyPoolComplex.sol` (ERC20 reference — we write our own
   `FxPrivacyPool` in `src/hub/` modeled on it).

**No algorithmic or arithmetic changes.**

## Audits

Vendored at the audited commit. Reports in upstream `audit/`:

- `circuits_audit_oxorio.md` (Feb 2025) — circuits audit by Oxorio
- `contracts_audit_oxorio.md` (Mar 2025) — contracts audit by Oxorio
- `contracts_audit_auditware.md` — contracts audit by Auditware
- `entrypoint_upgrade_audit_oxorio.md` — Entrypoint v1.1 upgrade audit by Oxorio

All findings remediated or formally acknowledged upstream.
