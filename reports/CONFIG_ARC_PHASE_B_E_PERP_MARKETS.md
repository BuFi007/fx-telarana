# Arc Phase B-E Perp Market Configuration

Date: 2026-05-17

Network: Arc testnet, chainId `5042002`

Admin: `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`

## Contracts

| Contract | Address |
| --- | --- |
| `FxPerpClearinghouse` | `0x6A265045D9A3291D2881d77DDC62e2781A2418c5` |
| `FxMarginAccount` | `0x35c7cD02cFa0c2889547482B71c1a5114d8439C6` |
| `FxFundingEngine` | `0x88B70872759E1aA24858746779Cb15ca9F2cdcf3` |
| `FxLiquidationEngine` | `0xD384560E5f8CE969BF4C1BDfAFACc5304AFbe8f2` |
| `USDC` | `0x3600000000000000000000000000000000000000` |

## Market Params

All markets were enabled with:

- Initial margin: `500` bps
- Maintenance margin: `300` bps
- Trading fee: `5` bps
- Max leverage: `200000` bps

| Market | Market ID | Base token | OI cap | Max skew |
| --- | --- | --- | ---: | ---: |
| `EURC/USDC` | `0x565a6e2fab61800aa18813603b5b485af5bed7dea1aa0845bdaa61502063cab8` | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | `1000000000` | `1000000000` |
| `tJPYC/USDC` | `0x9ccad283db415085bf69329b696bfc7a34bff2d476f5cf7b1d4a3ba9bc0b70ab` | `0xB176f6E0c8ecc2be208F72Ad34c54e5F10F1882a` | `500000000` | `500000000` |
| `tMXNB/USDC` | `0xb698dfdbcbae088741081a53b9f1da11df8ff7c92c9278b66e15a34077ea5ca3` | `0xe8F76f90553F50E76731afbeF1ac83a9152fFBEb` | `500000000` | `500000000` |
| `tCHFC/USDC` | `0x992a2a93cd7a43a9ca827907f708a00ef88e9757e8aadab780ec4f58b161c7dd` | `0x249DBFd4ac17247Cf10098F6C3937F90570b5750` | `500000000` | `500000000` |

## Funding Params

All markets were enabled with:

- Max funding rate: `1` bps per second
- Funding velocity: `1` bps

## Liquidation Params

- Bounty: `500` bps
- Bounty cap: `5000000`
- Flag delay: `0`

## Protocol Liquidity Seed

The explicit protocol liquidity seed deposited `100000000` USDC units into `FxMarginAccount`.

Post-smoke live readbacks:

- `protocolLiquidity()`: `100100300`
- `totalAccountMargin()`: `599700`
- USDC balance of `FxMarginAccount`: `100700000`

## Transactions

Market/funding/liquidation config used `contracts/script/ConfigureArcPerpMarkets.s.sol`.
The script is Arc-guarded with `block.chainid == 5042002`.

| Action | Tx |
| --- | --- |
| Configure `EURC/USDC` market | `0x98b0a0b40a2ffcb2d9020d8f6961bb2ce5f8b22c5dd08633c0c9c735ee585756` |
| Configure `EURC/USDC` funding | `0x201ee04bbdc42f09aa696314d977b01324f2a13089d64fba44223446bb575a4c` |
| Configure `tJPYC/USDC` market | `0x2062ba7e5a5e317e808151afab7f68df2dbd2d54f3e1cf5a7dc645394225ae5d` |
| Configure `tJPYC/USDC` funding | `0x3e4a7d3e10bf12e589d02d8c2613c654baa5d04e352db5070910ada8b8d3e9d6` |
| Configure `tMXNB/USDC` market | `0x92c4f84c8d1556f1f835e2154cf821c983d549fdeb490ff1637e87564bb01b25` |
| Configure `tMXNB/USDC` funding | `0x390a3f912d533a857aee32f418f0cab7d1f9d95d48c7b163229d058915a0669e` |
| Configure `tCHFC/USDC` market | `0x0b8f5294b3d22848bd2e43cb016533feaf8de5063b8bc21b91704c20e986396c` |
| Configure `tCHFC/USDC` funding | `0xa88177a80cffbdb2fc92d2baa2c0b3f88d499916eafcb59d6943b30cb7c61e95` |
| Configure liquidation | `0xcb96b07fe714cac4ee1676912080f922672e8a94a67dd7a866b752891238e57b` |
| Approve 100 USDC seed | `0xf0e57d767400543bce0257d0fce2f6ffa47495103814325b0eb80076e78ddb44` |
| Deposit 100 USDC seed | `0xca3dc7ee76eb8036dacc44700616934a6d2fa5c640da7334146618321c4f10a5` |

## Verification

Commands run:

```bash
bun run perps:arc:config:verify
bun run perps:arc:config:export
forge test --root contracts --offline --match-path 'test/perp/*.t.sol'
```

Results:

- Arc config broadcast completed successfully.
- Cold readiness verification passed with repo defaults.
- Perp unit/fuzz/invariant suite: `15` passed, `0` failed.
- On-chain reads confirmed all four market configs, all four funding configs, liquidation config, funding engine link, funding settlement hook, and protocol liquidity.

## Caveat

Foundry local fork simulation cannot execute Arc native USDC's blocklist precompile path during `transferFrom`, so the liquidity seed was sent as two live RPC transactions (`approve`, then `depositProtocolLiquidity`) after the non-token config transactions passed. The live seed succeeded and readbacks confirm the margin account holds the backing bucket.

Trading smoke uses `FxOracle.getMidWithUpdatePyth` before quote and liquidation scanner steps so live oracle reads do not depend on stale cached Pyth values.
