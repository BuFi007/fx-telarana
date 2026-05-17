# Vendored Reference Repositories

Phase A follows the project rule: no novel math in production. Any formula,
curve, solver, accumulator, or decimal-scaling pattern must be copied from or
thinly wrapped around an audited reference, with NatSpec citing that reference.

This file maps the in-repo references that auditors should use when checking
the Phase A spot-FX executor and the later Uniswap v4 hook wrap.

| Reference | Path | Source | Phase A use |
|---|---|---|---|
| Perennial v2 | `contracts/lib/perennial-v2` | `https://github.com/equilibria-xyz/perennial-v2` | Oracle-version settlement and accumulator patterns for later perp phases. |
| GMX Synthetics | `contracts/lib/gmx-synthetics` | `https://github.com/gmx-io/gmx-synthetics` | Swap/position fee and risk accounting references. |
| Synthetix v3 | `contracts/lib/synthetix-v3` | `https://github.com/Synthetixio/synthetix-v3` | Decimal scaling and async settlement references for `FxSpotExecutor v0.2` and later settlement flows. |
| Morpho Blue | `contracts/lib/morpho-blue` | `https://github.com/morpho-org/morpho-blue` | Existing lend/borrow and ERC-4626-backed liquidity references. |
| OpenZeppelin Uniswap Hooks | `contracts/lib/openzeppelin-uniswap-hooks` | `https://github.com/OpenZeppelin/uniswap-hooks` | `BaseCustomCurve` and safe Uniswap v4 hook wrapping patterns for Phase A v1. |
| Bunni v2 | `contracts/lib/bunni-v2` | `https://github.com/Bunniapp/bunni-v2` | Uniswap v4 hook and liquidity distribution references. |

## Patch Rule

Production contracts must not import these repositories just to satisfy the
rule. They should cite specific reference files in NatSpec where the arithmetic
or state-machine shape is used. If a future patch needs code reuse, keep the
wrapper thin and add focused tests that prove the local behavior matches the
reference assumption.
