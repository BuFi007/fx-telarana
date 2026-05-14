# CLAUDE.md — fx-Telaraña

Per-repo guidance for Claude Code agents working in this codebase.

## Status

- **Live on real Base Sepolia** (chainId 84532, deployer `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`). All 8 contracts deployed + both Morpho markets created on the real Morpho Blue singleton + registered with Circle SCP. Addresses: `deployments/base-sepolia.json` and `packages/sdk/src/addresses/index.ts` (`ChainId.BaseSepolia`).
- **Live on Tenderly vnet**: parallel deployment for fast iteration. Addresses in `deployments/tenderly-base-sepolia.json`. Vnet RPC + dashboard URL in `.env.local` (gitignored).
- **Production target**: Arc testnet (chainId 5042002). Deploy script at `contracts/script/DeployArcTestnet.s.sol`. Still blocked on Morpho Blue Arc address — or we self-deploy Morpho there next.
- **Branch**: `tcxcx/fx-onchain-hub-arc`. Don't rename without explicit instruction.

## Testing

```bash
# Solidity unit tests
bun run contracts:test

# Solidity unit + ETH mainnet fork tests (against live Morpho Blue)
bun run contracts:test:fork

# SDK tests
bun run sdk:test
```

Current: 42/42 unit + 4/4 mainnet fork + 20/20 SDK tests passing.

## Deferred work — pick up when triggered

### Circle Smart Contract Platform registration — DONE for Base Sepolia

All 8 Base Sepolia contracts registered in Circle SCP project (under `criptopoeta`, account-scoped). Contract IDs persist on Circle's side; re-running `bun run sdk:circle:register deployments/base-sepolia.json` is idempotent.

When we deploy to Arc testnet, run the same script with `deployments/arc-testnet.json` — works identically. Webhook URL not yet set; add `WEBHOOK_URL=https://...` when Pasillo/Trigger.dev sink is ready.

### Phase 2.5 swap hook — IN PROGRESS

`FxSwapHook.sol` ships as constant-spread MVP. Remaining work tracked inline as `Phase 2.5:` comments:
- DODO PMM curve math (k, B0, Q0; size-impact)
- LP rehypothecation through `FxMarketRegistry`
- JIT-borrow on output shortfall
- `afterSwap` fee → Morpho supply (Bunni pattern)
- exactOutput swap path

## Key project conventions

- **Solidity 0.8.26**, `evm_version = "cancun"` (Arc targets Prague, a superset). Don't change to `paris` — RedStone's evm-connector library uses `mcopy`, which is Cancun-only.
- **`IFxOracle` is the only price-read surface.** No contract calls Pyth/RedStone SDK directly. New oracles drop in behind this interface.
- **`IFxSpoke.enterHub(token, amount, beneficiary, hubCalldata)`** — explicit `beneficiary` arg, NEVER `msg.sender`-derived. Hinkal-wrapped flows (Phase 1) pass user's fresh SCA; public mode passes EOA/SCA.
- **`sweepStrandedDeposit(messageNonce)` 24h grace** — the only recovery path for CCTP V2 hook reverts on the Hub side.

## Tenderly testnet workflow

`/tenderly-testnet` skill (in `~/.claude/skills/tenderly-testnet/`) encodes the full setup pattern. Use it whenever creating a new vnet or onboarding a fresh project to the same workflow. Skill refuses mainnet network_ids by design.

## Arc-specific gotchas (baked into deploy script)

- USDC is native gas on Arc. Fund deployer via [faucet.circle.com](https://faucet.circle.com), no CCTP needed.
- `msg.value` and `address.balance` are 18-decimal native units. ERC-20 USDC is 6-decimal. **Never mix.**
- `SELFDESTRUCT` restricted during deployment (we don't use it).
- Pre-deploy checklist: `docs/PRE_DEPLOY_CHECKLIST.md`.
