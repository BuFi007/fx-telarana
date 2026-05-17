# Phase A — Spot FX Executor

Phase A v0.2 of the on-chain perp protocol roadmap. Closes the Stage 12 spot-FX
gap so `MINT_AND_REQUEST_SPOT_FX` requests actually deliver tokenOut to the
trader instead of stopping at the `GatewayAtomicFxSwapRequested` event.

## Architecture

```
trader (Fuji)
  └─ BUFX requestSpot (action = MINT_AND_REQUEST_SPOT_FX, tokenOut = EURC)
       └─ BUFX TelaranaRequestRouter records receipt + emits TelaranaGatewayMintContextPrepared

  keeper (off-chain, EOA)
  └─ approves USDC + calls FxHubMessageReceiver.relayToRemoteHub on Fuji
       └─ FxGatewayHook.lockForRemote → Circle Gateway locks USDC

  Circle Gateway signer service (in repo)
  └─ signs BurnIntent with destinationCaller = Arc TGH
       └─ Circle operator attests within ~350ms

  keeper
  └─ calls TGH.receiveGatewayMint on Arc
       └─ TGH mints USDC against attestation
       └─ TGH forwards USDC to route.destinationHub = FxSpotExecutor
       └─ TGH emits GatewayAtomicFxSwapRequested

  keeper
  └─ calls FxSpotExecutor.executeSpotFx(requestId) on Arc         <-- Phase A
       ├─ validates TGH receipt for requestId
       ├─ reads FxOracle.getMid(USDC, tokenOut)
       ├─ scales USDC atomic units through 18-dec oracle precision
       ├─ scales payout to receipt.tokenOut decimals
       ├─ applies configured spread
       ├─ asserts amountOut >= minAmountOut
       ├─ transfers tokenOut to receipt.recipient
       └─ calls TGH.markGatewayAtomicFxSwapSettled
```

## Contract surface

`contracts/src/spot/FxSpotExecutor.sol`

Roles:
- `DEFAULT_ADMIN_ROLE` — token allowlist + spread config + oracle mode + role admin.
- `OPERATIONS_ROLE` — manage liquidity reserves, pause/unpause.
- `EXECUTOR_ROLE` — call `executeSpotFx`.

Key methods:
- `executeSpotFx(bytes32 requestId)` — the one keeper-callable entry.
- `addLiquidity(token, amount)` / `withdrawLiquidity(token, amount, to)` — owner-only seed pool.
- `setTokenEnabled(token, bool)` — allowlist tokenOut and store its decimals.
- `setDefaultSpreadBps(bps)` / `setTokenSpreadBps(token, bps)` — capped at 500 bps (5%).
- `setRequireVerifiedOracle(bool)` — opt-in to RedStone + Pyth deviation gate.

## Deployment

```bash
# Per-chain. Example: Arc testnet.
DEPLOYER_PRIVATE_KEY=0x... \
USDC=0x3600000000000000000000000000000000000000 \
FX_ORACLE=0x77b3A3B420dB98B01085b8C46a753Ed9879e2865 \
TELARANA_GATEWAY_HUB_HOOK=0x74E894aFf25c89d707873347cd2554d30E0541fa \
DEFAULT_SPREAD_BPS=5 \
forge script script/DeployFxSpotExecutor.s.sol:DeployFxSpotExecutor \
  --rpc-url https://rpc.testnet.arc.network --broadcast --slow --skip-simulation
```

## Post-deploy wiring (do NOT skip)

1. **Enable tokenOut on the executor** (e.g. EURC). This stores
   `IERC20Metadata.decimals(tokenOut)` for decimal-aware payout scaling:
   ```
   FxSpotExecutor.setTokenEnabled(EURC, true)
   ```
2. **Seed liquidity** — owner approves + deposits tokenOut so swaps can settle:
   ```
   EURC.approve(FxSpotExecutor, seed)
   FxSpotExecutor.addLiquidity(EURC, seed)
   ```
3. **Grant the keeper EXECUTOR_ROLE on the executor**:
   ```
   FxSpotExecutor.grantRole(EXECUTOR_ROLE, keeper)
   ```
4. **Grant FxSpotExecutor EXECUTOR_ROLE on TGH** — required so the executor
   can call `markGatewayAtomicFxSwapSettled`:
   ```
   TelaranaGatewayHubHook.grantRole(EXECUTOR_ROLE, FxSpotExecutor)
   ```
5. **Configure a NEW TGH route for spot-fx flows** whose `destinationHub`
   is the FxSpotExecutor (separate from any MINT_TO_HUB route which keeps
   its destinationHub pointing at the FxHubMessageReceiver):
   ```
   TGH.setGatewayRoute(spotFxRouteId, GatewayHubRoute({
     sourceDomain: <src>,
     destinationDomain: <dst>,
     sourceUsdc: <src USDC>,
     destinationUsdc: <dst USDC>,
     sourceGatewayWallet: 0x0077777d7EBA4688BDeF3E311b846F25870A19B9,
     destinationGatewayMinter: 0x0022222ABE238Cc2C7Bb1f21003F0a260052475B,
     destinationHub: <FxSpotExecutor address>,            // <-- the key change
     whitelistedCaller: address(0),
     signerMode: GatewaySignerMode.EOA,
     enabled: true,
     metadataRef: ...
   }))
   ```
6. **Configure BUFX TelaranaRouter with the new spot-fx routeId** so
   BUFX submits MINT_AND_REQUEST_SPOT_FX requests under it:
   ```
   BUFX.BuFxTelaranaRequestRouter.setTelaranaRoute(spotFxRouteId, TelaranaRoute({
     sourceDomain: <src>,
     destinationDomain: <dst>,
     sourceChainId: <src chain id>,
     destinationChainId: <dst chain id>,
     sourceUsdc: <src USDC>,
     destinationUsdc: <dst USDC>,
     telaranaReceiver: <TGH address>,  // unchanged from MINT_TO_HUB route
     enabled: true,
     metadataRef: ...
   }))
   ```

The keeper smoke script's `--action=bufx-request --request-variant=spot-fx`
should pass this new routeId.

## v0 limits + future phases

- **Single-leg only**: USDC → enabled tokenOut. Reverse (tokenIn → USDC)
  comes when we wire the executor as a Uniswap v4 spot hook in v1.
- **Owner-managed reserves**: no LP token, no rehypothecation. Phase F
  replaces this with a MetaMorpho vault-backed pool so idle USDC earns
  Morpho lending yield and tokenOut reserves can be borrowed against
  cross-pair collateral.
- **Decimal-aware payout math**: v0.2 supports non-6-dec tokenOut assets by
  scaling USDC atomic units to 18-dec oracle precision and then to tokenOut
  decimals, following the vendored Synthetix v3 `Price.scale/scaleTo`
  pattern. Token decimals are capped by `MAX_TOKEN_DECIMALS`.
- **No price impact curve**: constant mid-anchored spread for v0. Stable
  pairs (USDC↔EURC) can sustain this; volatile pairs (when added) need
  a PMM curve modeled on `FxSwapHook.sol`'s rehypothecating-PMM design.
- **Pyth-only oracle by default**: opt into Pyth+RedStone deviation gate
  via `setRequireVerifiedOracle(true)` once the keeper wraps its tx with
  RedStone SDK calldata.
- **No matchable orderbook**: this is a sole-counterparty pool. The
  orderbook layer comes in Phase E (signed-order off-chain matching +
  on-chain settlement).

## What this unblocks

- Stage 12 #6 actually delivers tokenOut to the trader instead of dead-ending
  at the `GatewayAtomicFxSwapRequested` event.
- BUFX UI can show a true USDC→EURC quote that settles on-chain.
- The perp engine (Phase B) needs a hedge venue — this is it for v0.
