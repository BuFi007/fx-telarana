<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# FX Telarana DefiLlama Adapter

This package contains the internal DefiLlama-compatible TVL adapter for FX Telarana lending markets.

TVL definition, to re-verify against DefiLlama listing rules before mainnet submission:

- `TVL_market = totalSupplyAssets_in_USD`
- `BorrowedUSD = totalBorrowAssets_in_USD`
- `NetSupply = TVL_market - BorrowedUSD`

For lending-protocol adapters, DefiLlama distinguishes TVL/net supply from borrowed value. The adapter exports both `tvl(api)` and `borrowed(api)` per chain. Testnet output is internal only; submit to `DefiLlama-Adapters` after mainnet deploy.
