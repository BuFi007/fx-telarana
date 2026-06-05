# CLAUDE.md — fx-Telaraña

Per-repo guidance for Claude Code agents working in this codebase.

## Product framing

Forex Telaraña is a cross-chain FX credit hub. Users can enter from any supported chain with USDC or EURC where Circle supports it, route into Avalanche hub FX markets, and borrow or lend against currency-pair collateral. Hyperlane powers cross-chain intents and non-Circle asset routes; CCTP stays Circle-only for canonical USDC and EURC movement; the hub risk engine decides what assets are valid collateral.

## Status

- **Two live hubs, Gateway-bridged:** Fuji is the PRIMARY HUB (all user deposits land here via CCTP V2 spokes). Arc is the TRADING-EXECUTION HUB (receives USDC liquidity from Fuji via `FxGatewayHook` for FX/perp execution; never user-initiated). `FxGatewayHook` is the only contract that moves USDC across hubs.
- **Live on Avalanche Fuji** (chainId 43113, primary hub) — full hub stack + local FxSpoke + FxGatewayHook deployed 2026-05-14/15. Addresses: `deployments/avalanche-fuji.json` and `deployments/hub-config-fuji.json`.
- **Live on Arc Testnet** (chainId 5042002, trading hub) — full hub stack + FxGatewayHook deployed 2026-05-15. The live hub still uses the earlier self-deployed MorphoBlue + IrmMock. Morpho Labs Arc testnet contracts are now verified in `deployments/morpho-arc-testnet.json` and are the default for the next fresh Arc hub broadcast. Addresses: `deployments/arc-testnet.json` and `deployments/hub-config-arc.json`.
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

## The Yield Machine (canonical architecture)

> Every dollar is, at every instant, either **earning spread** (serving a swap) or **earning yield** (USYC / Morpho). Never idle. Full spec: `defi-web-app/docs/architecture/yield-machine-spec.md` (BUFX repo).

**Two hard invariants:**
1. **Performance law — the swap hot path never touches yield or Gateway.** `beforeSwap` stays byte-for-byte unchanged (<50k gas, one vault call, zero new external calls). All yield/cross-chain movement is out-of-band.
2. **Compliance law — retail NAV never touches USYC.** USYC is Reg-S (institutions only). Enforced on-chain as `retailAssets ∩ USYC = ∅`, not as a policy note.

### v4 delta-accounting is *why* capital can earn yield at all

`FxSwapHook` uses `beforeSwapReturnDelta` (the "delta hook") with **empty pools**. The pool is just a routable `PoolKey`; the hook prices the swap from the oracle PMM and pulls the fill from the vault **just-in-time**. No concentrated liquidity ever sits in the pool.

Because the pool is empty, the capital that backs it doesn't have to be in the pool — it can be off in USYC and Morpho earning yield, and the delta hook summons it back only at the instant of a swap. Without v4 delta-accounting, "no idle capital" is impossible; the liquidity would be trapped in pools. The delta hook **is** the mechanism that frees the capital to be a yield machine.

### The hooks as machine parts

| Hook | Role in the machine |
|---|---|
| **FxSwapHook** (delta accounting) | The **spread engine + JIT summon.** Earns the 30bps spread on every swap; its empty-pool design lets the backing capital go earn yield between swaps. |
| **FxHedgeHook** (hookathon) | The **IL shield.** Auto-opens BTC short perps to neutralize LP exposure → higher net LP yield. Links the perps book to the LP book. |
| **FxGatewayHook** `0x2931C50…` | The **cross-hub rail.** Lock/burn on Arc, mint on Fuji/Arbitrum (349ms attestor latency). Fully contract-authorized once Circle ships ERC-1271 on burn intents (authority rotates from the deployer EOA `0x0646…` to `FxHubMessageReceiver`). |

### The full machine

```
  SharedFxVault capital (senior working capital + junior backstop + FX inventory)
        │
        ├─ serving a swap?  → FxSwapHook delta-fill → earns SPREAD          ◀ Uniswap v4
        │                                                                      (+ FxHedgeHook trims IL)
        └─ idle right now?  → FxReserveYieldRouter:
                                 ├─ USDC → Morpho lending APY   (retail-OK)   ◀ Arc/Fuji money market
                                 ├─ FX   → Morpho FX-loan APY    (retail-OK)
                                 └─ USDC → USYC T-bill floor     (INSTI ONLY)  ◀ Circle Teller
        +
  TurboFeeVault: 40% of perp + swap fees ──▶ distributed back to LPs (cross-hub via Gateway)
        │
  Permissionless on-chain rebalance() moves dollars between "serving" and "earning",
  and across hubs via Gateway. Swaps never wait on it (local buffer + perSwapCapBps).
```

### The compliance wall — an on-chain invariant

USYC yield can never touch retail (Reg-S). Tier-aware accounting, enforced in the contract:

| Tier | Eligible yield | NAV rule |
|---|---|---|
| **Retail** (public lenders) | AMM spread + Morpho lending APY + perp-fee share | **Par-pure USDC NAV. USYC NAV *never* in retail share price.** |
| **Institutional** (KYB'd) | all of the above **+ USYC** | opts into RWA NAV explicitly |
| **Protocol / junior** (treasury, first-loss) | USYC + everything | we own it; no retail exposure |

The router tags capital by tier and **refuses to route retail dollars into the USYC sink.** Audit invariant: `retailAssets ∩ USYC = ∅`. SharedFxVault `totalAssets()` for the retail tier stays par-pure (no USYC term); only institutional/protocol NAV includes USYC.

### Seamless = it self-operates

No off-chain SaaS. Automation = on-chain `(s,S)` guard + permissionless incentivized `rebalance()`. Humans only set governance params.

### Build order (contracts live in this repo)

- **P1 (now):** `FxReserveYieldRouter` (Arc) + USYC sink (Teller `0x9fdF…105A`, USYC `0xe918…b86C`, Entitlements `0xcc20…`), tier-gated to protocol/institutional only. Entitle the router address (same flow as keeper `0xcA02`). One `SharedFxVault.totalAssets()` edit; permissionless `rebalance()`.
- **P2:** activate Morpho sinks — USDC-loan (`DeployArcCanonicalMorphoMarkets`) + FX-loan (`DeployArcAssetLoanMorphoMarkets`), reusing the vault's `_morphoSupplyAssets` scaffolding.
- **P3:** wire `TurboFeeVault` (`0x929e…0531`) perp-fee distribution cross-hub via Gateway.
- **P4:** `FxHedgeHook` IL protection as the net-yield amplifier.

Each phase adds a yield source to the same machine without touching the swap path or the retail/USYC wall.

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

- **License split:** Apache-2.0 for smart contracts, hooks, SDKs, and public
  protocol libraries; AGPL-3.0-only for backend/API/indexer/agent/workflow
  services; MIT for examples, templates, and frontend demo components. Add SPDX
  headers on new source files.
- **Solidity 0.8.26**, `evm_version = "cancun"` (Arc targets Prague, a superset). Don't change to `paris` — RedStone's evm-connector library uses `mcopy`, which is Cancun-only.
- **`IFxOracle` is the only price-read surface.** No contract calls Pyth/RedStone SDK directly. New oracles drop in behind this interface.
- **`IFxSpoke.enterHub(token, amount, beneficiary, hubCalldata)`** — explicit `beneficiary` arg, NEVER `msg.sender`-derived. Ghost Mode flows pass the Bufi Ghost router/action account selected by the privacy route; public mode passes the user EOA/SCA.
- **`sweepStrandedDeposit(messageNonce)` 24h grace** — the only recovery path for CCTP V2 hook reverts on the Hub side.

## Tenderly testnet workflow

`/tenderly-testnet` skill (in `~/.claude/skills/tenderly-testnet/`) encodes the full setup pattern. Use it whenever creating a new vnet or onboarding a fresh project to the same workflow. Skill refuses mainnet network_ids by design.

## Arc-specific gotchas (baked into deploy script)

- USDC is native gas on Arc. Fund deployer via [faucet.circle.com](https://faucet.circle.com), no CCTP needed.
- `msg.value` and `address.balance` are 18-decimal native units. ERC-20 USDC is 6-decimal. **Never mix.**
- `SELFDESTRUCT` restricted during deployment (we don't use it).
- Pre-deploy checklist: `docs/PRE_DEPLOY_CHECKLIST.md`.
