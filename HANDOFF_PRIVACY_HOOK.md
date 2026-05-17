# Privacy Hook — Handoff

**Current branch:** `feat/privacy-hook-slice-4-sdk`
**Slice 4 status:** ✅ TS SDK + permissive ASP postman skeleton
**Last green:** 306/306 Foundry + 52/52 Bun SDK tests, all 16 hub contracts under EIP-170

---

## What landed in slice 1

| Surface | Status |
|---|---|
| Vendored 0xbow privacy-pools-core Solidity (10 files, ~1,180 LoC) | ✅ `contracts/lib/privacy-pools/` |
| Vendored poseidon-solidity (T3 + T4) | ✅ `contracts/lib/poseidon-solidity/` |
| Vendored zk-kit lean-imt (InternalLeanIMT + Constants) | ✅ `contracts/lib/lean-imt/` |
| OZ contracts-upgradeable v5.0.2 submodule | ✅ `contracts/lib/openzeppelin-contracts-upgradeable/` |
| Foundry remappings: `privacy-pools/`, `interfaces/`, `@oz/`, `@oz-upgradeable/`, `poseidon/`, `lean-imt/` | ✅ |
| Pragma rewrite `0.8.28 → ^0.8.26` on vendored privacy-pools files | ✅ |
| `FxPrivacyPool.sol` (USDC ERC20 pool, owner-gated, Morpho hook points wired) | ✅ 5.3 KB deployed |
| `FxPrivacyEntrypoint.sol` (scaffold for slice-3 cross-currency extension) | ✅ 10 KB deployed |
| `check-eip170.ts` size guard extended | ✅ 16 contracts under limit |
| Unit tests: 15 covering constructor / ownership / deposit / wind-down / native rejection | ✅ |

**Architecture spec:** [`docs/PRIVACY_HOOK_SPEC.md`](docs/PRIVACY_HOOK_SPEC.md)
**Vendor map:** [`docs/PRIVACY_HOOK_VENDOR_MAP.md`](docs/PRIVACY_HOOK_VENDOR_MAP.md)

---

## Slices remaining (testnet path to feature-complete)

### Slice 2 — Morpho yield path ✅ LANDED

**Branch:** `feat/privacy-hook-slice-2-morpho`

- [x] `_pull` override: pulls ASSET from sender then `_rebalance()` supplies hot-excess to Morpho
- [x] `_push` override: `_ensureHot()` JIT-withdraws from Morpho when hot < amount, then transfers
- [x] Constructor extended: `_morpho`, `_registry`, `_collateral` + `hotReservePct` mutable (default 20%)
- [x] Pattern lifted from `FxSwapHook.sol:1014-1069` (paramsOf → MorphoMarketParams → supply/withdraw → expectedSupplyAssets)
- [x] Mainnet fork tests in `MainnetFork.t.sol` against real Morpho Blue (USDC/EURC market): deposit splits to hot+supply, owner-tightening hotPct round-trips through Morpho without loss
- [x] Owner-gated `setHotReservePct(uint16)` with bounds check + auto-rebalance
- [x] Helper views: `totalAssets()`, `hotBalance()`, `morphoSupplyAssets()`

### Slice 3 — cross-currency shielded swap ✅ LANDED

**Branch:** `feat/privacy-hook-slice-3-crossccy`

- [x] `FxPrivacyEntrypoint.relayCrossCurrency()` — withdraws shielded asset
      then atomically swaps to a buyToken before paying out to recipient
- [x] Reuses `IFxRouterSwapAdapter` (same interface as public `FxRouter` /
      PR-6 v4-unlock adapter — keeps the swap surface single-sourced)
- [x] `CrossCurrencyRelayData {recipient, feeRecipient, relayFeeBPS, buyToken, minBuyAmount}`
      decoded from `Withdrawal.data`; Groth16 `context` commits to full
      blob so a malicious relayer cannot alter swap target or slippage
- [x] Owner-gated `setSwapAdapter` + `setCrossCurrencyEnabled` (per-asset)
- [x] Relay fee skim in SELL asset, same shape as vendored `relay()`
- [x] Slippage bound enforced two ways: adapter's own minBuyAmount check
      + entrypoint asserts non-zero adapter return (`AdapterReturnedZero`)
- [x] 11 unit tests: happy path, fee skim, adapter underpay, unset adapter,
      asset disabled, buy==asset rejection, fee-over-max revert, owner gates

**NOT included this slice** (deferred items, mainnet-only):
- Production `IFxRouterSwapAdapter` wrapping v4 PoolManager.unlock + FxSwapHook
  (lives in the existing `FxRouter` PR-6 surface — slice 3 reuses the
  interface so we just inject the same adapter when PR-6 lands).
- External Uniswap V4 fallback adapter — testnet has ~zero v4 liquidity per
  spec §6; mainnet adapter is the same `IFxRouterSwapAdapter` shape but with
  an external V4 pool wrapped.

### Slice 4 — SDK + permissive ASP postman ✅ LANDED (skeleton)

**Branch:** `feat/privacy-hook-slice-4-sdk`

- [x] Vendored 0xbow TS SDK core into `packages/sdk/src/privacy/`:
      `constants`, `types`, `exceptions`, `crypto`, `circuits`, `withdrawal`,
      `crossCurrency` (fx-Telarana addition), barrel `index`
- [x] Retargeted to current viem 2.x (`bytesToNumber → bytesToBigInt`)
- [x] Added deps: `snarkjs`, `@zk-kit/lean-imt`, `maci-crypto`, `@types/snarkjs`
- [x] `UrlCircuits` loader: fetch `.wasm` / `.zkey` / `.vkey` from any
      CDN (default-free; explicit baseUrl required)
- [x] `WithdrawalService.proveWithdrawal` / `verifyWithdrawal` via snarkjs
- [x] `encodeCrossCurrencyRelayData` / `decodeCrossCurrencyRelayData`
      helpers — round-trip-safe `Withdrawal.data` for slice 3's relay path
- [x] 16 SDK unit tests (master keys, secrets, commitment hash, context
      hash matches Solidity, cross-ccy encode/decode, UrlCircuits)
- [x] `packages/relayer-privacy/` Bun service skeleton — permissive
      ASP postman: watches `Deposited`, maintains LeanIMT, periodically
      publishes a permissive root via `Entrypoint.updateRoot()`
      (testnet only; Uniswap V3 gas-swap layer stripped per spec)

**Still TODO in slice 4b** (post-merge follow-up):
- [ ] Commit `commitment.zkey` (901 KB), `*.vkey`, `*.wasm` artifacts (or
      decide CDN-only); document URL strategy
- [ ] account/data/contracts services (the viem wrappers — let dApp
      consumers query labels, build merkle proofs against live tree state)
- [ ] Real `Deposited` event indexing for label set (current skeleton
      uses commitments as leaves — slice 4b switches to `LeafInserted`
      events from each pool for accurate label tracking)
- [ ] Cross-currency relayer HTTP API (Hono) accepting withdrawal proofs
- [ ] E2E test on Fuji: deposit USDC → withdraw EURC to fresh address

---

## Permanently deferred (NOT in v1 — preserve as future work)

These items are intentionally out of scope for the testnet v1 ship. They are
the demarcation line between "testnet feature-complete privacy hook" and
"mainnet-ready Privacy Pools deployment."

1. **Cross-chain shielded transfers** (FxHubMessageReceiver / CCTP V2
   integration). Privacy pools stay single-chain in v1. Hyperlane/CCTP wire-up
   would let a user shield on Fuji and unshield on Arc (or any spoke), but
   requires either (a) per-chain pool replication with synchronized state
   roots (heavy), or (b) a shielded-bridge proof scheme (research-stage).
   Pick up only after mainnet ASP integration.

2. **Real ASP (Association Set Provider) screening.** v1 ships with a
   permissive postman bot that publishes "every label approved." Mainnet
   requires plugging in a real screening provider (Chainalysis Reactor, TRM,
   internal heuristic). Contract interface unchanged — only the postman
   replacement.

3. **Native asset pools** (ETH on Sepolia, AVAX on Fuji). v1 is ERC20-only.
   The vendored `PrivacyPoolSimple.sol` ships the native-asset variant; not
   imported in v1. Adding requires a parallel `FxPrivacyPoolNative.sol` plus
   entrypoint registry support.

4. **Ragequit UX in the SDK.** Slice 4 only ships forward-withdraw flows.
   Ragequit (original-depositor recovery without exposing secrets) is fully
   on-chain on the contract surface — it just needs SDK + dApp UI work.

5. **Mainnet deployment. Period.** v1 is testnet-only (Fuji + Arc). Mainnet
   deploy requires:
   - Real ASP integration (item 2)
   - Legal review of Tornado precedent / sanctions exposure
   - Trusted setup re-attestation or PSE ceremony reuse confirmation
   - Bug bounty / audit on the fx-Telaraña-specific overrides
   - Privacy-leakage analysis of cross-currency withdraw FX-rate exposure

---

## Next session quick-start

```bash
# Resume on the slice-2 branch
git checkout feat/privacy-hook-slice-2-morpho

# Cut slice 3
git checkout -b feat/privacy-hook-slice-3-crossccy

# Run privacy tests
cd contracts && forge test --match-contract FxPrivacyPoolTest -vv

# Fork test (requires ETH_RPC_URL)
cd contracts && ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test \
  --match-test test_fork_privacyPool -vvv

# Run full suite
cd contracts && forge test --no-match-contract MainnetForkTest

# Size guard
cd .. && bun run contracts:size:guard
```
