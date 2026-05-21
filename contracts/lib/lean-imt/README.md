# Lean Incremental Merkle Tree (vendored)

Vendored from
[`zk-kit/zk-kit.solidity`](https://github.com/zk-kit/zk-kit.solidity/tree/main/packages/lean-imt)
(MIT) — PSE's optimized binary IMT, used across Semaphore and Privacy Pools.

## Manifest

| File | Source | Status |
|---|---|---|
| `InternalLeanIMT.sol` | `packages/lean-imt/contracts/InternalLeanIMT.sol` | unchanged |
| `Constants.sol` | rewrite of upstream `Constants.sol` | rewritten — upstream SPDX was `UNLICENSED`; we re-declare `SNARK_SCALAR_FIELD` under MIT |

`LeanIMT.sol` (the wrapping contract variant) is not vendored — our
`State.sol` consumes `InternalLeanIMT` as a library on a struct.

## Pragma

`pragma solidity ^0.8.4;` — compatible with our `0.8.26` pin, unchanged.

## Audit posture

The lean-imt design is documented in the PSE
[lean-imt paper](https://github.com/zk-kit/zk-kit/tree/main/papers/leanimt) and
in-scope for the 0xbow Privacy Pools audits — `State.sol`'s use of
`InternalLeanIMT._insert`, `_has`, `depth`, `size` is validated by Oxorio's
contracts audit.

## Modification log

- `Constants.sol`: re-declared under explicit MIT (upstream was UNLICENSED). Same
  `SNARK_SCALAR_FIELD` value.
- `InternalLeanIMT.sol`: unchanged.
