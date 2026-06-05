# FxUsycAdapter + Gateway In-Transit Accounting Runbook

Status: prepared only. Do not broadcast from an unattended agent run.

## What Was Added

- `FxUsycAdapter`: Arc-only USYC holder with `KEEPER_ROLE`-gated `depositToYield` / `redeemFromYield` and `yieldAssets()` marked through `IUsycTeller.previewRedeem`.
- `SharedFxVault` accounting upgrade hooks:
  - `setYieldAdapter(adapter)`
  - `deploySeniorToYield(assets)`
  - `redeemSeniorFromYield(assets)`
  - `rebalanceYield(deployAssets, redeemAssets)` policy stub
  - `recordGatewayBurn(assets)`
  - `clearGatewayMint(assets)`
  - `gatewayInTransitUsdc()` and `yieldAdapterAssets()`

`totalAssets()` now includes hot senior USDC, live Morpho assets, `gatewayInTransitUsdc`, and configured adapter NAV. With `yieldAdapter == address(0)` and no in-transit balance, current deployed behavior is unchanged.

## Human-Gated Activation

1. Deploy `FxUsycAdapter` on Arc with Arc native USDC, USYC, and Teller addresses:
   - USDC: `0x3600000000000000000000000000000000000000`
   - USYC: `0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C`
   - Teller: `0x9fdF14c5B14173D74C08Af27AebFf39240dC105A`
2. Submit the deployed adapter address to Circle/Hashnote for USYC Entitlements approval. Deposits/redeems will revert until the adapter itself is entitled.
3. Upgrade the `SharedFxVault` proxy to the new implementation through the existing timelocked `UPGRADER_ROLE`.
4. From the vault admin, call `setYieldAdapter(adapter)`.
5. Grant `FxUsycAdapter.KEEPER_ROLE` to the `SharedFxVault` proxy so vault keeper calls can pull USDC into the adapter.
6. Grant `SharedFxVault.GATEWAY_ACCOUNTANT_ROLE` only to the audited Gateway accounting executor.

## Gateway Accounting Rule

When senior USDC is burned/locked for Gateway transfer, call `recordGatewayBurn(assets)` after the burn is accepted. When the matching destination mint is confirmed in the protocol book, call `clearGatewayMint(assets)`. During the in-flight window, `totalAssets()` remains stable because the burned amount moves from `seniorUsdcHot` to `gatewayInTransitUsdc`.

## Verification

Run from `contracts/`:

```bash
forge test --match-path test/vault/SharedFxVaultCrossChainAccounting.t.sol -vv
forge test --match-path 'test/vault/*.t.sol' -vv
```

The invariant `invariant_gatewayTransitDoesNotMoveSharePrice` proves `totalAssets()` and `convertToAssets()` stay constant across randomized burn/clear sequences.
