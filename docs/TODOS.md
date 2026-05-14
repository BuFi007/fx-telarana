# fx-Telaraña — TODOs from /plan-eng-review (2026-05-13)

## Blocking before Phase 0 starts
- [ ] **Verify Morpho Blue on Arc testnet.** Check Morpho Labs deployment registry. If absent, decide on self-deploy (Morpho Blue is permissionless + immutable).
- [ ] **Verify Uniswap v4 PoolManager on Arc.** Phase 2 +2 weeks if self-deploy is needed.
- [ ] **Pasillo↔Hinkal partner conversation.** Bufi-KYC → Hinkal AccessToken issuance API. Phase 1 blocker.
- [ ] **Verify Pyth + RedStone feed availability on Arc** for EUR/USD, USDC/USD, EURC/USD. List feed ids in `@bu/fx-engine/addresses/`.

## Implementation guardrails (track these explicitly)
- [ ] `IFxOracle` is the single read path. Lint rule + code-review check.
- [ ] `IFxSpoke.enterHub` MUST take explicit `beneficiary` arg.
- [ ] `sweepStrandedDeposit(messageNonce, beneficiary)` ships with `FxSpoke`.
- [ ] `EligibilityReason` enum lives in `@bu/fx-engine`, not duplicated.
- [ ] Every contract file has an ASCII data-flow diagram in the file header comment.
- [ ] Fresh-SCA-per-deposit via Circle MSCA factory in confidential path.

## Phase 0 deliverables (public-only ship)

**Contracts — DONE (31/31 tests passing, fork-verified against mainnet Morpho)**
- [x] `FxOracle.sol` with Pyth + RedStone slot, deviation gate, confidence band, 24/7
- [x] `MorphoOracleAdapter.sol` bridging IFxOracle → Morpho IOracle(price())
- [x] `FxMarketRegistry.sol` routing over Morpho Blue isolated markets
- [x] `FxReceipt.sol` ERC-4626 wrapper per asset
- [x] `FxLiquidator.sol` permissionless keeper wrapper
- [x] `FxSpoke.sol` (CCTP V2 depositForBurnWithHook) for Ethereum + Base
- [x] `FxHubMessageReceiver.sol` (CCTP V2 inbound + executor + stranded-deposit sweep)
- [x] `CctpMessageLib.sol` byte decoder
- [x] Unit tests (mocks for Pyth, CCTP MessageTransmitter, CCTP TokenMessenger)
- [x] Mainnet fork tests against real Morpho Blue (Ethereum mainnet)
- [x] Deploy scripts: `DeployFxHub.s.sol`, `DeployFxSpoke.s.sol`

**Still TODO before Arc testnet ship**
- [ ] Confirm Morpho Blue address on Arc (or self-deploy — it's permissionless + immutable)
- [ ] Confirm AdaptiveCurveIrm address on Arc (or self-deploy)
- [ ] Phase 0.5: RedStone consumer wiring in `FxOracle.getMidWithUpdate`
- [ ] `@bu/fx-engine` TypeScript SDK (lives in desk-v1)
- [ ] Pasillo `/fx/*` routes (lives in desk-v1)
- [ ] Frontend money-market + swap pages (public mode only)
- [ ] End-to-end testnet drill: Base USDC → Arc Morpho supply, withdraw, borrow EURC, repay, liquidation

## Phase 1 deliverables (confidential mode)
- [ ] Hinkal partner deal signed.
- [ ] 5 wrappers in `@bu/private-transfer-core` (shieldedSupplyCollateral, shieldedBorrow, shieldedRepay, shieldedFxSwap, shieldedCrossChainEnter).
- [ ] Circle MSCA factory integration on Arc — fresh SCA per deposit.
- [ ] `/fx/eligibility/:wallet` + `EligibilityReason` enum.
- [ ] `/fx/hinkal/accesstoken` provisioning route.
- [ ] Frontend auto-routes confidential when AccessToken detected (no toggle).
- [ ] Multi-SCA aggregate view client-side.

## Phase 2 deliverables (v4 hook)
- [ ] `FxSwapHook.sol` with PMM curve params.
- [ ] Rehypothecation: hook LP funds into Morpho M1/M2.
- [ ] JIT borrow path tested under multiple inventory states.
- [ ] Gas budget verified <500K per swap on Arc.

## Phase 3 deliverables (Arc mainnet GA + native privacy)
- [ ] Wire Arc native opt-in confidentiality precompile when published.
- [ ] Audit (external).
- [ ] Mainnet deploy + monitoring.

## Open product decisions (spec § 12)
- [ ] Brand name (fx-Telaraña vs Bufi FX Engine vs other).
- [ ] Repo home (standalone vs desk-v1 monorepo).
- [ ] Governance / token (default: none; revisit post-mainnet).
- [ ] Phase 1+ spoke chain set order (Arb / Op / Polygon / Avalanche / Solana).

## v2 ambitions (not committed)
- [ ] Custom Hinkal circuits for shielded health-factor proofs (collapses fresh-SCA-per-deposit pattern).
- [ ] Wormhole NTT for non-Circle assets.
- [ ] Bufi invoice factoring credit-delegation layer.
- [ ] Partner stables (BRLA, MXNB, JPYC).
- [ ] E-mode for USDC↔EURC if correlation justifies.
