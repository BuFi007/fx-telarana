# Arc Phase B-E Perp Stack Deployment

Date: 2026-05-17

Network: Arc testnet, chainId `5042002`

RPC used: `https://rpc.testnet.arc.network`

Deployer/admin/keeper: `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`

## Addresses

| Contract | Address |
| --- | --- |
| `FxPerpClearinghouse` | `0x6A265045D9A3291D2881d77DDC62e2781A2418c5` |
| `FxMarginAccount` | `0x35c7cD02cFa0c2889547482B71c1a5114d8439C6` |
| `FxFundingEngine` | `0x88B70872759E1aA24858746779Cb15ca9F2cdcf3` |
| `FxHealthChecker` | `0x272305e821D810eC5741761F98DbDC273efD47E6` |
| `FxLiquidationEngine` | `0xD384560E5f8CE969BF4C1BDfAFACc5304AFbe8f2` |
| `FxOrderSettlement` | `0x0F62FCdA2de63d905Cb167301C00251A9bB6dAa1` |

## Backend Env

```json
{"5042002":{"FxPerpClearinghouse":"0x6A265045D9A3291D2881d77DDC62e2781A2418c5","FxMarginAccount":"0x35c7cD02cFa0c2889547482B71c1a5114d8439C6","FxFundingEngine":"0x88B70872759E1aA24858746779Cb15ca9F2cdcf3","FxHealthChecker":"0x272305e821D810eC5741761F98DbDC273efD47E6","FxLiquidationEngine":"0xD384560E5f8CE969BF4C1BDfAFACc5304AFbe8f2","FxOrderSettlement":"0x0F62FCdA2de63d905Cb167301C00251A9bB6dAa1"}}
```

## Broadcast Transactions

| Step | Tx |
| --- | --- |
| Deploy `FxMarginAccount` | `0xffdf5836f076f7ba41cbba1534ff402db836d8ae0bc707a88de25fb2bcd001ea` |
| Deploy `FxPerpClearinghouse` | `0x32020998f7109409f9488e87e51ff9d0a0cbb855547cd648250c10faa9d3d172` |
| Deploy `FxFundingEngine` | `0xb535c7b9f30f985d54fca8c6126f0be301bfe56ace11417c7d85f05a2a13c769` |
| Deploy `FxHealthChecker` | `0x0b69c5a0c634966755fb9f3e28a27b19647114df2ed42b8ababef63c082f4b8e` |
| Deploy `FxLiquidationEngine` | `0x140701ae438b414909880fc221e3e271bf9fc4962171172eca5a53a05f59e5d8` |
| Deploy `FxOrderSettlement` | `0x4f8c5f5950b8601d3634772917aacc221c0e196c97fd061d2786682b9be79efa` |

Role-grant and link transactions are recorded in `contracts/broadcast/DeployFxPerpStack.s.sol/5042002/run-latest.json`.

## Verification

Broadcast output: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`.

Post-broadcast checks confirmed:

- all six addresses have nonzero bytecode;
- `FxMarginAccount.USDC()` is `0x3600000000000000000000000000000000000000`;
- `FxMarginAccount.MARGIN_DECIMALS()` is `6`;
- `FxPerpClearinghouse.ORACLE()` is `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865`;
- `FxPerpClearinghouse.marginAccount()` is `0x35c7cD02cFa0c2889547482B71c1a5114d8439C6`;
- `FxPerpClearinghouse.fundingEngine()` is `0x88B70872759E1aA24858746779Cb15ca9F2cdcf3`;
- `FxMarginAccount.fundingSettlementHook()` is `0x6A265045D9A3291D2881d77DDC62e2781A2418c5`;
- margin `CLEARINGHOUSE_ROLE` is granted to clearinghouse, funding, and liquidation;
- margin `ACCOUNT_OPERATOR_ROLE` is granted to keeper;
- clearinghouse `ORDER_SETTLEMENT_ROLE` is granted to settlement;
- clearinghouse `LIQUIDATION_ENGINE_ROLE` is granted to liquidation;
- clearinghouse `EXECUTOR_ROLE` is granted to keeper;
- settlement `SETTLER_ROLE` is granted to keeper.

Market, funding, liquidation, and protocol-liquidity configuration are recorded in `reports/CONFIG_ARC_PHASE_B_E_PERP_MARKETS.md`.
