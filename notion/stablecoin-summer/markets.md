# Stablecoin Summer Markets

## Initial Basket

- USDC.
- AUDF.
- JPYC.
- MXNB.
- KRW1.
- ZCHF.

## Disabled / TBD

- EURC.

## Excluded For Now

- BRLA.
- PHPC.

## Current Architecture

The spoke layer currently supports USDC entry only.

Users send USDC from a supported spoke chain into the Fuji hub. Once USDC arrives at the hub, the user can route into supported FX markets.

## Testnet Requirements For New Markets

To activate additional FX markets on testnet, the protocol needs:

- Mock asset contract.
- Matching receipt token, if used.
- Pyth oracle configuration.
- RedStone fallback configuration.
- FxMarketRegistry entry.
- Market ID in deployment manifest.
- Risk parameters.
- Borrow/supply enablement.
- Campaign eligibility config.
