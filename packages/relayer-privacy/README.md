# @bu/relayer-privacy

Off-chain Bun services that operate the **fx-Telaraña Privacy Hook** on testnet.
**Testnet only.** Mainnet requires a real ASP partnership and bug-bounty pass.

## ⚠️ Single-writer deployment ONLY

The vendored `FxPrivacyEntrypoint.updateRoot(uint256, string)` is append-only
and carries no expected-prior-root parameter. Running **two or more postman
processes** against the same entrypoint is **not safe**:

- Each tick reads `latestRoot()`, detects "drift" from its own local tree,
  and republishes. With concurrent writers, this oscillates — postman A
  publishes root_v2, postman B reads root_v2 ≠ its local root_v1, publishes
  root_v1, clobbering the newer root.
- There is no off-chain TOCTOU guard strong enough to fix this without an
  on-chain compare-and-set primitive (codex-r7 finding).

**Operational requirement:** grant the `ASP_POSTMAN` role to exactly ONE
key, and run exactly ONE postman process against that key. If you need
redundancy (HA failover), use a passive standby that does NOT hold the
role — promote it (rotate the role) only when the primary is confirmed
dead.

Future work (slice 4b / contracts v2): add `updateRootIfLatest(expected,
new, cid)` on `FxPrivacyEntrypoint` to make multi-writer mode safe at the
contract layer. Until then, this constraint is enforced operationally
only.

## Scope (slice 4)

| Service | Status | Purpose |
|---|---|---|
| `asp-postman` | shipping | Watches `Deposited` events on each registered pool, maintains the canonical-ordered LeanIMT, publishes a permissive ASP root via `Entrypoint.updateRoot()` (testnet only — every label approved). Single-writer constraint (see below). |
| `relayer-api` | shipping | Hono HTTP server on `RELAYER_PORT`. `POST /v1/relayCrossCurrency` accepts a JSON withdrawal proof + `CrossCurrencyRelayData`, validates the schema, rate-limits per-IP, and submits to `FxPrivacyEntrypoint.relayCrossCurrency()`. Stateless — viem manages the relayer wallet's nonce; redundant instances are safe because the on-chain nullifier double-spend gate makes only the first land. |

## Cross-currency relayer HTTP API

```bash
# Start the server
bun run --cwd packages/relayer-privacy relayer-api
```

```http
GET /health → 200 { ok: true, entrypoint, dryRun, maxRelayFeeBPS }

POST /v1/relayCrossCurrency
Content-Type: application/json

{
  "scope": "0x...",              # PrivacyPool scope (decimal string)
  "data": {
    "recipient":    "0x...",     # user's signed recipient
    "feeRecipient": "0x...",     # who gets relayFeeBPS in sell asset
    "relayFeeBPS":  "50",        # ≤ RELAYER_MAX_FEE_BPS or 400 returned
    "buyToken":     "0x...",     # asset delivered to recipient
    "minBuyAmount": "99500000"   # entrypoint enforces measured-delta gate
  },
  "proof": {
    "pA": ["...", "..."],
    "pB": [["...", "..."], ["...", "..."]],
    "pC": ["...", "..."],
    "pubSignals": ["...", "...", "...", "...",
                   "...", "...", "...", "..."]
  }
}

→ 200 { ok: true, txHash: "0x..." }
→ 400 { error: "bad_request" | "fee_too_high", ... }
→ 429 { error: "rate_limited" }
→ 500 { error: "relay_failed", message: "..." }
```

Security:
- The Groth16 proof itself is the authorization. The relayer doesn't
  validate it; the on-chain entrypoint does (codex-r1 HIGH #1
  measured-delivery gate + r2 MED recipient-delta gate make sure a
  malicious adapter or under-delivery is caught contract-side).
- `RELAYER_MAX_FEE_BPS` (default 5%) blocks payloads requesting absurd
  relayer fees — a soft cap above what the on-chain
  `assetConfig[asset].maxRelayFeeBPS` would already enforce.
- Rate limit is in-memory (testnet only). Production-style deploys
  should sit this behind a real edge / WAF.

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
