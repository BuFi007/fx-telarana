# Pre-Deploy Checklist — fx-Telaraña on Arc Testnet

Run through this before invoking `forge script script/DeployArcTestnet.s.sol --broadcast`.

## External dependencies

- [x] **Morpho Blue address on Arc testnet** — Morpho Labs deployment verified on-chain: `0x65f435eB4FF05f1481618694bC1ff7Ee4680c0A4`.
- [x] **AdaptiveCurveIrm address on Arc testnet** — verified on-chain and enabled in Morpho: `0xBD583cc9807980f9e41f7c8250f594fB6173abE3`.
- [x] **LLTV 86% enabled on Arc Morpho** — `isLltvEnabled(860000000000000000) == true`.
- [x] **Run the Morpho dependency gate before broadcast** — `forge script contracts/script/VerifyArcMorphoTestnet.s.sol:VerifyArcMorphoTestnet --root contracts --rpc-url "$ARC_TESTNET_RPC_URL" -vv`.
- [x] **Confirm cirBTC test collateral** — Arc token `0x44cEe9E472C34b2f0d9710CD8aBd02dadb912761` reads `FakeCirBTC` / `fCirBTC` / 18 decimals.
- [ ] **Confirm Pyth feed coverage on Arc** — `getUpdateFee` returns native-gas amount. Verify EUR/USD, USDC/USD, EURC/USD all publish on Arc with confidence < 30 bps.
- [ ] **Confirm RedStone signer set** — production uses `PrimaryProdDataServiceConsumerBase` (5 signers, threshold 3). Verify they're signing Arc-targeted payloads.

Morpho Labs cautioned that the Arc testnet Morpho configuration and dummy vault
do not reflect mainnet. Use the deployment for Arc wiring, not for production-like
liquidity assumptions. Source of truth: `deployments/morpho-arc-testnet.json`.

## Arc-specific behavior (encoded in `DeployArcTestnet.s.sol`)

- [ ] **USDC is native gas** — fund deployer via [faucet.circle.com](https://faucet.circle.com). No ETH needed.
- [ ] **18-decimal native unit, 6-decimal ERC-20 USDC** — `msg.value` is in 18-decimal units; `IERC20(USDC).balanceOf(x)` is in 6-decimal units. Never mix.
- [ ] **EVM is Prague** (superset of Cancun) — `foundry.toml` `evm_version = "cancun"` is safe.
- [ ] **Sub-second finality** — oracle staleness gate at 60s is wide enough; revisit if we observe Pyth lag.
- [ ] **`SELFDESTRUCT` is restricted during deployment** — we don't use it. Confirm.
- [ ] **`PREV_RANDAO` always 0 on Arc** — we don't use randomness. Confirm.

## Security — never deviate

- [ ] **Never pass `--private-key` as a flag in any deployment beyond local Anvil/Tenderly vnet**. Use an encrypted keystore: `cast wallet import deployer --interactive` then `forge script ... --account deployer`.
- [ ] **Deployer is a throwaway key** — transfer admin rights to a multisig (Circle Modular Wallet or Safe) immediately after deploy.
- [ ] **No mainnet target** — Arc is testnet only. Mainnet (Arc GA) gets a separate audited deploy.

## Post-deploy

- [ ] **Transfer `FxOracle.owner` to a TimelockController** (48h delay per spec § 3.3 of the engineering spec).
- [ ] **Transfer `FxMarketRegistry.owner`** to the same Timelock so market additions are governance-controlled.
- [ ] **Register all 8 contracts with Circle Smart Contract Platform** via `packages/sdk/scripts/register-contracts.ts`.
- [ ] **Set up Circle SCP event monitors** for `DepositStranded`, `DepositSwept`, `OracleDeviation`, `MarketRegistered`, `Entered`, `DepositExecuted`.
- [ ] **Set up Tenderly alerts** on the same events as a backup notification path.
- [ ] **Verify contracts on Arcscan** — `forge verify-contract` with `--verifier blockscout --verifier-url https://testnet.arcscan.app/api` (confirm URL with Arc team).
- [ ] **Persist live addresses** in `packages/sdk/src/addresses/index.ts` under `ChainId.ArcTestnet`.
- [ ] **Smoke test** — through a Tenderly Virtual TestNet forked from Arc:
  - USDC supply via `FxMarketRegistry.supply` → check Morpho position
  - USDC withdraw round-trip
  - Borrow with HF check (requires fresh RedStone payload via SDK)
  - Trigger `OracleDeviation` (admin-only test by skewing the secondary cache) → confirm revert
  - Simulate a stranded deposit → call `sweepStrandedDeposit` after grace

## SDK + dApp side-effects after Arc deploy

- [ ] Update `packages/sdk/src/addresses/index.ts` `ChainId.ArcTestnet` block with deployed contract addresses + `morphoBlue` + `adaptiveCurveIrm`.
- [ ] Pasillo: add Arc-aware fee surfacing — `gas_used * gas_price / 1e18` displayed as USDC (Arc native unit IS USDC at 18-decimal scaling).
- [ ] Frontend: route to `arcTestnet` chain in viem; show "fees in USDC" in UI cost surfaces.

## Reference links

- [Arc Docs · EVM compatibility](https://docs.arc.network/arc/references/evm-compatibility)
- [Arc Faucet](https://faucet.circle.com)
- [Arc Explorer](https://testnet.arcscan.app)
- [Pyth Hermes — fetch update payloads](https://docs.pyth.network/price-feeds/use-real-time-data/evm)
- [RedStone Pull Mode](https://docs.redstone.finance/docs/dapps/redstone-pull/)
- [Morpho Blue deployment repo](https://github.com/morpho-org/morpho-blue-deployment)
