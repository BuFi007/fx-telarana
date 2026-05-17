# Arc Phase B-E Trading Smoke

Date: 2026-05-17

Network: Arc testnet, chainId `5042002`

Admin / keeper: `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`

## Scope

This smoke executed the requested Arc-only flow:

- Explicit admin transactions for `configureMarket`
- Explicit admin transactions for `configureFunding`
- Explicit admin transaction for `configureLiquidation`
- Explicit `depositProtocolLiquidity`
- Trading smoke for quote, signed order intake, matcher settlement, funding poke, and liquidation scanner

Reusable script:

- `packages/sdk/scripts/perp-arc-trading-smoke.ts`

## Explicit Admin Transactions

Market and funding params match the Arc config report:

- Initial margin: `500` bps
- Maintenance margin: `300` bps
- Trading fee: `5` bps
- Max leverage: `200000` bps
- Funding: enabled, `maxFundingRateBpsPerSecond = 1`, `fundingVelocityBps = 1`
- Liquidation: `bountyBps = 500`, `bountyCap = 5000000`, `flagDelay = 0`

| Action | Tx |
| --- | --- |
| `configureMarket` `EURC/USDC` | `0xfe59fded02a8bc289adb08a2413e7b3201c7045f0fb757beb57da43e4cac0148` |
| `configureFunding` `EURC/USDC` | `0xa203c779570547f39fed8dcfa2291169649d3b55b531424b48763b6600c0b224` |
| `configureMarket` `tJPYC/USDC` | `0x1992d7fc71719a5dc0f16972add7a05310f145e220fca86f34460dbf572610a4` |
| `configureFunding` `tJPYC/USDC` | `0x344951241b6189757457800422b1256288ad9fee96db507e94b7a436306bf7e8` |
| `configureMarket` `tMXNB/USDC` | `0x79dde294d4d62a2d746bb1f38312ac5eaaec98881e06e7863a22038960498897` |
| `configureFunding` `tMXNB/USDC` | `0x13f2080a47e5de002aaf4ad464d4309fa79dbe8ef6132e27fdd3cda6f630315e` |
| `configureMarket` `tCHFC/USDC` | `0x3bfd3e595ab913d529ed84ab3b887f29896ed35f181bfb16be105a1c0e78d075` |
| `configureFunding` `tCHFC/USDC` | `0x967e1ab7338ea22549a52ecdf2f0ea1825b757ff1dcd3eb0f0833111cd1cefad` |
| `configureLiquidation` | `0x34d3daea8b1d5953733889da353bd55a9413b3af2798731c2956558f88288ad9` |
| USDC `approve` for protocol liquidity top-up | `0x8a7f61d90f654b77cb22fd9e1ab0a38c547e9a4d6ef3c7b5db1a3f9b44970e14` |
| `depositProtocolLiquidity(1000000)` | `0xc00493cbf57154419e0f1b2d1492a417bae9f7e7f04befed93e7a5b5dc7107af` |

Post-admin readback:

- `FxMarginAccount.protocolLiquidity()`: `101000000`
- `USDC.balanceOf(FxMarginAccount)`: `101000000`

## Trading Smoke

Smoke participants:

- Taker: `0x3A1a762459B6bbb13f0D1681eA44D6A00159315E`
- Liquidation victim: `0x0d1F6506096E77bdC4faA1d25827D5DD52eBb2ED`
- Hedge account: `0x784B65d7f757E5639b7Ec40bCc2e5EEcF83920bf`

The script derives smoke-only signing keys from `DEPLOYER_PRIVATE_KEY` at runtime and never prints the private keys.

### Successful Run

| Step | Result |
| --- | --- |
| Fresh Pyth update | `0x36c93ef2dcfbf11ea42134da34fa1bc94c9849de73a853e1c3fa292cc6c308d8` |
| Oracle mid | `1161586752309977840` |
| `quoteFee` for `0.01` EURC | `fee = 5`, `priceE18 = 1161586752309977840` |
| USDC approve for margin deposits | `0x446fdc3ca18f02f3d461316e10be48bbbe3323480578a0625943321fd6515b7d` |
| Admin margin deposit | `0xec4f71417aaf9144858ef7886bf24a23fe52153d0a13818d2f37e96aa9b10739` |
| Taker margin deposit | `0xbeabf9f458e8788d5f0645af173c5d017eda42df0302ac1b652cd8cd05dcafef` |
| Victim margin deposit | `0xc0c126ea624929ad7f519a9bf15760c43727344589b2909b56e66fe4e919f338` |
| Hedge margin deposit | `0x3efbd85d6ca126afb84efc4a9005599236f40fac1908cc88006b1c6693e76eae` |
| Maker order digest | `0xdd0c8c7410f9cc672ebb94c9fad50adeaf95ca35cb4f5761b5f476e7c6cac296` |
| Taker order digest | `0x697827ddbb5c0f7d4d112b227cfb0f26d3b5b396d9eea09160465b4b14953497` |
| Healthy `settleMatch` | `0xcd6c252cd3420c4a8667d61f15f8c1c0fe431b8249d8a0ee5a6595643bc2124e` |
| `pokeFundingRate` | `0xbd216b4932494be3513a4e25a906208a376cd33c4788f38c79520ff1d296c431` |
| Funding state after poke | `version = 2`, `rate = 0`, `cumulative = 0` |
| Victim order digest | `0x66f691173680ce816b8676d4dfe32176712fbc6a2f6a6cb5375d520412bbbf90` |
| Hedge order digest | `0xe4eb68ecb6d538cbfa360ea409a2a3906f83ddeb091fb6c19c3c5c610c21bf35` |
| Liquidation-candidate `settleMatch` | `0x2ebea83fb5e9515b5cbb826d106e9ae0da49cfd97437c48350e006597bf48a31` |
| Fresh Pyth update before scanner | `0x0a576686afdffd1d1de83a504d00ab1e9bbb7e0e8207fa675b702163db3e275d` |
| Liquidation scanner | `healthFactorBps = 0`, `liquidatable = true` |
| `flagAccount` | `0x75e2eb98fb4fdd1e5ea96f3e0d3c85b24422e548c1b70e4ea3b243dcc942d2b5` |
| Fresh Pyth update before liquidation | `0xbc16c481ca5845cf25d37410a15e1af6db1bd29dc9d95b096a511ec9c9afaad2` |
| `liquidate` | `0x4ceaf4d05e9e820428eb930dfc67ef44574135a73fafd5a9abf195bed1e13568` |

The first scanner calibration used a `3x` fill and correctly returned `liquidatable = false`; the script was adjusted to a `50x` fill for the intentional liquidation candidate. One cleanup liquidation pass was executed because the first calibration had left a tiny prior victim position:

| Cleanup Action | Tx |
| --- | --- |
| Cleanup `flagAccount` | `0x71ee02d7733f44f81206ddab2629f4ae3574127aebc4f82e7679d150a1a71cd9` |
| Cleanup `liquidate` | `0x1441503d77f458d3e072c29617c42deee99a0ed25286395f20f8531700ee1bfe` |

Post-smoke readback:

- Victim position: `(0, 0, 0, 0)`
- Victim health factor: `type(uint256).max`
- Victim liquidatable: `false`
- `FxMarginAccount.protocolLiquidity()`: `101200327`
- `USDC.balanceOf(FxMarginAccount)`: `102400000`

## Verification

Commands run:

```bash
ARC_RPC_URL=https://rpc.testnet.arc.network bun packages/sdk/scripts/perp-arc-trading-smoke.ts
bun run typecheck
```

Final contract readbacks confirmed:

- All four market configs still enabled with the expected params.
- All four funding configs still enabled with `(true, 1, 1)`.
- Liquidation config is `(500, 5000000, 0)`.
- Protocol liquidity is `101200327`.

## Notes

Funding rate was `0` because the smoke's signed matcher flow created balanced long and short open interest. This still exercised the keeper-accessible `pokeFundingRate` state transition and emitted the funding poke transaction.

The smoke uses `FxOracle.getMidWithUpdatePyth` before quote and liquidation scanner steps so live oracle reads do not depend on stale cached Pyth values.
