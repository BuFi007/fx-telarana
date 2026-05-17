# Gateman Analysis - Phase A T5 Receipt Parity

Date: 2026-05-17
Branch: `codex/phase-a-audit-ready-tier1`

## Scope

T5 hardens `TelaranaGatewayHubHook` so spot-FX receipt fields that were
previously keeper-supplied at `receiveGatewayMint` can be bound before the TGH
receipt is stored. The new route-level proof modes support:

- source-depositor signed EIP-712 intent;
- Hyperlane-delivered context hash from a configured mailbox/trusted sender;
- migration mode accepting either proof path.

The bound context hash covers `routeId`, `requestId`, `action`,
`sourceDepositor`, `sourceSigner`, `recipient`, `tokenOut`, `amount`,
`minAmountOut`, `spotRouteId`, and `metadataRef`. It intentionally excludes
`hookData`, because `hookData` is the proof container.

## Checks

- Assume nothing: default mode remains `NONE`, non-empty hook data is rejected
  there, and every active proof mode must satisfy a route-specific signature or
  a mailbox/trusted-sender hash proof before minting.
- Question everything: tests mutate `sourceSigner`, `spotRouteId`, and
  `metadataRef` after proof creation and assert the mutated context is rejected.
- Worship no one: EIP-712 hashing uses OZ `EIP712`; signature validation uses
  OZ `SignatureChecker` so EOAs and EIP-1271 source depositors are both
  supported.
- Applaud humility: Hyperlane support is present but disabled until operators
  configure `gatewayContextMailbox` and a trusted `(origin, sender)` pair.

## Evidence

- `forge test --root contracts --match-path test/TelaranaGatewayHubHook.t.sol -vv`:
  22 passed, 0 failed.
- `forge test --root contracts`: 254 passed, 0 failed, 1 existing skip.
- `forge build --root contracts --sizes`: compiled successfully.
  `TelaranaGatewayHubHook` is 16,476 bytes runtime, below the 24KB limit.
- Non-broadcast Arc deploy simulation:
  `forge script --root contracts contracts/script/DeployTelaranaGatewayHubHook.s.sol:DeployTelaranaGatewayHubHook --rpc-url https://rpc.testnet.arc.network`
  with Arc USDC and Circle GatewayMinter completed. Estimated gas: 4,830,160.

## Result

PASS. T5 contract support is ready for testnet deployment/configuration after
explicit user approval. No broadcast or live smoke was executed.
