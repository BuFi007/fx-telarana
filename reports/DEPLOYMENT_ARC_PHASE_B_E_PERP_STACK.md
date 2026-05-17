# Arc Phase B-E Perp Stack Deployment

Date: 2026-05-17  
Chain: Arc testnet  
Chain ID: 5042002  
RPC used: `https://rpc.testnet.arc.network`  
Deployer/admin/keeper: `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`

## Addresses

| Contract | Address |
| --- | --- |
| `FxPerpClearinghouse` | `0x25cDf2ad4Fd446e85273c4D7C77a03F22C742865` |
| `FxMarginAccount` | `0x1869D0253286dF29ce0AB8d29207772C7fD9dc35` |
| `FxFundingEngine` | `0x725822e8BC6edbcBa52914149e25f2671290C6D2` |
| `FxHealthChecker` | `0x9cc0D71e2Af1532e74C2Af8aE7248ACB501039d5` |
| `FxLiquidationEngine` | `0x01f71c1E74350633bBC9d554ca35DA40412DCFB7` |
| `FxOrderSettlement` | `0x49ad97Fa2b67252373f4683bD4a4B49AA3AF5565` |

## Backend Env

```json
{"5042002":{"FxPerpClearinghouse":"0x25cDf2ad4Fd446e85273c4D7C77a03F22C742865","FxMarginAccount":"0x1869D0253286dF29ce0AB8d29207772C7fD9dc35","FxFundingEngine":"0x725822e8BC6edbcBa52914149e25f2671290C6D2","FxHealthChecker":"0x9cc0D71e2Af1532e74C2Af8aE7248ACB501039d5","FxLiquidationEngine":"0x01f71c1E74350633bBC9d554ca35DA40412DCFB7","FxOrderSettlement":"0x49ad97Fa2b67252373f4683bD4a4B49AA3AF5565"}}
```

## Broadcast Transactions

| Step | Tx |
| --- | --- |
| Deploy `FxMarginAccount` | `0x5a38161747974ed22a4b23ad32e56da0a35e9a1df5f1b652a82bd8db562fe6ee` |
| Deploy `FxPerpClearinghouse` | `0x8fb157fbf57bbc92ab8b56ef688dd05ab16b04e3538e813457e9daae12f0b4da` |
| Deploy `FxFundingEngine` | `0x94084a0da88d8d69356a9a9d3d968643de84a309e5fe1cd3a22e7f2f72083945` |
| Deploy `FxHealthChecker` | `0x9a66eedc65f132d916a441c3f6b5c223a9c45636c44822070a807320a1841e0c` |
| Deploy `FxLiquidationEngine` | `0x289e6454fce8b9de6425aa791c3e8eaff023e3c35fff3db8675fb7ae9eee4048` |
| Deploy `FxOrderSettlement` | `0x5ee894682c161360cdd158b465cfb44586fa2a26206e49ff482c14e6a6f9bdb6` |

Role-grant transactions are recorded in
`contracts/broadcast/DeployFxPerpStack.s.sol/5042002/run-latest.json`.
Sensitive local cache output remains uncommitted.

## Verification

Broadcast output: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`.

Post-broadcast `cast` checks confirmed:

- all six addresses have nonzero bytecode;
- `FxMarginAccount.USDC()` is `0x3600000000000000000000000000000000000000`;
- `FxMarginAccount.MARGIN_DECIMALS()` is `6`;
- `FxPerpClearinghouse.ORACLE()` is `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865`;
- `FxPerpClearinghouse.marginAccount()` is `0x1869D0253286dF29ce0AB8d29207772C7fD9dc35`;
- margin `CLEARINGHOUSE_ROLE` is granted to clearinghouse, funding, and liquidation;
- margin `ACCOUNT_OPERATOR_ROLE` is granted to keeper;
- clearinghouse `ORDER_SETTLEMENT_ROLE` is granted to settlement;
- clearinghouse `LIQUIDATION_ENGINE_ROLE` is granted to liquidation;
- clearinghouse `EXECUTOR_ROLE` is granted to keeper;
- settlement `SETTLER_ROLE` is granted to keeper.

## Not Configured

No market, funding, liquidation, or protocol liquidity seed parameters were
configured in this deployment. Those remain explicit admin transactions before
any live perps smoke.

