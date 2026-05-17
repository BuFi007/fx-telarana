# Phase B2E Work 3 Deployment Readiness

Date: 2026-05-17

Network: Arc testnet, chainId `5042002`

Scope: deployment-ready Phase B-E config verification and machine-readable
manifest output. No broadcast was performed.

## Added

- `contracts/script/ArcPerpConfigReadiness.s.sol`
  - `VerifyArcPerpConfig`: read-only verifier for deployed addresses, immutable
    pointers, roles, market params, funding params, liquidation params, and
    minimum protocol liquidity.
  - `ExportArcPerpConfig`: runs the same verifier and writes a flat JSON config
    manifest.
- `deployments/perps-config-5042002.json`
  - Live Arc config export for the six deployed perps contracts, USDC, oracle,
    admin/keeper, four market ids, risk params, funding params, liquidation
    params, OI readbacks, liquidity readbacks, and role booleans.
- Runbook updates in `docs/PHASE_B_E_PERP_STACK_RUNBOOK.md`.
- README link to the config manifest.

## Live Readbacks

- `protocolLiquidity()`: `101200327`
- Margin USDC balance: `102400000`
- `totalAccountMargin()`: `1199673`
- EURC/USDC OI long: `23232`
- EURC/USDC OI short: `638872`
- tJPYC, tMXNB, tCHFC OI long/short: `0`

## Commands Run

```bash
forge build --root contracts --offline --contracts contracts/script/ArcPerpConfigReadiness.s.sol

forge script contracts/script/ArcPerpConfigReadiness.s.sol:VerifyArcPerpConfig \
  --root contracts \
  --rpc-url https://rpc.testnet.arc.network \
  -vv

forge script contracts/script/ArcPerpConfigReadiness.s.sol:ExportArcPerpConfig \
  --root contracts \
  --rpc-url https://rpc.testnet.arc.network \
  -q

bun run perps:arc:config:verify
```

## Result

`VerifyArcPerpConfig` passed against live Arc. The export wrote
`deployments/perps-config-5042002.json` at block `42621031`.

Existing repository lint warnings remain unrelated to this patch.
