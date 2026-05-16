# CLAUDE.md — fx-Telaraña

Per-repo guidance for Claude Code agents working in this codebase.

## Status

- **Two live hubs, Gateway-bridged:** Fuji is the PRIMARY HUB (all user deposits land here via CCTP V2 spokes). Arc is the TRADING-EXECUTION HUB (receives USDC liquidity from Fuji via `FxGatewayHook` for FX/perp execution; never user-initiated). `FxGatewayHook` is the only contract that moves USDC across hubs.
- **Live on Avalanche Fuji** (chainId 43113, primary hub) — full hub stack + local FxSpoke + FxGatewayHook deployed 2026-05-14/15. Addresses: `deployments/avalanche-fuji.json` and `deployments/hub-config-fuji.json`.
- **Live on Arc Testnet** (chainId 5042002, trading hub) — full hub stack + FxGatewayHook deployed 2026-05-15. MorphoBlue + IrmMock self-deployed (no canonical Morpho on Arc). Addresses: `deployments/arc-testnet.json` and `deployments/hub-config-arc.json`.
- **8 spokes routing to Fuji**: eth-sepolia, op-sepolia, arbitrum-sepolia, polygon-amoy, unichain-sepolia, worldchain-sepolia, arc-testnet, plus the local Fuji-on-Fuji spoke.
- **Base Sepolia hub retired** (still deployed, but no spokes route to it post-migration). Kept around for FxSwapHook + Uniswap V4 isolated swap testing.
- **Branch**: `tcxcx/fx-onchain-hub-arc`. Don't rename without explicit instruction.

### Mid-July 2026 — 1271 authority rotation

When Circle ships EIP-1271 support on Gateway burn intents (Corey's mid-July ETA):

1. Implement `isValidSignature(bytes32, bytes)` on `FxHubMessageReceiver` to gate which BurnIntents the protocol authorizes (read intent fields, assert sourceDomain/destDomain match a whitelisted hub pair, assert value ≤ some per-block cap, etc.).
2. Call `FxGatewayHook.setAuthority(FxHubMessageReceiver)` on both Fuji and Arc to swap the EOA out for the hub contract itself.
3. Withdraw any remaining USDC balance from Gateway under the OLD EOA authority (initiate → wait operator delay → complete), then re-lock under the new hub-contract authority.
4. Sunset the off-chain EOA-signed BurnIntent service; intents become contract-signed automatically.

Until this rotation, deployer EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` signs all BurnIntents off-chain.

### BUFX integration

`docs/BUFX_INTEGRATION.md` is the source of truth for the spot+perp execution layer (separate repo). Has all addresses, callable interfaces, the cross-hub trade flow, and the Stage 6 plumbing gap (hub-side `relayToRemoteHub` shim BUFX will need).

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
