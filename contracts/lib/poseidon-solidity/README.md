# poseidon-solidity (vendored)

Vendored from
[`privacy-scaling-explorations/poseidon-solidity`](https://github.com/privacy-scaling-explorations/poseidon-solidity)
(MIT). Canonical PSE implementation of the Poseidon hash function over BN254,
used across Semaphore, Tornado, MACI, Privacy Pools, and similar ZK protocols.

## Manifest

| File | Source | Status |
|---|---|---|
| `PoseidonT3.sol` | `contracts/PoseidonT3.sol` | unchanged (used by lean-imt) |
| `PoseidonT4.sol` | `contracts/PoseidonT4.sol` | unchanged (used by PrivacyPool commitment hash) |

`PoseidonT2.sol`, `PoseidonT5.sol`, `PoseidonT6.sol` are not vendored — not used
by Privacy Pools or lean-imt.

## Pragma

`pragma solidity >=0.7.0;` — compatible with our `0.8.26` pin, unchanged.

## Audit posture

PSE labels this implementation as "not standalone-audited", but it is the de
facto reference implementation across the Ethereum ZK ecosystem and was
explicitly in-scope for the
[0xbow Privacy Pools Oxorio contracts audit](../privacy-pools/README.md#audits),
which validates the `PoseidonT4.hash` usage we depend on.

## Modification log

None. Files copied verbatim from upstream HEAD (May 2026).
