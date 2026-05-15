# Ghost Mode privacy hooks

**Status:** V1 spoke-level and withdrawal scaffolding implemented. Production
ZK verifier and audited Ghost liquidity remain future work.
**Decision:** Ghost Mode uses Bufi Wallet KYC/KYB passes plus privacy
hooks/routers. It does not require a third-party privacy wallet or Circle
Wallet.

## Why this exists

The public fx-Telarana rail stays permissionless. Ghost Mode is a separate route
for verified Bufi Wallet users who want slower, privacy-preserving execution for
deposits, withdrawals, swaps, and cross-chain entry.

Circle remains in the stack only as:
- USDC/EURC issuer,
- CCTP V2 transport for USDC/EURC,
- optional contract/event monitoring infrastructure.

Bufi Wallet owns the user experience and KYC/KYB pass.

## Reference hook lessons

The blackbera privacy-hook concept points in the right direction:
commitments, Merkle roots, nullifiers, and proofs can break the public link
between deposit and withdrawal addresses.

The common KYC hook pattern is useful only as a negative example when it checks
`tx.origin`. A production v4 hook must not use `tx.origin`. In Uniswap v4:
- `msg.sender` is the PoolManager,
- the hook `sender` argument is usually the router,
- real user/pass identity must come from a trusted router, signed hook data, or a
  separate verifier.

## Required primitives

| Primitive | Responsibility |
|---|---|
| `IBufiKycPass` | Minimal verifier for a Bufi Wallet's valid KYC/KYB pass. |
| `FxGhostRouter` | User-facing route executor for Ghost actions. |
| `FxGhostCommitmentRegistry` | Merkle root/nullifier tracking. |
| `FxGhostSwapHook` | v4 hook for Ghost pools; combines PMM pricing, router allowlist, pass checks, and proof/nullifier checks. |
| `FxGhostWithdrawalRouter` | Verifies withdrawal proofs and consumes nullifiers before sending funds. |

Minimal verifier shape:

```solidity
interface IBufiKycPass {
    function hasValidPass(address account) external view returns (bool);
    function passLevel(address account) external view returns (uint8);
}
```

`passLevel` should distinguish at least KYC individual and KYB entity. The final
contract can expose richer data, but protocol contracts should depend on the
smallest possible interface.

## Design constraints

- A Uniswap v4 pool has exactly one hook address. Ghost behavior cannot be
  "stacked" onto the public `FxSwapHook` by adding a second hook.
- Public and Ghost pools should be separate if the Ghost pool needs proof checks
  inside swap execution.
- Gateway remains USDC-only in the current design. CCTP remains scoped to
  Circle-supported USDC/EURC routes. Hyperlane and approved issuer-specific
  routes handle other stablecoin transport and intent messages.
- Permissionless Hyperlane routes are not automatically accepted collateral.
- Ghost deposits and withdrawals must use nullifiers to prevent replay.
- Root updates and verifier-key updates must be timelocked.
- Ghost Mode v1 privacy is route/account unlinkability. It does not hide Morpho
  liquidation state unless the position itself is held behind the Ghost account
  abstraction or a future shielded accounting layer.

## Current implementation

Implemented in this branch:

1. `FxGhostSpokeRouter` wraps `FxSpoke.enterHub(...)` for Circle-only
   USDC/EURC routes. It requires `IBufiKycPass.hasValidPass(account)` and a
   route minimum pass level, records an explicit commitment, and always forwards
   an explicit `beneficiary`.
2. `FxGhostCommitmentRegistry` stores commitments, consumed nullifiers, and
   admin-set root metadata for future verifier integration.
3. `FxGhostWithdrawalRouter` verifies a mockable withdrawal proof, validates
   active root metadata, consumes the nullifier, checks the Bufi pass level, and
   pays out tokens already held by the route.
4. `FxGhostKycHook` is a minimal future v4 hook gate. It accepts only
   PoolManager callbacks, trusts only configured routers, takes user identity
   from hook data, and enables no custom swap deltas in v1.
5. SDK ABIs, Ghost entry/withdrawal request types, and indexer event schema are exported
   from `@bu/fx-engine`.

RO-KYC, Persona, Goofy, and Paseo remain offchain. Solidity consumes only the
minimal onchain Bufi pass interface.

## Remaining implementation sequence

1. Add `/fx/eligibility/:wallet` support for Bufi Wallet KYC/KYB pass status.
2. Add `/fx/ghost/prepare` and `/fx/ghost/proof` routes.
3. Replace the mockable withdrawal verifier with audited proof verification and
   verifier-key governance.
4. Add `FxGhostSwapHook` only after public `FxSwapHook` dynamic fee/oracle
   updates are stable.
5. Add Hyperlane/CCTP Ghost entry after same-chain proof settlement works.
6. Audit before any production Ghost liquidity.

## Frontend contract

The UI should route through Ghost Mode only when all are true:

- connected wallet is Bufi Wallet,
- KYC/KYB pass is valid and not revoked,
- selected action has a deployed Ghost route,
- selected asset/pair is live in the hub registry,
- proof generation succeeds locally or through the approved prover service.

If any condition fails, show public mode as the fallback and explain the exact
eligibility reason from `@bu/fx-engine`.
