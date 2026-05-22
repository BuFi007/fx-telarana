# `@bu/fx-telarana-api`

HTTP gateway wrapping `@bu/fx-engine` for downstream consumption by fx-pasillo (B2B API), BUFX (execution layer), and future services.

## Why this exists

The SDK is a pure TypeScript transaction-builder library — `planSupply`, `planBorrow`, `planEnterHub`, etc. To use it from another service (Cloudflare Worker, edge function, JVM, etc.) you'd otherwise need to bundle the SDK + viem + all transitive deps into your runtime. This gateway hides that behind REST.

The closure path for this is documented in [`docs/plans/2026-05-21-bucket-analysis-ecosystem.md`](../../../fx-pasillo/docs/plans/2026-05-21-bucket-analysis-ecosystem.md) (Seam #1) in the fx-pasillo repo.

## Auth

Shared secret in the `X-API-Key` header. Set `TELARANA_API_KEY` in env. In `NODE_ENV !== 'production'` the gateway accepts unauthenticated requests (dev convenience). In production, missing key returns 503.

This is service-to-service auth — Pasillo holds the secret and transforms B2B integrator calls into Telarana calls. Integrators never hit this gateway directly.

## Routes

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/health` | — | `{service, status, timestamp, version}`; public, no auth |
| GET | `/markets/hubs` | — | Hub addresses (Fuji + Arc): registry, receiver, hook, oracle, liquidator |
| GET | `/markets/spokes` | — | Spoke addresses per chain (Sepolia, OP, Arb, Polygon, Unichain, Worldchain, local Fuji + Arc) |
| GET | `/markets/pairs` | — | Static pair catalog (USDC↔EURC across both hubs) |
| POST | `/calldata/supply` | `{chainId, loanToken, collateralToken, assets, onBehalf}` | `{chainId, to, value, calldata}` |
| POST | `/calldata/borrow` | `{chainId, loanToken, collateralToken, assets, onBehalf, receiver}` | same |
| POST | `/calldata/supply-collateral` | `{chainId, loanToken, collateralToken, collateral, onBehalf}` | same |
| POST | `/calldata/withdraw` | `{chainId, loanToken, collateralToken, shares, onBehalf, receiver}` | same |
| POST | `/calldata/repay` | `{chainId, loanToken, collateralToken, assets, onBehalf}` | same |
| POST | `/calldata/enter-hub` | `{chainId, hub:'fuji'|'arc', token, amount, beneficiary, hubCalldata}` | same |

All amount fields are decimal strings in smallest units (micro-USDC, etc.) — no JS-float risk.

## Run

```bash
cd apps/api
bun install   # (or from monorepo root)
TELARANA_API_KEY=dev-secret bun --hot run src/index.ts
```

Default port: `4040`. Override with `PORT=...`.

## Smoke

```bash
curl http://localhost:4040/health
curl -H 'X-API-Key: dev-secret' http://localhost:4040/markets/hubs
```

## Deployment

This service is **AGPL-3.0-only**, not Apache-2.0 like the SDK. Per repo `CLAUDE.md`: "Apache-2.0 for SDK/contracts/protocol; AGPL-3.0-only for backend/API/indexer/agent/workflow services."

Target deploy environment: Fly.io / Render / Cloud Run — any long-lived Bun/Node host. **Not Cloudflare Workers** (workerd) because v2 will add on-chain RPC reads where a long-lived runtime is cheaper than per-request CF Workers cold-starts.

## What's not here (P3+)

- Live on-chain market state (utilization, borrow rate, supply rate) for `/markets/pairs` — currently static catalog.
- Per-tenant rate limiting — relies on Pasillo for that layer.
- Funding-tracking webhook subscribers — Telarana's events are on-chain; an indexer (existing `packages/ponder`) is the canonical source.
- Hyperlane helpers (`planHyperlaneWarpTransferRemote`, etc.) — add when Pasillo needs cross-chain non-USDC routes.
