// SPDX-License-Identifier: Apache-2.0
//
// fx-Telarana Privacy Hook SDK — Apache-2.0 surface.
//
// Vendored from 0xbow-io/privacy-pools-core (Apache-2.0) at audited commit
// a80836a4 (May 2026). See docs/PRIVACY_HOOK_SPEC.md and
// contracts/lib/privacy-pools/ for the on-chain surface.
//
// Surface (Apache-2.0):
//   • Domain types (Commitment, Withdrawal, MasterKeys, WithdrawalProofInput,
//     CrossCurrencyRelayData, ...)
//   • Crypto primitives (Poseidon master keys, commitment hash, merkle
//     proofs, keccak context hash for `PrivacyPool.validWithdrawal`)
//   • Circuit-artifact loader interface (UrlCircuits — fetches .wasm/.zkey
//     from any CDN; no snarkjs dependency)
//   • Cross-currency relay encode/decode (fx-Telarana addition)
//   • PrivacyTradeClient — integrator facade with bundled chain configs.
//     Closes shield / relay / cross-currency loops to 3 method calls.
//     Apache-clean; accepts an injected IWithdrawalProver so consumers
//     wire @bu/privacy-prover (GPL) themselves without contaminating
//     this SDK's license posture.
//
// What this SDK INTENTIONALLY does NOT ship (codex-r8 HIGH):
//   • The Groth16 prover — `WithdrawalService` lives in `@bu/privacy-prover`
//     (GPL-3.0) because snarkjs is GPL-3.0. Keeping that out of this Apache
//     package preserves the public SDK's license posture.
//   • Bundled `.zkey` / `.wasm` artifacts — consumers wire UrlCircuits with
//     a CDN URL.
//   • account/data/commitment services — slice 4b (viem wrappers).
//   • Ragequit UX — deferred per HANDOFF_PRIVACY_HOOK.md NOT-doing list.

export * from "./constants.js";
export * from "./types.js";
export * from "./exceptions.js";
export * from "./crypto.js";
export * from "./circuits.js";
export * from "./crossCurrency.js";
export * from "./services/index.js";
