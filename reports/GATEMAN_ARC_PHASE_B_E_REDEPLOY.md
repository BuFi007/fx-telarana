# Gateman Analysis: Arc Phase B-E Redeploy

Date: 2026-05-17

Scope: Arc Phase B-E redeploy, market/funding/liquidation configuration, protocol liquidity seed, manifest export, SDK address registry, and live trading smoke.

## Verdict

No blocking findings for the current Arc testnet handoff.

## Checks

- Assume nothing: the deployer key was validated by deriving the expected admin address before use; the key was not printed or committed.
- Question everything: live readiness was run both with explicit addresses and cold repo defaults after updating the defaults.
- Worship no one: SDK registry, manifests, README, scripts, and reports were grepped for retired Arc perps addresses; none remain in current handoff paths.
- Applaud humility: Arc native USDC `transferFrom` still cannot be simulated by Foundry's local EVM because of the blocklist precompile path, so the protocol liquidity seed was sent as direct live RPC transactions after non-token config broadcast succeeded.

## Evidence

- `forge test --root contracts --offline --match-path 'test/perp/*.t.sol'`: `15` passed, `0` failed.
- `forge build --root contracts --offline --sizes`: passed; Phase B-E contracts remain below 24 KB.
- `bun run perps:arc:config:verify`: passed against cold defaults.
- `bun run typecheck` in `packages/sdk`: passed.
- `bun test` in `packages/sdk`: `38` passed, `0` failed.
- `ARC_RPC_URL=https://rpc.testnet.arc.network bun packages/sdk/scripts/perp-arc-trading-smoke.ts`: passed.

## Residual Risk

The Arc liquidity seed path should remain documented as `approve` plus `depositProtocolLiquidity` direct live RPC transactions when bootstrapping a fresh stack, unless the Foundry simulation issue for Arc native USDC is resolved upstream or the script is split into a no-token config script and a token-seed helper.
