# fx-Telaraña — TODOs from /plan-eng-review (2026-05-13)

## Blocking before Phase 0 starts
- [ ] **Verify Morpho Blue on Arc testnet.** Check Morpho Labs deployment registry. If absent, decide on self-deploy (Morpho Blue is permissionless + immutable).
- [ ] **Verify Uniswap v4 PoolManager on Arc.** Phase 2 +2 weeks if self-deploy is needed.
- [x] **Bufi Wallet KYC/KYB pass verifier interface.** Minimal `IBufiKycPass` interface and revocation semantics defined for Ghost Mode. Concrete RO-KYC verifier remains offchain/Pasillo-owned.
- [ ] **Verify Pyth + RedStone feed availability on Arc** for EUR/USD, USDC/USD, EURC/USD. List feed ids in `@bu/fx-engine/addresses/`.

## Implementation guardrails (track these explicitly)
- [x] `IFxOracle` is the single read path. Enforced by `bun run contracts:guardrails`.
- [x] `IFxSpoke.enterHub` MUST take explicit `beneficiary` arg. Enforced by `bun run contracts:guardrails`.
- [x] `sweepStrandedDeposit(messageNonce)` ships with `FxHubMessageReceiver` and sweeps to the stored beneficiary after grace. Enforced by `bun run contracts:guardrails`.
- [x] `EligibilityReason` enum lives in `@bu/fx-engine`, not duplicated. Enforced by `bun run contracts:guardrails`.
- [x] Every production contract file has an ASCII data-flow diagram in the file header comment. Enforced by `bun run contracts:guardrails`.
- [x] Ghost Mode privacy path uses Bufi Wallet pass + commitment/nullifier routing. No third-party privacy wallet or Circle Wallet dependency.

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
- [x] Phase 0.5: RedStone consumer wiring (`getMidVerified` reads signed payload from msg.data; deviation gate live)
- [ ] `@bu/fx-engine` TypeScript SDK (lives in desk-v1)
- [ ] Pasillo `/fx/*` routes (lives in desk-v1)
- [ ] Frontend money-market + swap pages (public mode only)
- [ ] End-to-end testnet drill: Base USDC → Arc Morpho supply, withdraw, borrow EURC, repay, liquidation

## Phase 1 deliverables (Ghost Mode)
- [x] Bufi Wallet KYC/KYB pass verifier interface.
- [x] `FxGhostCommitmentRegistry` with root metadata, root expiry, and nullifier replay protection.
- [x] `FxGhostSpokeRouter` wrapper for pass-gated `crossChainEnter` over Circle-only USDC/EURC `FxSpoke`.
- [ ] `FxGhostRouter` wrappers for supplyCollateral, borrow, repay, fxSwap, and withdraw.
- [x] `FxGhostWithdrawalRouter` mockable proof/nullifier withdrawal scaffold.
- [ ] Production ZK verifier integration and verifier-key governance for Ghost withdrawals.
- [x] `FxGhostKycHook` v1 scaffold for Ghost pools; no `tx.origin`, PoolManager-only callbacks, trusted router + pass verification only.
- [ ] `FxGhostSwapHook` proof-aware design for production Ghost pools.
- [ ] `/fx/eligibility/:wallet` + `EligibilityReason` enum using Bufi Wallet pass state.
- [ ] `/fx/ghost/prepare` and `/fx/ghost/proof` routes.
- [ ] Frontend shows Ghost Mode only when Bufi Wallet pass and route support are live.
- [ ] Client-side aggregate view across public and Ghost route accounts.

## Phase 2 deliverables (v4 hook)
- [x] `FxSwapHook.sol` with PMM curve params.
- [x] Rehypothecation: hook LP funds into Morpho M1/M2.
- [x] JIT withdrawal path tested under multiple inventory states.
- [ ] Gas budget verified <500K per swap on Arc/Tenderly deployment.

## Phase 3 deliverables (Arc mainnet GA + native privacy)
- [ ] Wire Arc native opt-in confidentiality precompile when published, if it composes safely with Ghost hooks.
- [ ] Audit (external).
- [ ] Mainnet deploy + monitoring.

## Open product decisions (spec § 12)
- [ ] Brand name (fx-Telaraña vs Bufi FX Engine vs other).
- [ ] Repo home (standalone vs desk-v1 monorepo).
- [ ] Governance / token (default: none; revisit post-mainnet).
- [ ] Phase 1+ spoke chain set order (Arb / Op / Polygon / Avalanche / Solana).

## v2 ambitions (not committed)
- [ ] Custom Ghost circuits for shielded health-factor proofs.
- [ ] Wormhole NTT for non-Circle assets.
- [ ] Bufi invoice factoring credit-delegation layer.
- [ ] Partner stables (BRLA, MXNB, JPYC).
- [ ] E-mode for USDC↔EURC if correlation justifies.
