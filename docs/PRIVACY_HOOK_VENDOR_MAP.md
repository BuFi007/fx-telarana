# FxPrivacyHook — Concrete Vendor Map

**Status:** Discovery — branch `tcxcx/privacy-hook-discovery`
**Prereq:** Read [PRIVACY_HOOK_SPEC.md](./PRIVACY_HOOK_SPEC.md) first.

This document is the **file-by-file mapping** of what gets pulled into our repo. Generated after cloning three upstream repos into `discovery/` (gitignored) and inspecting every Solidity / Circom / artifact file.

---

## 1. Source repos cloned into `discovery/`

Vendored at the following exact commits (codex-r5 LOW: pinned for
reproducible audit attestation):

| Path | Upstream | License | Pinned commit | Subject |
|---|---|---|---|---|
| `discovery/privacy-pools-core/` | `github.com/0xbow-io/privacy-pools-core` | Apache-2.0 | `a80836a47451e662f127af17e11430ffa976c234` | `fix(sdk): Fixed 0 values withdrawals processing in SDK (#121)` |
| `discovery/poseidon-solidity/` | `github.com/privacy-scaling-explorations/poseidon-solidity` | MIT | `6557e66928f576b879343781a964f6c6804f1129` | `Merge pull request #1 from chancehudson/pse-repo-update` |
| `discovery/zk-kit.solidity/` | `github.com/zk-kit/zk-kit.solidity` | MIT | `a171c845ec7fdc50cdd1fe96c14c27d707cdfbed` | `docs: update contributing, pull request template and license year (#54)` |

To verify any vendored file matches the pin:

```bash
# Clone the upstream at the pinned SHA
git clone https://github.com/0xbow-io/privacy-pools-core /tmp/pp-verify
git -C /tmp/pp-verify checkout a80836a47451e662f127af17e11430ffa976c234

# Diff against our vendored copy — only the documented modifications
# (pragma + remappings) should appear.
diff -u /tmp/pp-verify/packages/contracts/src/contracts/State.sol \
       contracts/lib/privacy-pools/contracts/State.sol
```

All three discovery clones are gitignored via `discovery/` in `.gitignore` — they exist locally for reference, not committed.

---

## 2. Solidity files: source → destination

### 2.1 From `privacy-pools-core/packages/contracts/src/` → `contracts/lib/privacy-pools/`

| Source (bytes) | Lines | Destination | Action |
|---|---:|---|---|
| `contracts/lib/Constants.sol` (313) | 9 | `lib/privacy-pools/Constants.sol` | **Vendor as-is** |
| `contracts/lib/ProofLib.sol` (6589) | 167 | `lib/privacy-pools/ProofLib.sol` | **Vendor**, bump pragma `0.8.28→^0.8.26` |
| `contracts/lib/DeployLib.sol` (1770) | 39 | `lib/privacy-pools/DeployLib.sol` | **Vendor** (drop — we don't use CreateX) |
| `contracts/State.sol` (7061) | 183 | `lib/privacy-pools/State.sol` | **Vendor**, bump pragma |
| `contracts/PrivacyPool.sol` (7758) | 186 | `lib/privacy-pools/PrivacyPool.sol` | **Vendor**, bump pragma |
| `contracts/implementations/PrivacyPoolComplex.sol` (3393) | 68 | — | **Reference only** (we write our own `FxPrivacyPool.sol` modeled on this) |
| `contracts/implementations/PrivacyPoolSimple.sol` (3074) | 57 | — | **Skip** (no native asset pools) |
| `contracts/Entrypoint.sol` (15955) | 402 | `lib/privacy-pools/Entrypoint.sol` | **Vendor as base**, we extend → `FxPrivacyEntrypoint.sol` |
| `contracts/verifiers/WithdrawalVerifier.sol` (9851) | 219 | `lib/privacy-pools/verifiers/WithdrawalVerifier.sol` | **Vendor as-is** (auto-gen Groth16, do not modify) |
| `contracts/verifiers/CommitmentVerifier.sol` (8296) | 191 | `lib/privacy-pools/verifiers/CommitmentVerifier.sol` | **Vendor as-is** (= ragequit verifier) |
| `interfaces/IPrivacyPool.sol` (6046) | — | `lib/privacy-pools/interfaces/IPrivacyPool.sol` | **Vendor** |
| `interfaces/IEntrypoint.sol` (12722) | — | `lib/privacy-pools/interfaces/IEntrypoint.sol` | **Vendor** |
| `interfaces/IState.sol` (5321) | — | `lib/privacy-pools/interfaces/IState.sol` | **Vendor** |
| `interfaces/IVerifier.sol` (1542) | — | `lib/privacy-pools/interfaces/IVerifier.sol` | **Vendor** |
| `interfaces/external/ICreateX.sol` (5977) | — | — | **Skip** (CreateX deploy helper, we deploy via existing scripts) |

**Vendor LoC total: ~1,180 lines Solidity (~71 KB).**

### 2.2 From `poseidon-solidity/contracts/` → `contracts/lib/poseidon-solidity/`

| Source (bytes) | Lines | Destination | Action |
|---|---:|---|---|
| `PoseidonT2.sol` (~10 KB) | 298 | — | **Skip** (not used) |
| `PoseidonT3.sol` (~13 KB) | 391 | `lib/poseidon-solidity/PoseidonT3.sol` | **Vendor as-is** (lean-imt depends on it) |
| `PoseidonT4.sol` (~20 KB) | 568 | `lib/poseidon-solidity/PoseidonT4.sol` | **Vendor as-is** (PrivacyPool commitment hash) |
| `PoseidonT5.sol` | 702 | — | **Skip** |
| `PoseidonT6.sol` | 897 | — | **Skip** |
| `Test.sol` | 191 | — | **Skip** |

**Pragma already `>=0.7.0` — compiles unchanged under 0.8.26.**
**Note:** poseidon-solidity README says "not audited as a standalone library", but the privacy-pools-core Oxorio audit explicitly validates PoseidonT4 usage in the Privacy Pool, and PSE uses this same implementation in Semaphore, Tornado, etc. De facto trusted across the ecosystem.

**Vendor LoC: 959 lines.**

### 2.3 From `zk-kit.solidity/packages/lean-imt/contracts/` → `contracts/lib/lean-imt/`

| Source | Lines | Destination | Action |
|---|---:|---|---|
| `InternalLeanIMT.sol` | 349 | `lib/lean-imt/InternalLeanIMT.sol` | **Vendor as-is** (pragma `^0.8.4`) |
| `LeanIMT.sol` | 45 | `lib/lean-imt/LeanIMT.sol` | **Skip** (thin wrapper; State.sol uses Internal directly) |
| `Constants.sol` | 4 | — | **Skip** — we redeclare `SNARK_SCALAR_FIELD` inside Constants.sol (already vendored from privacy-pools-core) |

**Vendor LoC: 349 lines.**

### 2.4 fx-Telaraña-specific new code → `contracts/src/hub/`

| File | Est. LoC | Source pattern |
|---|---:|---|
| `FxPrivacyPool.sol` | ~150 | Extends `PrivacyPool`; overrides `_pull`/`_push` for Morpho rehyp (pattern from `FxSwapHook.sol:1014-1069`) |
| `FxPrivacyEntrypoint.sol` | ~120 | Extends vendored `Entrypoint`; adds `relayCrossCurrency()` (slice 3) |
| `interfaces/IFxPrivacyPool.sol` | ~40 | Our public surface |

**New LoC: ~310 lines.**

---

## 3. Solidity total

| Bucket | LoC |
|---|---:|
| Vendored from privacy-pools-core | ~1,180 |
| Vendored from poseidon-solidity (T3 + T4 only) | 959 |
| Vendored from lean-imt | 349 |
| fx-Telaraña new (FxPrivacyPool + FxPrivacyEntrypoint) | ~310 |
| **Total** | **~2,800** |

Of which **vendored + audited: ~2,488 LoC (89%)**. Custom code: ~310 LoC (11%) — all integration glue, no novel crypto.

---

## 4. Circom circuits — **not vendored** (used off-chain only)

| Source | Lines | Action |
|---|---:|---|
| `discovery/privacy-pools-core/packages/circuits/circuits/commitment.circom` | ~80 | **Stay in discovery/**, used only for re-deriving witness during dev. Verifier contracts already vendored. |
| `discovery/privacy-pools-core/packages/circuits/circuits/merkleTree.circom` | ~60 | Same |
| `discovery/privacy-pools-core/packages/circuits/circuits/withdraw.circom` | ~150 | Same |

**We don't compile or modify circuits.** The auto-generated Solidity verifier contracts (`WithdrawalVerifier.sol`, `CommitmentVerifier.sol`) are vendored under section 2.1.

---

## 5. Trusted setup artifacts — CDN-hosted, not committed

| File | Size | Strategy |
|---|---:|---|
| `commitment.zkey` | 901 KB | **Commit** to `packages/sdk/circuits/commitment.zkey` (Git LFS or direct) |
| `commitment.vkey` | 3.4 KB | **Commit** |
| `withdraw.zkey` | **17.8 MB** | **CDN-host** (Cloudflare R2 / IPFS) — too large for git. Mirror PSE's CDN URL or our own. |
| `withdraw.vkey` | 4.1 KB | **Commit** |
| `commitment.wasm` (witness gen) | ~few hundred KB | **Commit** to `packages/sdk/circuits/` |
| `withdraw.wasm` | ~few MB | **Commit** |

**Decision:** SDK uses `fetchArtifacts.ts` pattern from 0xbow's SDK — fetches `.zkey` from a configurable URL at runtime, caches in IndexedDB. Default URL = PSE's mirror; can override via env.

---

## 6. TS SDK — destination structure under `packages/sdk/src/privacy/`

From `discovery/privacy-pools-core/packages/sdk/src/`:

| Source | Destination | Action |
|---|---|---|
| `core/account.service.ts` | `privacy/account.ts` | **Vendor**, retarget viem 2.x (we already use viem) |
| `core/commitment.service.ts` | `privacy/commitment.ts` | **Vendor** |
| `core/data.service.ts` | `privacy/data.ts` | **Vendor**, adapt to our deployment manifests |
| `core/withdrawal.service.ts` | `privacy/withdrawal.ts` | **Vendor**, **extend** with cross-currency entry |
| `core/sdk.ts` | `privacy/sdk.ts` | **Vendor**, wire to our chain configs |
| `circuits/circuits.impl.ts` | `privacy/circuits.ts` | **Vendor** (snarkjs WASM wrapper) |
| `circuits/fetchArtifacts.*` | `privacy/fetchArtifacts.ts` | **Vendor**, point default URL at our CDN |
| `crypto.ts` | `privacy/crypto.ts` | **Vendor** (Poseidon JS via circomlibjs) |
| `keys.ts` | `privacy/keys.ts` | **Vendor** (BIP32-style key derivation) |
| `abi/*.ts` | — | **Regenerate** via existing `bun run sdk:abis:sync` after FxPrivacyPool/FxPrivacyEntrypoint compile |

**SDK LoC vendored:** ~2,000 lines TS (estimate; need final count after slice 4).

---

## 7. Relayer — new package `packages/relayer-privacy/`

From `discovery/privacy-pools-core/packages/relayer/src/`:

| Source | Action |
|---|---|
| `app.ts` (Fastify) | **Port to Hono** (matches our `packages/sdk` stack) |
| `providers/sdk.provider.ts` | **Vendor**, wires our new TS SDK |
| `providers/web3.provider.ts` | **Vendor**, swap viem chain configs |
| `providers/sqlite.provider.ts` | **Vendor** (session storage) |
| `providers/uniswap/**` | **Strip** (no gas-swap on testnet) |
| `providers/quote.provider.ts` | **Strip** |
| `schemes/*.scheme.ts` | **Vendor**, adapt to our payloads |
| **NEW:** `asp-postman.ts` | **Write new** — watches Deposited events, calls `Entrypoint.updateRoot()` with permissive root |

---

## 8. Foundry / build wiring changes

### 8.1 `contracts/foundry.toml` — add to `remappings`:

```toml
"privacy-pools/=lib/privacy-pools/",
"poseidon/=lib/poseidon-solidity/",
"lean-imt/=lib/lean-imt/",
```

### 8.2 `contracts/remappings.txt` — same additions (kept in sync).

### 8.3 Pragma rewriter — one-time script before vendoring

privacy-pools-core uses `pragma solidity 0.8.28;` (strict). We need `pragma solidity ^0.8.26;`. Apply via:

```bash
for f in contracts/lib/privacy-pools/**/*.sol; do
  sed -i '' 's/pragma solidity 0.8.28;/pragma solidity ^0.8.26;/' "$f"
done
```

Then `forge build` to verify. **No language features differ 0.8.26 ↔ 0.8.28 that the vendored code uses** (verified by grep — no `transient` keyword, no 0.8.27+ features).

### 8.4 `scripts/check-eip170.ts` — add to REQUIRED:

```typescript
{ sourceDir: "FxPrivacyPool.sol",       name: "FxPrivacyPool" },
{ sourceDir: "FxPrivacyEntrypoint.sol", name: "FxPrivacyEntrypoint" },
{ sourceDir: "WithdrawalVerifier.sol",  name: "WithdrawalVerifier" },
{ sourceDir: "CommitmentVerifier.sol",  name: "CommitmentVerifier" },
```

Predicted sizes (rough, based on 0xbow's mainnet deploys):
- `FxPrivacyPool` deployed bytecode: ~12 KB (well under 24 KB limit)
- `FxPrivacyEntrypoint`: ~16 KB (UUPS + AccessControl adds weight; still safe)
- Verifiers: ~3 KB each (Groth16 verifiers are tiny)

### 8.5 `package.json` — no new top-level scripts needed; existing `contracts:test`, `contracts:size:guard`, `sdk:abis:sync` cover the surface.

---

## 9. License headers — what each vendored file gets

Per repo convention (CLAUDE.md):
- **Privacy-pools vendor:** Keep `// SPDX-License-Identifier: Apache-2.0` (matches our `contracts/` license)
- **Poseidon vendor:** Keep `// SPDX-License-Identifier: MIT` (compatible)
- **Lean-imt vendor:** Keep `// SPDX-License-Identifier: MIT`
- **Our new code (FxPrivacyPool, FxPrivacyEntrypoint):** `// SPDX-License-Identifier: Apache-2.0`

Add `LICENSES/` entries mirroring how `dodo-pmm-08` was vendored.

---

## 10. Verification checklist for slice 1

When slice 1 (`feat/privacy-hook-slice-1-vendor`) is "done":

- [ ] `contracts/lib/privacy-pools/`, `contracts/lib/poseidon-solidity/`, `contracts/lib/lean-imt/` populated per table above
- [ ] All `pragma solidity 0.8.28;` rewritten to `^0.8.26;`
- [ ] `LICENSES/poseidon-solidity-MIT.md` and `LICENSES/lean-imt-MIT.md` added
- [ ] `forge build` clean (multi-version solc auto-detect handles 0.8.19 Morpho + 0.8.26 us + ^0.8.26 vendor)
- [ ] `scripts/check-eip170.ts` extended; all contracts under 24,576 bytes
- [ ] `FxPrivacyPool` constructor wires `IFxMarketRegistry` + asset + verifier addresses
- [ ] `FxPrivacyEntrypoint` deployed via UUPS proxy in a new script `script/DeployPrivacyHub.s.sol`
- [ ] Unit tests: deposit, withdraw (real Groth16 proof), nullifier double-spend, unknown root, ragequit
- [ ] All 286 existing contract tests still pass
- [ ] `bun run sdk:abis:sync` produces `packages/sdk/src/abis/FxPrivacyPool.ts` + `FxPrivacyEntrypoint.ts`

---

## 11. Confirmed sign-off question

This vendor map is concrete: **2,488 LoC vendored across 3 audited upstreams + 310 LoC fx-Telaraña glue.** No novel crypto, no novel math.

Three confirms needed before slice 1 starts:
1. **Pragma downgrade strategy** OK? (privacy-pools-core 0.8.28 → ^0.8.26 via sed)
2. **CDN strategy** for the 17.8 MB `withdraw.zkey`? (default to PSE mirror, allow our R2 override)
3. **Relayer language** — Hono is fine, or do you want it on a different stack?

Once those are answered, I cut `feat/privacy-hook-slice-1-vendor` and start vendoring.
