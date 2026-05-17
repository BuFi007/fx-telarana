# Fuji Phase B-E Perp Stack Deployment

Date: 2026-05-17  
Chain: Avalanche Fuji  
Chain ID: 43113  
Deployer/admin/keeper: `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`

## Addresses

| Contract | Address |
| --- | --- |
| `FxPerpClearinghouse` | `0x22013f712190034D8Ee43F3894461c27709E74AC` |
| `FxMarginAccount` | `0x21bB1Bb922b04CbCFD1AD7Bd6788F5251917acb2` |
| `FxFundingEngine` | `0x3a4459dBa18806e700423aAbEA1df1fefc928C6a` |
| `FxHealthChecker` | `0x7Ff02e5F618a051acad9BbF9b1295E423062BB56` |
| `FxLiquidationEngine` | `0xED58C176E9a37Cda2854AC0Ade409cfb3687cA7d` |
| `FxOrderSettlement` | `0x955AAEE698aaA03d5bc32F16434cef78b8Ee1fc7` |

## Backend Env

```json
{"43113":{"FxPerpClearinghouse":"0x22013f712190034D8Ee43F3894461c27709E74AC","FxMarginAccount":"0x21bB1Bb922b04CbCFD1AD7Bd6788F5251917acb2","FxFundingEngine":"0x3a4459dBa18806e700423aAbEA1df1fefc928C6a","FxHealthChecker":"0x7Ff02e5F618a051acad9BbF9b1295E423062BB56","FxLiquidationEngine":"0xED58C176E9a37Cda2854AC0Ade409cfb3687cA7d","FxOrderSettlement":"0x955AAEE698aaA03d5bc32F16434cef78b8Ee1fc7"}}
```

## Combined Backend Env

```json
{"5042002":{"FxPerpClearinghouse":"0x6A265045D9A3291D2881d77DDC62e2781A2418c5","FxMarginAccount":"0x35c7cD02cFa0c2889547482B71c1a5114d8439C6","FxFundingEngine":"0x88B70872759E1aA24858746779Cb15ca9F2cdcf3","FxHealthChecker":"0x272305e821D810eC5741761F98DbDC273efD47E6","FxLiquidationEngine":"0xD384560E5f8CE969BF4C1BDfAFACc5304AFbe8f2","FxOrderSettlement":"0x0F62FCdA2de63d905Cb167301C00251A9bB6dAa1"},"43113":{"FxPerpClearinghouse":"0x22013f712190034D8Ee43F3894461c27709E74AC","FxMarginAccount":"0x21bB1Bb922b04CbCFD1AD7Bd6788F5251917acb2","FxFundingEngine":"0x3a4459dBa18806e700423aAbEA1df1fefc928C6a","FxHealthChecker":"0x7Ff02e5F618a051acad9BbF9b1295E423062BB56","FxLiquidationEngine":"0xED58C176E9a37Cda2854AC0Ade409cfb3687cA7d","FxOrderSettlement":"0x955AAEE698aaA03d5bc32F16434cef78b8Ee1fc7"}}
```

## Broadcast Transactions

| Step | Tx |
| --- | --- |
| Deploy `FxMarginAccount` | `0xf0bba4e3060a67640da69b3e5764068c63ae185c0abf29bcc9c4475d44842a5f` |
| Deploy `FxPerpClearinghouse` | `0xa85738ba985cf542602dedbc89dd99388edb86368c6cf5fc6e95d4837ae9e88d` |
| Deploy `FxFundingEngine` | `0xe363387b7344f5355e770cd9778417c70ebf213e8094be35ec44a2a0bd87a2b6` |
| Deploy `FxHealthChecker` | `0x97db4436e0dbc80818f8add0f625d4962769f105503984fa91e184cbaf7bd7d3` |
| Deploy `FxLiquidationEngine` | `0x7129566a0a3f001fecfcc4f78d435fda7a74acc3fe37d2637b139e3df24fc11d` |
| Deploy `FxOrderSettlement` | `0xf8bfab95327bd2550c3e30dd43de5a5a8d3f4013a3da98f9734c23951672f455` |

Role-grant transactions are recorded in
`contracts/broadcast/DeployFxPerpStack.s.sol/43113/run-latest.json`.
Sensitive local cache output remains uncommitted.

## Verification

Broadcast output: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`.

Post-broadcast `cast` checks confirmed:

- all six addresses have nonzero bytecode;
- `FxMarginAccount.USDC()` is `0x5425890298aed601595a70AB815c96711a31Bc65`;
- `FxMarginAccount.MARGIN_DECIMALS()` is `6`;
- `FxPerpClearinghouse.ORACLE()` is `0xf7fcDCA3f9c92418A980A31df7f87De7E1a1a04b`;
- `FxPerpClearinghouse.marginAccount()` is `0x21bB1Bb922b04CbCFD1AD7Bd6788F5251917acb2`;
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
