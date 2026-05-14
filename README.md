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

## Tenderly Virtual TestNet

Live, persistent Base Sepolia fork with admin RPC access for time-travel / state mutation. Used for fast iteration while we wait on Morpho's Arc deployment.

```
slug:    fx-telarana-base-sepolia
chainId: 84532
forked:  Base Sepolia @ block 0x278e72a
admin:   https://virtual.base-sepolia.eu.rpc.tenderly.co/15f37edc-dbae-4ca6-818c-5770d495a38f
public:  https://virtual.base-sepolia.eu.rpc.tenderly.co/5987456d-3864-4716-8b96-df5d5e9d12fa
dash:    https://dashboard.tenderly.co/criptopoeta/bufi/testnet/d70bf2af-c59f-4ef5-a6cc-0af9d5c2cf2f
```

Useful admin RPC methods (Tenderly-specific extensions):
- `tenderly_setBalance(address, amountHex)` — fund any address with native gas
- `tenderly_setErc20Balance(token, holder, amountHex)` — fund any ERC-20
- `tenderly_setStorageAt(address, slot, value)` — mutate state directly
- `evm_increaseTime` / `evm_mine` — time travel for grace-period tests

The current live deployment on this vnet is in [`deployments/tenderly-base-sepolia.json`](deployments/tenderly-base-sepolia.json).

## Deploying to Arc Testnet (when Morpho lands there)

1. Fund deployer via [faucet.circle.com](https://faucet.circle.com) (Arc uses USDC as native gas).
2. Set env: `DEPLOYER_PRIVATE_KEY`, `ARC_MORPHO_BLUE`, `ARC_MORPHO_ADAPTIVE_IRM`.
3. `forge script contracts/script/DeployArcTestnet.s.sol --rpc-url https://rpc.testnet.arc.network --broadcast`
4. Run through [`docs/PRE_DEPLOY_CHECKLIST.md`](docs/PRE_DEPLOY_CHECKLIST.md).

## Registering with Circle Smart Contract Platform

Post-deploy, ingest the contracts into Circle SCP for event webhooks + ABI-driven reads:

```bash
CIRCLE_API_KEY=TEST_API_KEY:... \
ENTITY_SECRET=... \
WEBHOOK_URL=https://your.webhook.endpoint \
  bun run sdk:circle:register deployments/tenderly-base-sepolia.json
```

Idempotent (re-runs find existing imports by address). Event monitors land on the provided `WEBHOOK_URL` for `DepositStranded`, `DepositSwept`, `DepositExecuted`, `MarketRegistered`, `Entered`, `Exited`, `FeedSet`, `RedstoneFeedSet`.

## License

MIT — see contracts SPDX headers.
