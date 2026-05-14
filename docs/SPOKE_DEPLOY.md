# Spoke Deploy Run-book

Live Base Sepolia hub already labeled in Tenderly (`criptopoeta/bufi` project).
This file lists the exact one-line commands to deploy `FxSpoke` to a new chain.

## Hub address pinned in `DeployFxSpoke.s.sol`

- `FxHubMessageReceiver` (Base Sepolia v3): `0x758c17BfA85D1b26A81423B524397b8b2D271818`
- Hub CCTP V2 domain: `6` (Base Sepolia)

Override via env if you ever redeploy the hub-side receiver.

## Deployer wallet

`0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` — the sendero throwaway already
funded on Base Sepolia. **0 balance on every other chain — needs faucet drip
per spoke before deploy.**

## Per-spoke deploy

### Unichain Sepolia (chainId 1301, CCTP V2 domain 10)

Faucet — pick any:
- <https://faucet.unichain.org>
- <https://www.alchemy.com/faucets/unichain-sepolia>

Minimum needed: **~0.000002 ETH** (estimate from a dry-run).

```bash
set -a && source .env.local && set +a
forge script contracts/script/DeployFxSpoke.s.sol:DeployFxSpoke \
  --rpc-url https://sepolia.unichain.org \
  --broadcast --slow \
  --root contracts
```

Then label in Tenderly + persist the address:

```bash
# After noting the FxSpoke address from the deploy log,
# write deployments/unichain-sepolia.json and:
bun packages/sdk/scripts/tenderly-label.ts deployments/unichain-sepolia.json
```

### Avalanche Fuji (chainId 43113, CCTP V2 domain 1)

Faucet:
- <https://faucets.chain.link/fuji>
- <https://core.app/tools/testnet-faucet/>

Minimum: **~0.005 AVAX** (Fuji gas is heavier than Unichain Sepolia).

```bash
set -a && source .env.local && set +a
forge script contracts/script/DeployFxSpoke.s.sol:DeployFxSpoke \
  --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
  --broadcast --slow \
  --root contracts
```

Then:

```bash
bun packages/sdk/scripts/tenderly-label.ts deployments/avalanche-fuji.json
```

## After deploy — three things to update

1. **`deployments/<chain>.json`** — write a manifest with the new `FxSpoke` address.
2. **`packages/sdk/src/addresses/index.ts`** — fill in the `fxSpoke` field for the chain.
3. **Tenderly label** — `bun packages/sdk/scripts/tenderly-label.ts deployments/<chain>.json`.

The labeling script skips `external` block by default to preserve the 20-address
Tenderly free-plan cap. Pass `--include-external` only when you need to monitor
boilerplate contracts.
