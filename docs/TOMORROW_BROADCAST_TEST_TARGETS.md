# Tomorrow Broadcast Test Targets

This is the focused contract and circuit list for the Fuji + Arc fresh
deployment wiring pass. Do not publish addresses or manifests until the
chain-specific readiness exporters pass against live RPC after broadcast.

## Perp Stack

Freshly deploy and verify on each target chain:

- `FxOracle` - sprint-1 hard caps present; `config()` non-zero and within
  `1800s / 500bps / 500bps`.
- `FxMarginAccount` - USDC custody, protocol liquidity, reserved margin, and
  funding settlement hook.
- `FxPerpClearinghouse` - market config, open/increase/decrease/close,
  liquidation close path, and order settlement role.
- `FxFundingEngine` - funding config, poke, settle, and version index.
- `FxHealthChecker` - maintenance margin, strict verified-oracle liquidation
  gate.
- `FxLiquidationEngine` - `flagAccount`, `rescindFlag`, `liquidate`,
  auto-rescind, and `flagDelay >= 60s` live readback.
- `FxOrderSettlement` - EIP-712 matching and nonce burn.

Broadcast/readiness scripts to run around the deploy:

- `DeployPerpOracle.s.sol`
- `DeployFxPerpStack.s.sol`
- `ConfigureArcPerpMarkets.s.sol`
- `ConfigureFujiPerpMarkets.s.sol`
- `ArcPerpConfigReadiness.s.sol`
- `FujiPerpConfigReadiness.s.sol`
- `RetireOldPerpStack.s.sol`

RedStone production-path smoke:

- `packages/sdk/scripts/perp-redstone-smoke.ts`
- `packages/sdk/src/perps-keeper.ts::writeWithRedstone`
- Keeper calls wrapped with RedStone payloads: `flagAccount`, `rescindFlag`,
  `liquidate`.

## Hub, Spoke, And Gateway

Probe the deployed contracts that move funds or authorize cross-chain minting:

- `FxSpoke` on eth-sepolia, op-sepolia, arbitrum-sepolia, polygon-amoy,
  unichain-sepolia, worldchain-sepolia, arc-testnet, and Fuji.
- `FxHubMessageReceiver` on Fuji and Arc.
- `TelaranaGatewayHubHook` on Fuji.
- `FxGatewayHook` for Fuji <-> Arc protocol-owned USDC transfer.
- `FxHyperlaneHubReceiver` and `FxSpokeIntentRouter` for non-USDC intent
  routes.
- `FxMarketRegistry`, `FxReceipt`, and `MorphoOracleAdapter` for lending
  market wiring.
- `FxSwapHook` and `FxSpotExecutor` for constant-spread swap MVP coverage.

Required invariants:

- Every spoke calls `enterHub(token, amount, beneficiary, hubCalldata)` with an
  explicit privacy-route beneficiary.
- Fuji/Arc hub receivers reject non-allowlisted `(sourceDomain, sender)` pairs.
- Only hub/gateway contracts can call Circle Gateway movement paths.
- Any stranded CCTP deposit remains sweepable only after the 24 hour grace.

## Privacy Contracts And Circuits

Privacy contract targets:

- `FxGhostCommitmentRegistry`
- `FxGhostSpokeRouter`
- `FxGhostKycHook`
- Live privacy pool entrypoint/verifier contracts referenced by the deployment
  manifests or RPC discovery.

Circuit artifacts to prove before user-facing privacy flows are advertised:

- `packages/privacy-prover/circuits/commitment.wasm`
- `packages/privacy-prover/circuits/commitment.zkey`
- `packages/privacy-prover/circuits/withdraw.wasm`
- `packages/privacy-prover/circuits/withdraw.zkey`

Circuit/e2e scripts:

- `packages/privacy-prover/dist/b5-deposit.mjs`
- `packages/privacy-prover/dist/b5-withdraw.mjs`
- `packages/privacy-prover/dist/b5-cross-currency.mjs`

Privacy checks:

- Deposit registers a commitment, emits `LeafInserted`, and advances the root.
- Valid Groth16 withdraw proof succeeds; malformed proof fails.
- USDC-shielded to EURC withdrawal works on Fuji and Arc.
- Cross-chain pool migration is rejected by per-chain root/nullifier state.
- Exactly one live address holds `ASP_POSTMAN_ROLE` for each pool.
- `packages/sdk/src/**` has zero imports of `@bu/privacy-prover`.

## Stablecoin And Morpho Basket

Use the local stablecoin lifecycle matrix before broadcast rehearsal:

```bash
bun run contracts:smoke:basket
```

The matrix must cover `USDC/JPYC`, `USDC/MXNB`, `USDC/AUDF`, `USDC/KRW1`, and
`USDC/ZCHF` in both Morpho directions:

- asset loan with USDC collateral;
- USDC loan with asset collateral.

Each direction must exercise `supply`, `supplyCollateral`, `borrow`, `repay`,
`withdrawCollateral`, and `withdraw`.

## Manifest Rule

Treat `deployments/perps-config-5042002.json` and
`deployments/perps-config-43113.json` as readiness targets until the fresh stack
is broadcast and the exporters rewrite them from live state. Pass the freshly
deployed stack addresses explicitly; the scripts intentionally do not default to
old live perp contracts. Pass the freshly deployed sprint-1 `FxOracle`
explicitly too; historical hub oracles that lack hard-cap selectors are a ship
blocker.

```bash
forge script contracts/script/DeployPerpOracle.s.sol:DeployPerpOracle \
  --root contracts --rpc-url "$ARC_RPC_URL" --broadcast -vvvv

forge script contracts/script/DeployPerpOracle.s.sol:DeployPerpOracle \
  --root contracts --rpc-url "$FUJI_RPC_URL" --broadcast -vvvv

ARC_PERP_CLEARINGHOUSE=0x... ARC_PERP_MARGIN=0x... \
ARC_PERP_FUNDING=0x... ARC_PERP_HEALTH=0x... \
ARC_PERP_LIQUIDATION=0x... ARC_PERP_SETTLEMENT=0x... \
ARC_FX_ORACLE=0x... \
bun run perps:arc:config:verify

ARC_PERP_CLEARINGHOUSE=0x... ARC_PERP_MARGIN=0x... \
ARC_PERP_FUNDING=0x... ARC_PERP_HEALTH=0x... \
ARC_PERP_LIQUIDATION=0x... ARC_PERP_SETTLEMENT=0x... \
ARC_FX_ORACLE=0x... \
bun run perps:arc:config:export

FUJI_PERP_CLEARINGHOUSE=0x... FUJI_PERP_MARGIN=0x... \
FUJI_PERP_FUNDING=0x... FUJI_PERP_HEALTH=0x... \
FUJI_PERP_LIQUIDATION=0x... FUJI_PERP_SETTLEMENT=0x... \
FUJI_FX_ORACLE=0x... \
bun run perps:fuji:config:verify

FUJI_PERP_CLEARINGHOUSE=0x... FUJI_PERP_MARGIN=0x... \
FUJI_PERP_FUNDING=0x... FUJI_PERP_HEALTH=0x... \
FUJI_PERP_LIQUIDATION=0x... FUJI_PERP_SETTLEMENT=0x... \
FUJI_FX_ORACLE=0x... \
bun run perps:fuji:config:export
```

If the live readback returns `liquidation_flagDelay < 60`, the deployment is not
ready for keepers, UI, or integrator address publication.
