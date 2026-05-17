// SPDX-License-Identifier: Apache-2.0
//
// fx-Telarana Privacy Hook SDK — slice 4.
//
// Vendored from 0xbow-io/privacy-pools-core (Apache-2.0) at audited commit
// (May 2026). See docs/PRIVACY_HOOK_SPEC.md and contracts/lib/privacy-pools/
// for the on-chain surface this SDK targets.
//
// Surface:
//   • Domain types (Commitment, Withdrawal, MasterKeys, ...)
//   • Crypto primitives (Poseidon master keys, commitment hash, merkle proofs,
//     keccak context hash for `PrivacyPool.validWithdrawal`)
//   • Cross-currency relay encoder (slice 3 — fx-Telarana addition)
//   • Groth16 circuit loader + WithdrawalService prover
//
// What this SDK does NOT yet ship:
//   • Bundled `.zkey` / `.wasm` artifacts — use UrlCircuits with a CDN
//   • account/data/commitment services — those wrap viem contract calls and
//     land in slice 4b
//   • Ragequit UX — deferred per HANDOFF_PRIVACY_HOOK.md NOT-doing list

export * from "./constants.js";
export * from "./types.js";
export * from "./exceptions.js";
export * from "./crypto.js";
export * from "./circuits.js";
export * from "./withdrawal.js";
export * from "./crossCurrency.js";
