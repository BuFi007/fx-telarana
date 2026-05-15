# Forex Telaraña Protocol

A decentralized cross-currency money market and FX engine with cross-chain spokes (CCTP V2 + Hyperlane) and an opt-in Ghost Mode rail powered by Bufi Wallet KYC/KYB passes and privacy hooks.

> *Telaraña — "spider's web" — for the hub-and-spoke topology that pulls FX liquidity from any chain into a single Arc-native lending and swap market.*

## Product framing

Forex Telaraña is a cross-chain FX credit hub. Users can enter from any supported chain with USDC or EURC where Circle supports it, route into Avalanche hub FX markets, and borrow or lend against currency-pair collateral. Hyperlane powers cross-chain intents and non-Circle asset routes; CCTP stays Circle-only for canonical USDC and EURC movement; the hub risk engine decides what assets are valid collateral.

Stablecoin Summer is a cross-chain FX credit campaign: users enter from supported chains with USDC, route into hub-based currency markets, earn real stablecoin yield and rewards, and eventually access Forex perps backed by Morpho liquidity and Uniswap v4 execution.

## What it is

- **FX money market** built over **Morpho Blue** isolated markets (USDC↔EURC at MVP, Avalanche basket next).
- **Cross-chain spokes** via Circle's CCTP V2 — bring USDC, and EURC where Circle supports it, from CCTP-supported chains and open positions on the Hub. CCTP is never used for non-Circle stablecoins.
- **Permissionless, decentralized oracle** — Pyth primary + RedStone secondary. 24/7. No forex-hours circuit breakers. USDC and EURC are ERC-20s onchain.
- **Ghost Mode** (Phase 1) — Bufi Wallet KYC/KYB pass-gated privacy hooks and routers for slower private deposit, withdrawal, swap, and cross-chain entry flows. No third-party privacy wallet dependency and no Circle Wallet dependency.
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
- **Phase 1** — Ghost Mode with Bufi Wallet pass verification, privacy hooks, and commitment/nullifier withdrawal routing.
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

## Attribution

The hook roadmap and the current truncated-observation / volatility-spread
implementation are inspired by public Uniswap v4 hook examples, including the
truncated oracle, volatility oracle, and TWAMM work by Austin Adams (`aadams`)
and the Uniswap builders. The Ghost Mode direction also learns from the
`blackbera/privacy-hook-univ4` privacy-hook concept and public KYC hook examples,
while avoiding unsafe patterns like `tx.origin` authorization.

Thank you to those builders for publishing useful reference work. If we vendor
or derive from third-party sources later, keep their SPDX headers, copyright
notices, and NOTICE requirements with the imported files.

## License

This repository is mixed-license by path and artifact type:

- Apache-2.0: smart contracts, Uniswap v4 hooks, public Solidity protocol
  libraries, and the public `@bu/fx-engine` SDK.
- AGPL-3.0-only: backend services, Hono APIs, indexers, monitors, simulators,
  deployment/registration workflows, and agent/workflow services.
- MIT: examples, templates, frontend demo components, and throwaway integration
  samples.

See [LICENSE](LICENSE) for the repo policy and `LICENSES/` for full license
texts. Per-file SPDX headers are authoritative where present.
