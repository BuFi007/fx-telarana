# Uniswap v4 Indexing Handoff

Generated from: `deployments/uniswap-v4-indexing-evidence-5042002.json`
Generated at: `2026-06-08`
Network: `arc-testnet`
Chain ID: `5042002`
Official Uniswap deployments source: https://developers.uniswap.org/docs/protocols/v4/deployments

## Current Conclusion

Arc testnet is demoable on self-deployed Uniswap v4 infrastructure, with 11 published pool records across FxHedgeHook, FxSwapHook, and TelaranaGatewayHubHook. Official Arc mainnet indexing remains externally pending until Uniswap publishes Arc v4 contracts. Avalanche C-Chain and Arbitrum One official v4 contracts are tracked, but chain-specific hook redeploy, PoolManager initialization, first liquidity, StateView, subgraph, and Quoter/custom-route evidence are still required before claiming indexed hook pools there.

## Official Multichain Status

| Network | Chain | Official status | Indexing readiness | Contracts |
| --- | ---: | --- | --- | --- |
| Arc Mainnet | pending | pending-official-uniswap-v4-addresses | not-indexable-yet-official-uniswap-v4-addresses-pending | PoolManager pending; Quoter pending; StateView pending |
| Avalanche Fuji | 43113 | pending-official-uniswap-v4-addresses | rehearsal-only-not-official-indexing | PoolManager pending; Quoter pending; StateView pending |
| Avalanche C-Chain | 43114 | official-uniswap-v4-addresses-published | official-contracts-known-hook-pool-publication-pending | PoolManager 0x06380c0e0912312b5150364b9dc4542ba0dbbc85; Quoter 0xbe40675bb704506a3c2ccfb762dcfd1e979845c2; StateView 0xc3c9e198c735a4b97e3e683f391ccbdd60b69286 |
| Arbitrum One | 42161 | official-uniswap-v4-addresses-published | official-contracts-known-hook-pool-publication-pending | PoolManager 0x360e68faccca8ca495c1b759fd9eee466db9fb32; Quoter 0x3972c00f7ed4885e145823eb7c655375d275a1c5; StateView 0x76fd297e2d437cd7f76d50f01afe6160f86e9990 |

## Arc Testnet Pool Evidence

| Family | Pair | Status | PoolManager | Hook | PoolId | Initialize tx | Router/Quoter evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| FxHedgeHook | JPYC/USDC | live | 0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E | 0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540 | 0xd19440c05e5c0d9549187e01162e8aeab29c196c3177cde6360db740b8aa3504 | 0xa2564c11072dddd7f56fa7150d2da815d6047f1cc6a8294782cd2ddb1687335e | locally-proven-with-official-v4quoter-diagnostic |
| FxHedgeHook | cirBTC/USDC | live | 0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E | 0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540 | 0x33e42e1b20e3ea50b925963b583a033a8b959f53ffe76fb18cb97a6c6a171a8d | 0x1e662456f1979eb6362935cc0057fce66a37fdd188d941d0d3f8a631b5b7b22c | locally-proven-with-official-v4quoter-diagnostic |
| FxHedgeHook | EURC/USDC | live | 0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E | 0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540 | 0x0a463f18e563a62ab306eb375452c3feebe9ccbdab822b3c3582ddd13443ce00 | 0x1b7a1a38a1960319a8d60a6ddf3e04a2d9d6f1ebd4931c86eaddfc4fbbcd128e | locally-proven-with-official-v4quoter-diagnostic |
| FxHedgeHook | AUDF/USDC | live | 0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E | 0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540 | 0x3d6aafb1d198968d10fb9d8596681979be57116efc7dda5f1e2694c6841a3e08 | 0x879b7286dc07d64ff83258769a19c6709edcda3bf0851765e6979602c4270b1d | locally-proven-with-official-v4quoter-diagnostic |
| FxHedgeHook | MXNB/USDC | live | 0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E | 0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540 | 0x5bd11000bfaa4f274a1cbc0b7d5c20f92ffc047738ac04963fcaac3221466946 | 0x40589ff7072d44afaeb90bacfb3fa65d58a77eba255c2443db9e2e4b5fe2c554 | locally-proven-with-official-v4quoter-diagnostic |
| FxHedgeHook | QCAD/USDC | live | 0x403Aa1347a77195FB4dEddc362758AA9e0a48D2E | 0x466e2BBFbF3D2Ca1a90eCf25fFF1e275b548C540 | 0x1ad04bd3b9be342b2c720b5bbde60569cea51b9c343cfb4848f342a45e061fd7 | 0xd0594a7fa15d4eaa6e471a2b308739a2bf428650d70ce64d629e9e03cb82dc34 | locally-proven-with-official-v4quoter-diagnostic |
| FxSwapHook | USDC/EURC | published-testnet-pool | 0x3FA22b7Aeda9ebBe34732ea394f1711887363B34 | 0x5bA91EB2f67302C947dFD35cC75D1dBcDb2CcAc8 | 0x4d268583c6cefb4fb959761f3f733c22b6a0bd622a2e7fa04dd30fe6e35e2d9c | 0xba9982b907ade0bcb67acabeac7b8bd36628b4e321f8ab8110f9384ce38da72e | diagnostic-proven-not-generic-empty-hookdata |
| FxSwapHook | USDC/AUDF | published-testnet-pool | 0x3FA22b7Aeda9ebBe34732ea394f1711887363B34 | 0x7Af1ed939C2d4965490f1546b08b07e0BFdA0ac8 | 0x7b1fbffcc973902a9cb09cb66f7322f7e750d0f54f953abdea910b2e21267de6 | 0xc3c5c4379bf5a4eca36abb822f08af18dca121b4d4de9756f117a9e17984615f | diagnostic-proven-not-generic-empty-hookdata |
| FxSwapHook | USDC/MXNB | published-testnet-pool | 0x3FA22b7Aeda9ebBe34732ea394f1711887363B34 | 0xe9B0cD01eD5F83EEAe98522052Ae3a798dfb8aC8 | 0x964b698844ab4699762ec07031a2dc953d7cfc17f567dc43faccf6dac23c1c39 | 0x289fe08e3bb5f0d571b41a2699959cde5adeff3e318a34c0659ee34f0b7af55c | diagnostic-proven-not-generic-empty-hookdata |
| FxSwapHook | QCAD/USDC | published-testnet-pool | 0x3FA22b7Aeda9ebBe34732ea394f1711887363B34 | 0x6f80Ab06A4e359e9E6D025105945f02CcC98CAc8 | 0x5303c347ab8aa48a98f6738d4598bd3d8db7a9924143a990ad883cd54a7adb41 | 0xb2d63cb96b38d981b9605013f88837b5ae614ae2088463a2beeeea15c63eaaf5 | diagnostic-proven-not-generic-empty-hookdata |
| TelaranaGatewayHubHook | USDC/EURC | live-gateway-demo | 0x3FA22b7Aeda9ebBe34732ea394f1711887363B34 | 0xe895CB461AFF6E98167a7FA0Db252ba906714088 | 0xf6b13fe5ae3115d159b3a844a56588d1549293fb6725040f01c54ba31827f711 | 0x91f605e7556c5aec98fd2a93ea00777321b55cdaf501a371404b708d01ce2921 | not-generic-hookdata-required |

## Reviewer Commands

| Purpose | Command |
| --- | --- |
| Official docs freshness | `bun run uniswap:official-multichain:docs:check` |
| Readiness aggregate | `bun run uniswap:indexing:check` |
| Arc official deployment input | `bun run uniswap:official-arc:input:check` |
| Arc pool publication fill plan | `bun run uniswap:official-arc:pools:plan` |
| StateView gate | `bun run uniswap:stateview:check` |
| Subgraph gate | `bun run uniswap:subgraph:check` |
| Evidence snapshot freshness | `bun run uniswap:evidence:check` |
| Submission audit | `bun run uniswap:submission:audit` |

## Do Not Claim Yet

- Official Uniswap Arc mainnet indexing, because official Arc v4 addresses are not published in the Uniswap deployments table as of 2026-06-08.
- Official Uniswap Avalanche Fuji indexing, because official Fuji v4 addresses are not published in the Uniswap deployments table as of 2026-06-08 and the recorded Fuji PoolManager is rehearsal-only.
- fx-Telarana hook indexing on Avalanche or Arbitrum, because official v4 contracts are known but protocol hooks still need chain-specific remine/redeploy, PoolManager Initialize txs, first liquidity, StateView verification, subgraph verification, and official Quoter diagnostics.
- Router-active/liquid FxHedgeHook hedge markets, because first liquidity txs are not published yet and current in-range liquidity is zero.
- Generic empty-hookData V4Quoter compatibility for FxSwapHook, because the local diagnostic proves this custom-accounting PMM requires the direct quote/protocol router path instead.

## No Ops Or Surveillance Additions

This packet is a static generated reviewer artifact. It does not add cron jobs, monitors, daemons, alerts, wallet surveillance, or unrelated operational surfaces.
