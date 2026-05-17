# Arc Phase B-E Perp Market Configuration

Date: 2026-05-17

Network: Arc testnet, chainId `5042002`

Admin: `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`

## Contracts

| Contract | Address |
| --- | --- |
| `FxPerpClearinghouse` | `0x25cDf2ad4Fd446e85273c4D7C77a03F22C742865` |
| `FxMarginAccount` | `0x1869D0253286dF29ce0AB8d29207772C7fD9dc35` |
| `FxFundingEngine` | `0x725822e8BC6edbcBa52914149e25f2671290C6D2` |
| `FxLiquidationEngine` | `0x01f71c1E74350633bBC9d554ca35DA40412DCFB7` |
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

`FxMarginAccount.protocolLiquidity()` is seeded to `100000000` USDC units.

Live readbacks after seed:

- `protocolLiquidity()`: `100000000`
- USDC balance of `FxMarginAccount`: `100000000`
- Admin USDC balance after seed: `140129188`
- Admin allowance to `FxMarginAccount`: `0`

## Transactions

Market/funding/liquidation config used `contracts/script/ConfigureArcPerpMarkets.s.sol`.
The script is Arc-guarded with `block.chainid == 5042002`.

| Action | Tx |
| --- | --- |
| Configure `EURC/USDC` market | `0xfc9fac0cddeaf65717db97551ae983b7f1dbe1261aa1688848d849f5aa839942` |
| Configure `EURC/USDC` funding | `0x29ed648c10a571cf1172fffd049c7c8a8fd2c83d0debc6b9acbcf4b0d7185875` |
| Configure `tJPYC/USDC` market | `0x5cc92f8b3db324c9531d8e66d027508f196ad80e6cffb0fd72c699180cc45f2b` |
| Configure `tJPYC/USDC` funding | `0x29775d3577a19de821ae4eb0e569d4c4a932594590ffc03bf0ba029e7feda64d` |
| Configure `tMXNB/USDC` market | `0x0f3488384d70420f8dfd61af375c8f6a561a018105a79e65b3685f62ffb5531c` |
| Configure `tMXNB/USDC` funding | `0x0b36d7f11254fa75a6ecd9c5d38195da81ff744b1c9348725649b6fb38f045b8` |
| Configure `tCHFC/USDC` market | `0x61e63408f1583a68e9964c2b973d81269cd2fc72d4105533f4b4b52f011e05de` |
| Configure `tCHFC/USDC` funding | `0x072fcbc0ea24fe78794f097c69da84ee955d5275a60c28739d128653f62c4809` |
| Configure liquidation | `0x315980ffef50b8297936c52e3c990e2f613e7765751ada5e95e50bc912a756a9` |
| Approve 100 USDC seed | `0xe23b1d49f5d8f01f47d40a9431f01a7e7fcde3c00557f43407ffc6db48cb5b21` |
| Deposit 100 USDC seed | `0x206bc24c8b962c2cec99c7d718bc379d291daba6af9566a9d042794f81b0d026` |

## Verification

Commands run:

```bash
ARC_PERP_PROTOCOL_LIQUIDITY_TARGET=0 \
forge script contracts/script/ConfigureArcPerpMarkets.s.sol:ConfigureArcPerpMarkets \
  --root contracts \
  --rpc-url https://rpc.testnet.arc.network \
  -vv

ARC_PERP_PROTOCOL_LIQUIDITY_TARGET=0 \
forge script contracts/script/ConfigureArcPerpMarkets.s.sol:ConfigureArcPerpMarkets \
  --root contracts \
  --rpc-url https://rpc.testnet.arc.network \
  --broadcast \
  -vv

forge test --root contracts --offline --match-path 'test/perp/*.t.sol' -vv
forge build --root contracts --offline --sizes
```

Results:

- Non-token Arc config dry-run passed.
- Arc config broadcast completed successfully.
- Perp unit/fuzz/invariant suite: `12` passed, `0` failed.
- `forge build --root contracts --offline --sizes` passed. Existing repository warnings remain unrelated to this configuration script.
- On-chain reads confirmed all four market configs, all four funding configs, liquidation config, and `100000000` protocol liquidity.

## Caveat

Foundry local fork simulation cannot execute Arc native USDC's blocklist precompile path during `transferFrom`, so the liquidity seed was intentionally sent as two live RPC transactions (`approve`, then `depositProtocolLiquidity`) after the non-token config dry-run passed. The live seed succeeded and readbacks confirm the margin account holds the 100 USDC backing bucket.

Trading opens still require a fresh oracle update path. Current live `FxOracle.getMid(baseToken, USDC)` calls can revert when Pyth prices are stale and no RedStone payload is supplied.
