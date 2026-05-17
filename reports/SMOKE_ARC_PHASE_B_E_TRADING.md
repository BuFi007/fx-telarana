# Arc Phase B-E Trading Smoke

Date: 2026-05-17

Network: Arc testnet, chainId `5042002`

Admin / keeper: `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`

Manifest: `deployments/perps-config-5042002.json`

## Scope

This smoke executed the requested Arc-only flow:

- live quote against `FxPerpClearinghouse.quoteFee`
- EIP-712 signed order digesting/signing
- matcher settlement through `FxOrderSettlement.settleMatch`
- funding poke through `FxFundingEngine.pokeFundingRate`
- liquidation scanner through `FxHealthChecker`
- account flag and liquidation through `FxLiquidationEngine`

Reusable script:

- `packages/sdk/scripts/perp-arc-trading-smoke.ts`

## Contracts

| Contract | Address |
| --- | --- |
| `FxPerpClearinghouse` | `0x6A265045D9A3291D2881d77DDC62e2781A2418c5` |
| `FxMarginAccount` | `0x35c7cD02cFa0c2889547482B71c1a5114d8439C6` |
| `FxFundingEngine` | `0x88B70872759E1aA24858746779Cb15ca9F2cdcf3` |
| `FxHealthChecker` | `0x272305e821D810eC5741761F98DbDC273efD47E6` |
| `FxLiquidationEngine` | `0xD384560E5f8CE969BF4C1BDfAFACc5304AFbe8f2` |
| `FxOrderSettlement` | `0x0F62FCdA2de63d905Cb167301C00251A9bB6dAa1` |

## Smoke Participants

- Taker: `0x3A1a762459B6bbb13f0D1681eA44D6A00159315E`
- Liquidation victim: `0x0d1F6506096E77bdC4faA1d25827D5DD52eBb2ED`
- Hedge account: `0x784B65d7f757E5639b7Ec40bCc2e5EEcF83920bf`

The script derives smoke-only signing keys from `DEPLOYER_PRIVATE_KEY` at runtime and never prints private keys.

## Successful Run

| Step | Result |
| --- | --- |
| Fresh Pyth update | `0x0c9b3214a69d7e489eb2a7e2df5e06132dc33607acf8fc5d3f7f1e1c6e5e691b` |
| Oracle mid | `1161661346799466383` |
| `quoteFee` for `0.01` EURC | `fee = 5`, `priceE18 = 1161661346799466383` |
| USDC approve for margin deposits | `0xcacc508155c881593ddbc0721f8ea5d929c09d8cabb84ebb4ebe0d09e0d09d75` |
| Admin margin deposit | `0x105942d71cda8bac34cc09bf6a126dead41ede16ddafc6125f9257706c281c37` |
| Taker margin deposit | `0x4de9ba4cd0f3e11b9c1b11ddaa4ca8c64e70a95251e5d63674dcc7787f151dd3` |
| Victim margin deposit | `0x2e500886bc36cee66347b9ebca3cd882723f93d29a74830cc8a454f70c7af8c8` |
| Hedge margin deposit | `0x6cb222b22de22f18fdb68abdae3520fb5b070f9276000c6c1e5aa1208e73f565` |
| Maker order digest | `0x11c497946e4be8b1f2c76a7177fc987659320e6cd62cbc47c27d46f03b7398f5` |
| Taker order digest | `0x162e5630ae7fbcd47f61e77a11d9d761b7d99efa097eab7b35c18d2b279f6a32` |
| Healthy `settleMatch` | `0x779b65f9e49c7267cba62e979709151a9dae84f03c595e4a2c93159e33265ac4` |
| `pokeFundingRate` | `0x2cc8513ffeb9e7b961e08c779da70dd0bad6537b0fc13b13f77806655b160156` |
| Funding state after poke | `version = 3`, `rate = 0`, `cumulative = 0` |
| Victim order digest | `0x0ee4bc222cb4c60013311e1b13562ab7fa953c6cfe7cd3bae061e0a0353bd55d` |
| Hedge order digest | `0x69438931e4caa0e8e64361e6bad1b82cbf7420ebca7ece49673335a91eb01634` |
| Liquidation-candidate `settleMatch` | `0x0be94e276510684742dd9d8db5bc228e056a4b226bb87baa3a43ca2f1445f032` |
| Fresh Pyth update before scanner | `0x00e4c7de1ab313928ec85219ef8bf9cf23dd56c9e62e4d1f1cbd7b9d8f72a79b` |
| Liquidation scanner | `healthFactorBps = 0`, `liquidatable = true` |
| `flagAccount` | `0x7d94f84b1216267ad74a828be59d38645d83327b32a7516f4f847b4fb50bd85a` |
| Fresh Pyth update before liquidation | `0x05968cbc875d81e3cad0e83ce848a280ef095f52b7c6a7d441b04bd7adb9c43f` |
| `liquidate` | `0x3b065bb167b5f894b5739948a7e6cbaf05589e5cdb5437ea6b26c3b2a13cac26` |

Post-smoke readback:

- Victim position: `(0, 0, 0, 0)`
- `EURC/USDC` open interest long: `11616`
- `EURC/USDC` open interest short: `592446`
- `FxMarginAccount.protocolLiquidity()`: `100100300`
- `USDC.balanceOf(FxMarginAccount)`: `100700000`

## Verification

Commands run:

```bash
ARC_RPC_URL=https://rpc.testnet.arc.network \
ARC_PERP_CONFIG_PATH=/Users/criptopoeta/Documents/fx-telarana_phase_b_e/deployments/perps-config-5042002.json \
bun packages/sdk/scripts/perp-arc-trading-smoke.ts
```

Follow-up checks:

- `bun run perps:arc:config:verify`: passed
- `bun run typecheck` in `packages/sdk`: passed
- `bun test` in `packages/sdk`: `38` passed, `0` failed
- `forge test --root contracts --offline --match-path 'test/perp/*.t.sol'`: `15` passed, `0` failed

## Notes

Funding rate was `0` because the smoke's signed matcher flow kept skew small. This still exercised the keeper-accessible funding poke path and state readback.

The smoke uses `FxOracle.getMidWithUpdatePyth` before quote and liquidation scanner steps so live oracle reads do not depend on stale cached Pyth values.
