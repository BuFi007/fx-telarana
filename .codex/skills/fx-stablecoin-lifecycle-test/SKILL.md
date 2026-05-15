---
name: fx-stablecoin-lifecycle-test
description: Use when testing fx-Telarana stablecoin basket lending, borrowing, repayment, withdrawal, and swap coverage for Avalanche/Fuji/Tenderly rehearsals.
---

# FX Stablecoin Lifecycle Test

Use this workflow when the task asks whether all stablecoin loan/borrow paths are covered, or when validating the Avalanche basket before Tenderly/Fuji/mainnet deployment.

## Coverage Target

The basket matrix must cover every active Phase 3 asset:

- `USDC/JPYC`
- `USDC/MXNB`
- `USDC/AUDF`
- `USDC/KRW1`
- `USDC/ZCHF`

For each pair, tests must exercise both Morpho market directions:

- asset loan with USDC collateral
- USDC loan with asset collateral

Each direction must run:

1. `FxMarketRegistry.supply`
2. `FxMarketRegistry.supplyCollateral`
3. `FxMarketRegistry.borrow`
4. `FxMarketRegistry.repay`
5. `FxMarketRegistry.withdrawCollateral`
6. `FxMarketRegistry.withdraw`

The same contract should also keep the swap-path smoke test that deploys the pair hook, seeds liquidity, rehypothecates into Morpho, initializes the v4 pool, and executes exact-input USDC-to-asset swaps.

## Command

```bash
bun run contracts:smoke:basket
```

Expected result:

- `AvalancheBasketSmokeTest.test_basketDeploySeedAndSwapMatrix` passes
- `AvalancheBasketSmokeTest.test_basketLendBorrowRepayWithdrawMatrix` passes

If Morpho artifacts are missing, run:

```bash
cd contracts && forge build --force test/MorphoArtifacts.t.sol
```

## Notes

- This is a local/Tenderly-rehearsal matrix. It uses mocked basket tokens and a self-deployed Morpho instance while preserving the production registry/oracle/hook surfaces.
- Do not use a same-chain spoke for hub-chain UX. On the hub chain, call registry/router/hook contracts directly.

## Persisted Tenderly Manifest Drill

Use this when the task asks for a persisted vnet deployment rather than an in-test deployment.

1. Source the local Tenderly env file without printing secrets.
2. Confirm the selected vnet chain id is `43113` for Fuji.
3. Broadcast the testnet-only basket deploy script:

```bash
cd contracts
forge script script/DeployTenderlyAvalancheBasket.s.sol:DeployTenderlyAvalancheBasket \
  --rpc-url "$TENDERLY_POSTMIGRATE_VNET_ADMIN_RPC" \
  --broadcast \
  --skip-simulation \
  --slow
```

The script writes `deployments/tenderly-avalanche-fuji-basket.json` only as a deployment manifest for that vnet. If transaction submission fails, delete the dry-run manifest and do not treat those addresses as live.

4. Run the address-based drill against the same vnet:

```bash
cd contracts
FXT_BASKET_MANIFEST=../deployments/tenderly-avalanche-fuji-basket.json \
  forge test --match-contract AvalancheBasketManifestTest \
  --fork-url "$TENDERLY_POSTMIGRATE_VNET_PUBLIC_RPC" -vv
```

Expected result:

- `test_manifestAddressesAndSeededHooks` confirms every manifest address has code, 10 markets are registered, every pair is live, and seeded hooks hold Morpho shares.
- `test_manifestSwapMatrix` executes USDC-to-asset swaps for every basket pair through the deployed `PoolManager` + hook.
- `test_manifestLendBorrowRepayWithdrawMatrix` runs both Morpho directions for every basket pair.

If Tenderly returns `quota limit` on `eth_sendRawTransaction`, the blocker is external to the repo. Keep the deploy script and manifest test, but report the vnet deployment as not persisted.
