# @bu/relayer-privacy

Off-chain Bun services that operate the **fx-Telaraña Privacy Hook** on testnet.
**Testnet only.** Mainnet requires a real ASP partnership and bug-bounty pass.

## Scope (slice 4)

| Service | Status | Purpose |
|---|---|---|
| `asp-postman` | **skeleton** | Watches `Deposited` events on `FxPrivacyEntrypoint`, maintains the in-memory label set, periodically calls `updateRoot()` with a permissive Merkle root that approves every observed deposit. |
| `cross-currency-relayer` | _deferred_ | HTTP server (Hono) that accepts withdrawal proofs + `CrossCurrencyRelayData` and submits to `relayCrossCurrency()`. |

## ASP postman — permissive mode

The on-chain `Entrypoint.relay()` and `relayCrossCurrency()` paths gate
withdrawals on the user's Groth16 proof matching the **latest ASP root**
published via `Entrypoint.updateRoot()`. For testnet we ship a *permissive*
postman: every observed `Deposited` label is included in the root, so any
valid commitment can be spent.

**Mainnet posture is different:** the postman is replaced with a real
screening provider (Chainalysis, TRM, or internal heuristic) that excludes
sanctioned/tagged addresses. The Solidity surface is unchanged — only the
off-chain bot swaps.

## Run

```bash
# 1. Build the workspace SDK first (relayer-privacy depends on @bu/fx-engine):
bun run --cwd packages/sdk build

# 2. Configure env (see .env.example):
export RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
export PRIVATE_KEY=0x...                       # postman key with ASP_POSTMAN role
export ENTRYPOINT_ADDRESS=0x...                # FxPrivacyEntrypoint proxy address
export POLL_INTERVAL_SECONDS=30

# 3. Run:
bun run --cwd packages/relayer-privacy asp-postman
```

## Architecture sketch

```
┌─────────────────────────────────────────────────────┐
│ FxPrivacyEntrypoint  (Avalanche Fuji / Arc testnet) │
│   ├─ event Deposited(depositor, pool, commitment,   │
│   │                  amount)                        │
│   └─ ASP_POSTMAN role → updateRoot(root, cid)       │
└──────────────────────┬──────────────────────────────┘
                       │ viem PublicClient.watchEvent
                       ▼
        ┌──────────────────────────────┐
        │      asp-postman             │
        │   ┌───────────────────────┐  │
        │   │ in-memory label set   │  │
        │   │ (every Deposited      │  │
        │   │  pushes its label)    │  │
        │   └──────────┬────────────┘  │
        │              ▼               │
        │   LeanIMT root = Merkle      │
        │   (Poseidon) of label set    │
        │              │               │
        │              ▼               │
        │   sign + send updateRoot()   │
        │   every POLL_INTERVAL_SEC    │
        └──────────────────────────────┘
```

## Permanently deferred (per HANDOFF_PRIVACY_HOOK.md)

- Real ASP screening (Chainalysis/TRM) — mainnet-only.
- Cross-currency relayer HTTP API + DB persistence — slice 4b.
- Uniswap V3 gas-swap layer (0xbow upstream uses this; we strip it because
  USDC is gas on Arc and AVAX is gas on Fuji — no swap-for-gas needed).
