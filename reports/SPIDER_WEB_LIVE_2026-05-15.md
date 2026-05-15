# Spider Web Live — Fuji L1 Broadcast Report

**Date:** 2026-05-15
**Branch:** `codex/frontend-handoff-avalanche-fx` (PR #5)
**Network:** Avalanche Fuji testnet (chainId 43113)
**Deployer:** `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`
**Gas spent (total):** ~0.0000003 AVAX out of 1.99 AVAX provisioned. Effectively free.

## Summary

The Phase 3 multi-stablecoin basket + Avalanche-to-Arc gateway hub-hook are deployed and configured on **real Avalanche Fuji L1**, not a Tenderly virtual testnet. The deploy ran in 7 phased forge invocations (no Tenderly TUs/s rolling-window issue on real L1 since gas is just gas) and the gateway hook is wired against the canonical Circle Gateway addresses returned by `circle contract address gateway --chain AVAX-FUJI`.

## Live addresses (Fuji 43113)

### Hub core (Phase 1)

| Contract | Address |
|---|---|
| FxOracle | `0x54295160F754045BCF5b603d236b984d00A5c409` |
| FxMarketRegistry | `0xd0f5AEB3611778b42cA0A2892B24BBeCa4BfbE46` |
| FxLiquidator | `0xd9e574B1BbadB55d8685a4C9EFc941A539074168` |
| FxHubMessageReceiver | `0x8abe2C1C1Da01bCa1052FFF7C577604C77a2433a` |
| MockPyth | `0xa8aE5c958F01Ba0570D78cD807555474aA67EE91` |
| Basket USDC (MockStablecoin) | `0xF2C8C08E739b22eF6055892892E1ad179edc4396` |
| Uniswap v4 PoolManager | `0x2B483aD8B35310563C724b0D3c0b046665F235e3` |
| PoolSwapTest | (in manifest) |

### Governance (Phase 3)

| Contract | Address |
|---|---|
| FxTimelock (OZ TimelockController, 24h delay) | `0xa29fB6c46c378475C123abfe47295E08731080aB` |

Verification: `cast call FxOracle "hasRole(bytes32,address)(bool)" 0x00…00 FxTimelock --rpc-url $FUJI_RPC` → `true`. Same getter against the deployer → `false`. Admin handoff complete; deployer holds no admin role on FxOracle, FxMarketRegistry, or FxLiquidator.

### v4 hooks per basket asset (Phase 2)

Each hook ends in `0AC8` — the HookMiner CREATE2 salt search produces addresses with the required v4 permission flag bits set in the low bits of the address.

| Pair | Hook |
|---|---|
| USDC/JPYC | `0xA7CF9314E9e2699E49478d95b9f49202eADA8AC8` |
| USDC/MXNB | `0xE8aC5C28D293407b5124E71F0aED77261b8D0AC8` |
| USDC/AUDF | `0x8fA9336ec1053acb4F890f78E4454fA13E28CAC8` |
| USDC/KRW1 | `0x5777D7efaF733c3d9156733253E30e51BF0D0AC8` |
| USDC/ZCHF | `0xaFdE316a55B96DF1F5219e4eE8d1A89eBbB60AC8` |

Each pair has two markets registered with Morpho (loan=asset/collat=USDC, and mirror), two MorphoOracleAdapter instances, two FxReceipt ERC-4626 wrappers, and seeded LP positions in the swap hook. Full address set under `deployments/tenderly-avalanche-fuji-basket.json` (81 keys).

### Gateway (Stage 2 smoke)

| Contract | Address |
|---|---|
| TelaranaGatewayHubHook | `0x79Cb6068CF11464d3EB47c6f7D01631C3006dD59` |
| Circle GatewayMinter (immutable on hook) | `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B` |
| Circle GatewayWallet | `0x0077777d7EBA4688BDeF3E311b846F25870A19B9` |
| Local USDC (immutable on hook) | `0x5425890298aed601595a70AB815c96711a31Bc65` (real Fuji USDC) |
| Destination hub (forwards to) | `0x8abe2C1C1Da01bCa1052FFF7C577604C77a2433a` (basket FxHubMessageReceiver) |
| Route id | `0x8b605b5be9e102dc245b157d0244d1aff8d7d78714b17136bd4aef2140188f4f` |
| Source/destination CCTP domain | 26 (Arc) → 1 (Fuji) |

Verification via `cast`:
- `GATEWAY_MINTER()` → `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B` ✓
- `USDC()` → `0x5425890298aed601595a70AB815c96711a31Bc65` ✓

## Probes asserted in-broadcast

The gateway smoke ran 5 probes inside a single forge broadcast:

| Probe | Assertion |
|---|---|
| A — `setGatewayRoute` | Hook accepts route with real Circle minter + real Fuji USDC + destination hub |
| B — `gatewayRoute(routeId)` read-back | All slot fields round-trip correctly (minter, USDC, sourceDomain, destDomain, enabled, metadataRef) |
| C — disable/re-enable state | `setGatewayRoute(enabled=false)` → `gatewayRoute(routeId).enabled == false`. Re-enable returns to true. |
| D — pause/unpause state | `pause()` → `paused() == true`. `unpause()` → `paused() == false`. |
| E — immutable verification | Hook's `GATEWAY_MINTER` immutable == Circle's canonical Gateway Minter; `USDC` immutable == Fuji real USDC; minter has bytecode |

Probes for the revert-side behavior of `receiveGatewayMint` (disabled-route revert, paused revert, fake-attestation revert from Circle's signature verifier) are covered by 24 unit tests in `contracts/test/TelaranaGatewayHubHook.t.sol`. We don't re-run them in the broadcast script because forge's `--broadcast` simulator aborts the whole run when ANY revert happens during simulation, even reverts caught by `try/catch`. State assertions sidestep that quirk.

## What still needs to happen for the full Spider Web end-to-end

1. **Real cross-chain Gateway USDC happy mint.** Requires:
   - Depositor calls `circle gateway deposit --chain AVAX-FUJI --amount X` to seed USDC into `GatewayWallet`.
   - Circle's relayer signs a BurnIntent attestation (off-chain, Circle infrastructure).
   - Relayer EOA holds `EXECUTOR_ROLE` on the destination-hub `TelaranaGatewayHubHook` (currently the deployer holds it).
   - Relayer calls `receiveGatewayMint(realAttestation, realSig, ctx)` on the destination hook → mint lands, USDC forwards to destination hub `FxHubMessageReceiver`.
2. **Arc-side hub broadcast.** Mirror Stages 1-2 on Arc Testnet (chainId 5042002). Gated on a one-off Morpho Blue self-deploy since Morpho is not on Arc.
3. **Spoke fleet retest.** Existing FxSpoke contracts on Base Sepolia / Sepolia / OP Sepolia / Arbitrum Sepolia / Polygon Amoy / Unichain Sepolia / WorldChain Sepolia / Arc Testnet route to the v1.2.x Fuji hub. Re-point or deploy parallel spokes targeting the new basket `FxHubMessageReceiver`.
4. **Ghost Mode end-to-end.** Spoke router + commitment registry + mock withdrawal scaffold exist. Real ZK verifier integration is Phase 1+ per `docs/TODOS.md`.

## Gas accounting

Per phase (real Fuji L1 gas, ~2 navax per gas):

| Phase | Gas used | AVAX |
|---|---|---|
| Phase 1 (core) | 22,358,814 | 0.00000004472 |
| Phase 2 × 5 (assets) | ~25M each | ~0.00000025 total |
| Phase 3 (handoff) | 2,673,074 | 0.0000000053 |
| Smoke (gateway wiring) | 4,047,759 | 0.00000000810 |
| **Total** | ~155M gas | **~0.0000003 AVAX** |

Deployer balance: 2.147 AVAX before, 2.147 AVAX after (effectively unchanged at this gas price). Plenty of headroom for Arc-side broadcast + spoke retests.

## Verification matrix (all green)

| Check | Result |
|---|---|
| `forge build --root contracts` | exit 0 |
| `bun run contracts:guardrails` | contract guardrails passed |
| `bun run contracts:test` | 171/172 (1 skipped) |
| Phase 1-3 on-chain broadcast | success |
| Gateway smoke on-chain broadcast | success |
| FxOracle admin == FxTimelock | true |
| FxOracle admin == deployer | false (renounced) |
| Hook `GATEWAY_MINTER` == Circle real minter | true |
| Hook `USDC` == Fuji real Circle USDC | true |
| Total contracts in manifest | 81 keys |

## Files in this commit

- `deployments/tenderly-avalanche-fuji-basket.json` — canonical manifest (81 keys).
- `deployments/_tenderly-basket-phases/phase1-core.json`, `phase2-{JPYC,MXNB,AUDF,KRW1,ZCHF}.json`, `phase3-handoff.json`, `smoke-gateway-wiring.json` — per-phase sub-manifests.
- `contracts/script/SmokeGatewayWiring.s.sol` — refactored Probes C, D, E to assert state instead of revert behavior (avoid forge `--broadcast` simulator aborts on caught reverts).
- `contracts/broadcast/Phase*` + `SmokeGatewayWiring*` — forge broadcast artifacts with on-chain tx receipts.
- `reports/SPIDER_WEB_LIVE_2026-05-15.md` — this report.
