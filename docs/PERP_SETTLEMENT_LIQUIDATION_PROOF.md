# Perp Settlement + Liquidation Proof

Status: on-chain boundaries proven locally; no live matcher service or broadcast was run.

## Settlement Verdict

The signed maker/taker order path is proven through a local matcher relay:

1. maker and taker deposit USDC margin
2. both sign `FxOrderSettlement.SignedOrder` EIP-712 payloads
3. `LocalMatcherRelay` forwards the matched orders into `FxOrderSettlement.settleMatch`
4. `FxOrderSettlement` verifies signatures, consumes nonces, and calls `FxPerpClearinghouse.applyOrderFill`
5. clearinghouse opens maker long and taker short positions

This proves the on-chain boundary that a matcher must call. It does not prove the external Rust matcher service, networking, queueing, or production gRPC path.

Focused test:

```bash
forge test --match-path test/perp/FxPerpStack.t.sol -vv
```

Result: 15 pass.

## Liquidation Verdict

The real `LiquidationRouter -> FxLiquidationEngine -> FxPerpClearinghouse` path is proven for a ready pre-flagged unhealthy account:

1. trader opens a leveraged long
2. oracle price moves against the trader
3. account is flagged through `FxLiquidationEngine.flagAccount`
4. the required 60-second delay elapses
5. `LiquidationRouter.liquidateAtomic` liquidates through the real engine stack
6. position closes, flag clears, and the router forwards the liquidation reward delta

The router cannot atomically flag and liquidate a fresh account when the production minimum flag delay is active. A fresh `liquidateAtomic` attempt correctly reverts with `FlagDelayPending`, and the flag write rolls back with the transaction.

Focused test:

```bash
forge test --match-path test/perp/LiquidationRouter.t.sol -vv
```

Result: 13 pass.

## Remaining Human/Infra Proof

The missing production proof is not Solidity. It is an infra canary: submit two signed orders through the live matcher service, verify the matcher emits a fill, then verify the resulting transaction reaches `FxOrderSettlement` and the positions are visible through MCP/UI. That should be run only with the approved testnet keeper and no mainnet funds.
