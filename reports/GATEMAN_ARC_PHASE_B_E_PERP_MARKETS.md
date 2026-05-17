# Gateman Analysis: Arc Phase B-E Perp Market Configuration

Date: 2026-05-17

Scope:

- `contracts/script/ConfigureArcPerpMarkets.s.sol`
- Arc market/funding/liquidation configuration broadcast
- Arc protocol liquidity seed
- `reports/CONFIG_ARC_PHASE_B_E_PERP_MARKETS.md`

## Result

No open blockers for the requested Arc testnet market-parameter, funding-parameter, liquidation-parameter, and protocol-liquidity configuration.

## Findings

### Resolved: Script lacked an explicit Arc chain guard

The first review found that the script was Arc-only by naming and constants, but did not enforce `block.chainid`. The script now reverts unless `block.chainid == 5042002`.

### Residual: Trading opens still need an oracle update path

The live configuration is set, but `FxPerpClearinghouse` depends on `FxOracle.getMid(baseToken, USDC)`. Current live calls can revert when Pyth prices are stale and no RedStone payload is supplied. This is not a configuration failure, but keeper/open-position flows must include a fresh oracle update path before live trade smoke.

## Checks

### Assume Nothing

- Chain guard added: `WrongChain(uint256)` on non-Arc execution.
- Addresses are fixed to the deployed Arc stack and can be overridden through env vars for reruns.
- Admin execution is enforced by on-chain roles; incorrect private key would fail at the target contracts.
- Seed target is idempotent: the script tops up to target and never withdraws if current liquidity exceeds target.

### Question Everything

- Non-token config dry-run passed before broadcast.
- Full liquidity seed could not be dry-run locally because Foundry's fork EVM cannot execute Arc native USDC's blocklist precompile path during `transferFrom`.
- Liquidity seed was executed as live `approve` and `depositProtocolLiquidity` transactions, then read back from chain.
- On-chain reads confirmed all four market configs, all four funding configs, liquidation config, and `100000000` protocol liquidity.

### Worship No One

- No private key material is committed or printed.
- `SafeERC20.forceApprove` is used in the reusable script for token approval.
- No new production math was introduced. Constants are admin parameters; market IDs use the repository's existing deterministic `keccak256("FX-PERP:<symbol>/USDC")` convention.
- `forge build --root contracts --offline --sizes` passed after the script hardening change.

### Applaud Humility

- The Arc-native USDC simulation limitation is documented instead of hidden.
- Existing repository warnings from build-size verification remain visible and were not misattributed to this change.
- The report separates deployed configuration from the remaining oracle-update requirement for live trading opens.

## Evidence

- Config report: `reports/CONFIG_ARC_PHASE_B_E_PERP_MARKETS.md`
- Perp tests: `forge test --root contracts --offline --match-path 'test/perp/*.t.sol' -vv`
  - `12` passed, `0` failed
  - Includes `256` fuzz runs and `256` invariant runs
- Build-size check: `forge build --root contracts --offline --sizes`
  - Passed, with existing unrelated warnings
