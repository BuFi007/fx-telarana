# Feed readiness — Phase 3 basket

Reviewed: 2026-05-15

Scope: Avalanche mainnet Hub simulation + Arc testnet mocks for USDC-paired AUDF, JPYC, MXNB, KRW1, and ZCHF.

## Result

All Phase 3 basket currencies have a Pyth feed shape and RedStone symbol suitable for `IFxOracle`-gated simulation. The key code change is that `FxOracle` now supports Pyth inverse feeds through `setPythFeedConfig(token, feedId, true)`.

| Asset | Pyth feed | Feed id | Invert in `FxOracle` | RedStone symbol |
|---|---|---|---|---|
| USDC | `USDC/USD` | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` | no | `USDC` |
| EURC | `EURC/USD` | `0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c` | no | recheck before Tier 0 Avalanche use |
| AUDF | `AUD/USD` | `0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80` | no | `AUD` |
| JPYC | `USD/JPY` | `0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52` | yes | `JPY` |
| MXNB | `USD/MXN` | `0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca` | yes | `MXN` |
| KRW1 | `USD/KRW` | `0xe539120487c29b4defdf9a53d337316ea022a2688978a468f9efd847201be7e3` | yes | `KRW` |
| ZCHF | `USD/CHF` | `0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8` | yes | `CHF` |

## On-chain issuer checks

KRW1 on Avalanche mainnet:

- Address: `0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318`
- `decimals()`: `0`
- `name()`: `KRW1`
- `symbol()`: `KRW1`
- `totalSupply()`: `10000000`

## Tenderly swap drill plumbing

Landed after this review:

1. `contracts/script/DeployAvalancheBasketHub.s.sol` — fresh Avalanche-shaped basket deploy for Tenderly vnet/mainnet rehearsal.
2. `FxSwapHook` raw-unit quote fix — normalizes ERC-20 decimals before applying oracle mids, so USDC↔JPYC/ZCHF/KRW1 are not mispriced.
3. `contracts/test/AvalancheBasketSmoke.t.sol` — local smoke matrix for USDC→JPYC/MXNB/AUDF/KRW1/ZCHF: market creation, hook deploy, v4 pool initialize, LP seed, Morpho rehypothecation, v4 hook swap callback.

Remaining before public mainnet rehearsal: run the same script against a Tenderly Avalanche vnet with real deployment addresses and capture the resulting deployment manifest.
