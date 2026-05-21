# FxPrivacyHook — Architecture Spec & Vendor Manifest

**Status:** Discovery — branch `tcxcx/privacy-hook-discovery`
**Date:** 2026-05-16
**Author:** Claude (post-discovery pass on 0xbow/privacy-pools-core @ commit `HEAD~`, May 2026)

---

## 1. Goal

Add a privacy layer to fx-Telaraña so users can deposit publicly into a per-currency pool and withdraw privately to a fresh address. While funds sit shielded, they earn Morpho supply APY. Cross-currency withdraws (deposit USDC → withdraw EURC) route through the existing FxSwapHook (DODO PMM); if internal LP is insufficient, fall back to external Uniswap V4 USDC/EURC pools.

**Hard constraint:** **No novel cryptography. No new circuits. No re-derived math.** Vendor every primitive from an audited reference.

**Scope:**
- Testnet only (Fuji primary hub, Arc trading hub).
- No KYC for testnet — but architecture stays mainnet-compatible by keeping the ASP interface and running a *permissive* postman bot.

---

## 2. Vendor source

### Primary vendor: 0xbow-io/privacy-pools-core

| Property | Value |
|---|---|
| Repo | https://github.com/0xbow-io/privacy-pools-core |
| License | Apache-2.0 ✓ matches `contracts/` license |
| Mainnet status | Live on Ethereum since Apr 2025 (Privacy Pools, Vitalik-backed) |
| Audits | 4 reports under `audit/` |
| | • Oxorio — contracts (Mar 2025) |
| | • Oxorio — circuits (Feb 2025) |
| | • Oxorio — Entrypoint upgrade |
| | • Auditware — contracts |
| Verdict | Production-ready. No critical findings post-remediation. |

### Solidity contracts (`packages/contracts/src/`)

| File | Lines | Status | Note |
|---|---|---|---|
| `lib/Constants.sol` | 9 | **Keep** | SNARK field, NATIVE_ASSET sentinel |
| `lib/ProofLib.sol` | 167 | **Keep** | Public-signal accessors for Groth16 proofs |
| `lib/DeployLib.sol` | 39 | **Keep** | CreateX deployment helper |
| `State.sol` | 183 | **Keep** | Merkle tree + nullifier + root history |
| `PrivacyPool.sol` | 186 | **Keep** | Base deposit/withdraw/ragequit; abstract `_pull`/`_push` |
| `implementations/PrivacyPoolComplex.sol` | 68 | **Extend → FxPrivacyPool** | ERC20 variant — we override `_pull`/`_push` to plumb Morpho |
| `implementations/PrivacyPoolSimple.sol` | 57 | **Strip** | Native-ETH variant — no native asset on Fuji/Arc |
| `Entrypoint.sol` | 402 | **Keep, modify** | UUPS + AccessControl multi-pool router |
| `verifiers/WithdrawalVerifier.sol` | 219 | **Keep** | Auto-generated Groth16 verifier |
| `verifiers/CommitmentVerifier.sol` | 191 | **Keep** | (= "RagequitVerifier" in pool constructor) Auto-gen Groth16 |
| `interfaces/I*.sol` | ~800 | **Keep** | Full interface surface |

**~1,200 LoC of Solidity to vendor as-is**, plus ~150 LoC fx-Telaraña-specific overrides.

### Circom circuits (`packages/circuits/circuits/`)

| File | Lines | Status |
|---|---|---|
| `commitment.circom` | ~80 | **Keep verbatim** — Poseidon hasher |
| `merkleTree.circom` | ~60 | **Keep verbatim** — IMT inclusion proof |
| `withdraw.circom` | ~150 | **Keep verbatim** — main spend circuit |

**Total: 117 audited circuit lines.** Reused as-is. **No circuit changes** — that would invalidate the trusted setup.

### Trusted setup artifacts

`packages/circuits/trusted-setup/final-keys/`:
- `commitment.zkey`, `commitment.vkey`
- `withdraw.zkey`, `withdraw.vkey`

**Reuse PSE's ceremony output directly.** We do not run a new ceremony. The `.zkey` files are 10–100 MB and stay in our SDK bundle (or CDN-hosted via `fetchArtifacts.ts` pattern that 0xbow's SDK already implements).

### Build outputs (already present in 0xbow repo)

`packages/circuits/build/{commitment,withdraw}/`:
- `*.r1cs`, `*.sym` (constraint system metadata)
- `*_js/{*.wasm, witness_calculator.js}` (witness generation)
- `groth16_pkey.zkey`, `groth16_vkey.json`

**All reusable as-is** for client-side proof generation via snarkjs.

### TS SDK (`packages/sdk/`)

| Path | Status | Note |
|---|---|---|
| `src/core/*.service.ts` | **Reuse** | account/commitment/withdrawal/data services |
| `src/circuits/circuits.impl.ts` | **Reuse** | snarkjs WASM wrapper |
| `src/circuits/fetchArtifacts.*` | **Reuse** | CDN artifact loading |
| `src/abi/*.ts` | **Replace** | Regenerate against our FxPrivacyPool ABI |
| `src/crypto.ts` | **Reuse** | Poseidon, secret/nullifier gen |

Wire into our existing `packages/sdk/` workspace as a sub-module — does not need its own package.

### Relayer (`packages/relayer/`)

| Concern | Status |
|---|---|
| Uniswap V3 swap-for-gas (relayer charges in shielded token, swaps to ETH) | **Strip** — testnet, USDC is gas on Arc, AVAX on Fuji, relayer paid in native |
| Quote provider | **Strip** — no swap-for-gas |
| HTTP API (Fastify) | **Reuse as reference**, port to Hono in our backend |
| SQLite session storage | **Reuse** |
| ASP-postman bot logic | **Reuse, mode = permissive** (testnet) |

Net: vendor the relayer pattern, drop the gas-swap layer, run as Bun service.

---

## 3. External dependencies to add

These are pinned at the versions 0xbow uses (npm `yarn.lock`):

| Dep | Purpose | License | Audit |
|---|---|---|---|
| `poseidon-solidity` | `PoseidonT4` hasher (BN254 field, Solidity) | MIT | PSE-audited |
| `@zk-kit/lean-imt.sol` | Lean Incremental Merkle Tree (Semaphore stack) | MIT | PSE-audited |
| `@openzeppelin/contracts-upgradeable` | UUPS, AccessControl, ReentrancyGuard | MIT | OZ-audited |
| `circomlib` (TS side) | Poseidon JS for client-side commitment gen | GPL-3.0 | PSE-audited |
| `snarkjs` (TS side) | Groth16 prover (WASM) | GPL-3.0 | PSE-audited |

**Vendor strategy:** `contracts/lib/privacy-pools/` for the Solidity drop, `contracts/lib/lean-imt/` and `contracts/lib/poseidon-solidity/` for transitive deps. Mirror the pattern used for `dodo-pmm-08`. Update `remappings.txt` accordingly.

---

## 4. Solidity version reconciliation

| Codebase | pragma | EVM |
|---|---|---|
| fx-Telaraña (us) | `0.8.26` | cancun |
| 0xbow vendor | `0.8.28` | cancun |
| Vendored Morpho | `0.8.19` strict | — |

**Action:** Bump vendored privacy-pools files to `pragma solidity ^0.8.26;` (drop the strict `0.8.28` pin). No language features used between 0.8.26 → 0.8.28 are incompatible. Foundry `auto_detect_solc = true` is already on, so multi-version builds work.

**Risk:** Verifiers (auto-gen) sometimes use very specific opcodes. We verify by compiling under 0.8.26 in a smoke build before merging slice 1.

---

## 5. fx-Telaraña-specific overrides (the "new" code)

### 5.1 `FxPrivacyPool` (extends `PrivacyPool`)

Overrides `_pull` and `_push` to plumb Morpho rehypothecation, mirroring the pattern already in `FxSwapHook.sol`:

```solidity
contract FxPrivacyPool is PrivacyPool {
    IFxMarketRegistry public immutable REGISTRY;
    IMorpho            public immutable MORPHO;
    address            public immutable COLLATERAL; // pair token for the Morpho market

    uint256 public hotReservePct; // default 20% — same pattern as FxSwapHook
    uint256 public supplyShares;  // our bookkeeping of Morpho shares

    function _pull(address sender, uint256 amount) internal override {
        IERC20(ASSET).safeTransferFrom(sender, address(this), amount);
        _rebalanceToMorpho(amount); // supply excess over hot target
    }

    function _push(address recipient, uint256 amount) internal override {
        _ensureHot(amount); // JIT-withdraw from Morpho if hot < amount
        IERC20(ASSET).safeTransfer(recipient, amount);
    }
}
```

### 5.2 Cross-currency shielded withdraw (slice 3)

Add a new entrypoint on `Entrypoint.sol`:

```solidity
function relayCrossCurrency(
    Withdrawal calldata _withdrawal,
    WithdrawProof calldata _proof,
    uint256 _scope,
    address _outputAsset,
    bytes calldata _routerData
) external nonReentrant;
```

Flow:
1. Run normal `withdraw()` to `address(this)` (Entrypoint as processooor).
2. If `_outputAsset == pool.ASSET()` → transfer to recipient (same as existing `relay`).
3. Else: route the FX leg through `FxSwapHook.swap()` (internal LP, DODO PMM with `maxDriftBps` spread cap).
4. If FxSwapHook reverts on slippage → fallback to Uniswap V4 `PoolManager.swap()` using `_routerData`-encoded PoolKey.
5. Transfer output asset to `_data.recipient`.

**Privacy leakage:** FX rate is observable on-chain → bound by existing `FxSwapHook.maxDriftBps` envelope. Document this trade-off in the user-facing SDK warning.

### 5.3 Testnet ASP-postman (slice 4)

Off-chain Bun service in `packages/relayer-privacy/`:
- Watches `Deposited` events on `Entrypoint`.
- Maintains an in-memory Merkle tree of every label seen.
- On each new deposit (or every N seconds), calls `Entrypoint.updateRoot(root, ipfsCID)` as `_ASP_POSTMAN`.
- IPFS CID can be a stub (just needs to be 32–64 bytes per `InvalidIPFSCIDLength` check).

**No screening.** Every label is in the approved set. Mainnet would swap in a real ASP (Chainalysis Reactor, TRM, etc.) — interface unchanged.

---

## 6. FxHub integration surfaces

```
┌───────────────────────────────────────────────────────────────────┐
│                       FxPrivacyEntrypoint                         │
│  (UUPS + AccessControl, vendored from 0xbow Entrypoint.sol)       │
│   deposit(asset, value, precommitment)                            │
│   relay(withdrawal, proof, scope)                                 │
│   relayCrossCurrency(...)         ←─── slice 3                    │
│   updateRoot(root, ipfsCID)        ←─── ASP postman               │
└──────────────────────────┬────────────────────────────────────────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
    ┌───────▼──────┐ ┌─────▼──────┐ ┌────▼──────┐
    │ FxPrivacyPool│ │FxPrivacyPool│ │FxPrivacyPool│
    │    (USDC)    │ │   (EURC)    │ │   (GBPC)   │
    └───────┬──────┘ └─────┬───────┘ └────┬───────┘
            │              │              │
            ▼              ▼              ▼
   ┌──────────────────────────────────────────────┐
   │           IFxMarketRegistry                  │
   │   (existing) — provides Morpho MarketParams  │
   └──────────┬───────────────────────────────────┘
              │ supply / withdraw
              ▼
       ┌──────────────┐
       │  Morpho Blue │
       └──────────────┘

For cross-ccy withdraw (slice 3):
   FxPrivacyEntrypoint → FxSwapHook (DODO PMM)
                       ↓ fallback
                       Uniswap V4 PoolManager
```

**Touchpoints in existing code:**
- `IFxMarketRegistry` — read-only (`paramsOf`) — no changes needed.
- `FxSwapHook` — new view `quote()` already exists; we just call `swap()`. **No changes needed.**
- `FxOracle` — used for sanity-checking cross-ccy slippage. Read-only.
- `FxHubMessageReceiver` — not touched. Privacy pools are local-only (no cross-chain shielded transfers in v1).

---

## 7. Slicing (each = one branch / one worktree)

### Slice 1 — vendor + USDC pool deposit/withdraw

**Branch:** `feat/privacy-hook-slice-1-vendor`
**Effort:** ~2 days
**Done when:**
- `contracts/lib/privacy-pools/`, `contracts/lib/lean-imt/`, `contracts/lib/poseidon-solidity/` vendored
- `contracts/src/hub/FxPrivacyPool.sol` (USDC-only) compiles
- `FxPrivacyEntrypoint.sol` deployed via UUPS proxy
- `scripts/check-eip170.ts` updated with new contracts (no overflow)
- Foundry tests: deposit, withdraw with valid proof, ragequit, nullifier double-spend revert, unknown root revert
- All 286 existing contract tests still green

### Slice 2 — Morpho yield path

**Branch:** `feat/privacy-hook-slice-2-morpho`
**Effort:** ~1 day
**Done when:**
- `_pull` / `_push` overridden to plumb Morpho supply/withdraw
- `hotReservePct` tunable by owner
- Fork test against ETH mainnet (or Fuji testnet Morpho) verifying supply accrual
- LP redeem (withdraw) always solvent even when 80% in Morpho

### Slice 3 — cross-currency shielded swap

**Branch:** `feat/privacy-hook-slice-3-crossccy`
**Effort:** ~3 days
**Done when:**
- `Entrypoint.relayCrossCurrency` exists, gated by `FxSwapHook.maxDriftBps`
- Uniswap V4 fallback adapter (`contracts/src/hub/UniV4Router.sol`)
- Tests: USDC→EURC shielded swap via FxSwapHook
- Tests: same swap with FxSwapHook insufficient → Uniswap fallback
- Tests: revert if both internal LP + Uniswap insufficient

### Slice 4 — SDK + permissive ASP postman

**Branch:** `feat/privacy-hook-slice-4-sdk`
**Effort:** ~3 days
**Done when:**
- TS SDK in `packages/sdk/src/privacy/` with commitment gen, proof gen (snarkjs WASM), withdrawal flow
- `packages/relayer-privacy/` Bun service: ASP-postman + relayer (no gas-swap)
- E2E test on Fuji testnet: deposit USDC → wait → withdraw EURC to fresh address via relayer

---

## 8. Risks & open questions

| Risk | Severity | Mitigation |
|---|---|---|
| ZK proof-gen WASM is 10–30s client-side | Med | Show progress UI in dApp; allow off-thread Web Worker |
| Anonymity-set size small on testnet | Low | Documentation; tune `vettingFeeBPS=0` to remove deposit friction |
| FX rate leaks for cross-ccy withdraw | Med | Bound by `maxDriftBps`; document in SDK |
| Uniswap V4 testnet liquidity ≈ 0 | Low | Acknowledge: testnet routes 100% through FxSwapHook |
| `auto_detect_solc` mixing 0.8.19 (Morpho) + 0.8.26 (us) + 0.8.28 (vendor) | Low | Already proven pattern; bump vendor to ^0.8.26 |
| 0xbow Entrypoint is UUPS; we'd add another UUPS contract to the hub | Low | Match existing FxTimelock pattern for upgrades |
| Mainnet regulatory hair (Tornado precedent) | **Hi** | **Testnet only**. Mainnet deploy requires real ASP partnership. |

---

## 9. What we are NOT doing in v1

- Cross-chain shielded transfers (FxHubMessageReceiver / CCTP integration). Single-chain only.
- Real ASP screening. Permissive testnet postman only.
- Native asset (ETH/AVAX) pools. ERC20 only.
- Ragequit UX in the SDK (slice 4 only does forward withdraw, not original-depositor rage-quit).
- Mainnet deployment. Period.

---

## 10. Vendor manifest (final shopping list for slice 1)

```
contracts/lib/privacy-pools/                    # NEW — Apache-2.0
├── Constants.sol
├── ProofLib.sol
├── DeployLib.sol
├── State.sol
├── PrivacyPool.sol
├── implementations/
│   └── PrivacyPoolComplex.sol                  (template for FxPrivacyPool)
├── verifiers/
│   ├── WithdrawalVerifier.sol
│   └── CommitmentVerifier.sol
└── interfaces/
    ├── IPrivacyPool.sol
    ├── IEntrypoint.sol
    ├── IVerifier.sol
    └── IState.sol

contracts/lib/lean-imt/                         # NEW — MIT
└── InternalLeanIMT.sol  +  LeanIMTData struct

contracts/lib/poseidon-solidity/                # NEW — MIT
└── PoseidonT4.sol  +  PoseidonT3.sol

contracts/src/hub/                              # MODIFY
├── FxPrivacyPool.sol                           NEW — extends PrivacyPool
└── FxPrivacyEntrypoint.sol                     NEW — extends Entrypoint (or fork)

packages/sdk/src/privacy/                       # NEW
├── (vendored from 0xbow sdk core + circuits)
└── index.ts

packages/relayer-privacy/                       # NEW (separate slice)
└── ...

contracts/foundry.toml                          # MODIFY — add remappings
contracts/remappings.txt                        # MODIFY — add remappings
scripts/check-eip170.ts                         # MODIFY — add FxPrivacyPool, FxPrivacyEntrypoint
```

---

## 11. Sign-off question

This SPEC says:
1. Vendor 0xbow privacy-pools-core wholesale (Apache-2.0, 4 audits).
2. Reuse PSE trusted-setup artifacts (`.zkey` files).
3. Override `_pull`/`_push` for Morpho yield via existing `IFxMarketRegistry`.
4. Cross-currency withdraw routes through existing FxSwapHook + Uniswap V4 fallback.
5. Permissive ASP postman bot for testnet; mainnet swaps in a real ASP later.
6. Four slices, ~9 days total.

**Slice 1 (vendor + USDC deposit/withdraw) is the natural starting point.** Confirm and I'll cut the branch.

Sources:
- [0xbow/privacy-pools-core](https://github.com/0xbow-io/privacy-pools-core)
- [Privacy Pools paper (Buterin, Illum, Nadler, Schär, Soleimani, 2023)](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4563364)
- Audit reports: `audit/contracts_audit_oxorio.md`, `audit/contracts_audit_auditware.md`, `audit/circuits_audit_oxorio.md`, `audit/entrypoint_upgrade_audit_oxorio.md` (in vendored repo)
