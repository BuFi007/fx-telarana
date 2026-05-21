# Gateman Analysis - Phase A T1 Vendored References

Date: 2026-05-17
Branch: `codex/phase-a-audit-ready-tier1`

## Scope

T1 vendors the Phase A reference repositories into `contracts/lib/` and adds
an auditor-facing map at `docs/VENDORED_REFERENCE_REPOS.md`. It also updates
`FxSpotExecutor` NatSpec citations so the existing pricing and future v4-hook
references point at vendored paths.

## Checks

- Assume nothing: confirmed each new reference is a pinned git submodule entry
  in `.gitmodules` plus a gitlink under `contracts/lib/`.
- Question everything: searched production, script, test, docs, and remappings
  for the new reference names. No remappings or production imports were added;
  the repositories are references only.
- Worship no one: verified the exact pinned reference SHAs with
  `git submodule status`, rather than relying on repository names.
- Applaud humility: kept this patch documentation/reference-only. No runtime
  logic, deployment, or live testnet state changed.

## Evidence

- `forge test --root contracts`: 240 passed, 0 failed, 1 existing skip.
- `forge test --root contracts --match-contract FxSpotExecutorTest`: 24 passed.
- `forge build --root contracts --sizes`: compiled successfully. Notable
  runtime sizes remain below 24KB, including `FxSpotExecutor` at 8,536 bytes
  and `FxSwapHook` at 22,082 bytes.
- Existing Forge lint warnings are unchanged and outside this patch surface.

## Result

PASS. T1 closes the in-repo reference availability gap without changing
runtime behavior. No deployment or live smoke is required for this patch.

