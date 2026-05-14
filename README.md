# fx-Telaraña — Forex Telaraña Protocol

A decentralized cross-currency money market and FX engine on **Arc** with cross-chain spokes (CCTP V2) and an opt-in confidential rail (Hinkal, Phase 1).

> *Telaraña — "spider's web" — for the hub-and-spoke topology that pulls FX liquidity from any chain into a single Arc-native lending and swap market.*

## What it is

- **FX money market** on Arc built over **Morpho Blue** isolated markets (USDC↔EURC at MVP).
- **Cross-chain spokes** via Circle's CCTP V2 — bring USDC from Ethereum / Base / any CCTP-supported chain and open positions on the Arc Hub.
- **Permissionless, decentralized oracle** — Pyth primary + RedStone secondary. 24/7. No forex-hours circuit breakers. USDC and EURC are ERC-20s onchain.
- **Confidential mode** (Phase 1) — Hinkal-wrapped flows for KYC'd Bufi users; same contracts, different call boundary.
- **Uniswap v4 FX swap hook** (Phase 2) — oracle-anchored PMM with JIT-borrow from the lending pool.

## Repo layout

```
contracts/   Solidity (Foundry) — Phase 0 protocol contracts + unit + mainnet-fork tests
docs/        SPEC.md (engineering spec v0.2), TODOS.md
```

See [`contracts/README.md`](contracts/README.md) for build, test, and deploy.

## Status

- **Phase 0 contracts** — complete, 31/31 tests passing, fork-verified against the real Morpho Blue singleton (`0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`) on Ethereum mainnet.
- **Phase 0.5** — RedStone consumer payload wiring (next).
- **Phase 1** — Hinkal confidential mode (after Hinkal partner conversation).
- **Phase 2** — Uniswap v4 swap hook.

## License

MIT — see contracts SPDX headers.
