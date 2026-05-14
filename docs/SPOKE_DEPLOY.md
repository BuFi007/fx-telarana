# Spoke Deploy Run-book

The live Base Sepolia hub is fully verified in the Tenderly project
`criptopoeta/bufi` — every fx-Telaraña contract has source code attached,
proper display name, and shows up in the **Contracts** tab (not Wallets).

This file lists the exact commands to deploy + verify `FxSpoke` on a new
chain.

## Hub pinned in `DeployFxSpoke.s.sol`

- `FxHubMessageReceiver` (Base Sepolia v3): `0x758c17BfA85D1b26A81423B524397b8b2D271818`
- Hub CCTP V2 domain: `6` (Base Sepolia)

Override with `HUB_RECEIVER=` / `HUB_DOMAIN=` env if you ever redeploy the hub-side receiver.

## Deployer wallet

`0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` — the sendero throwaway, funded on
Base Sepolia, **0 balance on every other chain — needs faucet drip per spoke
before deploy.** The private key lives in `.env.local` (gitignored).

## Per-spoke deploy

### Unichain Sepolia (chainId 1301, CCTP V2 domain 10)

Faucet — pick any:
- <https://faucet.unichain.org>
- <https://www.alchemy.com/faucets/unichain-sepolia>

Minimum needed: **~0.000002 ETH** (dry-run estimate).

```bash
set -a && source .env.local && set +a
forge script contracts/script/DeployFxSpoke.s.sol:DeployFxSpoke \
  --rpc-url https://sepolia.unichain.org \
  --broadcast --slow \
  --root contracts
```

### Avalanche Fuji (chainId 43113, CCTP V2 domain 1)

Faucet:
- <https://faucets.chain.link/fuji>
- <https://core.app/tools/testnet-faucet/>

Minimum: **~0.005 AVAX** (Fuji gas is heavier than Unichain).

```bash
set -a && source .env.local && set +a
forge script contracts/script/DeployFxSpoke.s.sol:DeployFxSpoke \
  --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
  --broadcast --slow \
  --root contracts
```

## After deploy — three things to update

1. **`deployments/<chain>.json`** — write a manifest with the new `FxSpoke`
   address, `chainId`, `network`, the chain's `CctpTokenMessengerV2` + `USDC`
   under `external`, and a `hub` block:
   ```json
   {
     "network": "unichain-sepolia",
     "chainId": 1301,
     "deployer": "0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69",
     "contracts": { "FxSpoke": "0x..." },
     "external": {
       "CctpTokenMessengerV2":  "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
       "CctpMessageTransmitterV2":"0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
       "USDC": "0x31d0220469e10c4E71834a79b1f276d740d3768F"
     },
     "hub": {
       "chainId": 84532,
       "messageReceiver": "0x758c17BfA85D1b26A81423B524397b8b2D271818",
       "cctpDomain": 6
     }
   }
   ```

2. **`packages/sdk/src/addresses/index.ts`** — fill in the `fxSpoke` field
   for the chain entry that already exists.

3. **Verify + label in Tenderly:**
   ```bash
   bun run --cwd packages/sdk tenderly:verify:spoke ../../deployments/<chain>.json
   ```
   The script submits source + constructor args via Tenderly's
   etherscan-compat endpoint, then sets the display name to
   `FxSpoke (<network>)`.

## Hub-side verify (already done for v3, kept here for reference)

```bash
bun run --cwd packages/sdk tenderly:verify:hub
```

That's `packages/sdk/scripts/tenderly-verify.sh` — hardcoded for the
Base Sepolia v3 hub. Re-run anytime you redeploy a hub contract.
