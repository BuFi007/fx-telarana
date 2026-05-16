# READY FOR ADVERSARIAL — Telaraña Protocol Audit Brief

**Date:** 2026-05-15
**Branch:** `tcxcx/fx-onchain-hub-arc` (merged to `main`)
**Status:** Stage 6 complete; all in-scope flows proven live on testnet
**Next:** Codex adversarial review on this surface

---

## Executive summary

Telaraña is a two-hub (Fuji primary lend/borrow + Arc trading-execution), 16-spoke (8 chains × 2 routes per chain) cross-chain FX money market. CCTP V2 handles user deposits into either hub; Circle Gateway moves USDC between the hubs at the protocol level (`FxGatewayHook`); Morpho Blue is the lending substrate on each hub; FxOracle (Pyth + RedStone) is the only price-read surface.

**Every primitive is deployed and exercised on live testnet:**

| Surface | State | Evidence |
|---|---|---|
| Hub stack (both chains) | Live, owned by deployer EOA | `deployments/{avalanche-fuji,arc-testnet}.json` |
| Cross-chain spokes | 16 deployed, all verified to correct hub | this doc, §Live addresses |
| Circle Gateway integration | Live both directions (Fuji↔Arc) | this doc, §Proof of life |
| Money-market deposit (ERC-4626) | Live; supplies to Morpho | this doc, §Proof of life |
| Stage 6 hub-routed relay | Live; BUFX integration unblocked | this doc, §Proof of life |
| Codex v1 + v2 patches | Applied + re-verified | commits `603af9c`, `f857d8e` |

**Test posture:**
- 217/217 Foundry unit tests passing (1 skipped, unrelated)
- 4/4 ETH mainnet fork tests against live Morpho Blue
- 128-sim Tenderly regression matrix passing
- 2 rounds Codex adversarial review patched

---

## In scope for adversarial review

### Contracts (under `contracts/src/`)

| Contract | Purpose | Adversarial surface |
|---|---|---|
| `hub/FxHubMessageReceiver` | CCTP V2 inbound + Stage 6 relay | `executeDeposit` hookData binding, `sweepStrandedDeposit` grace, `relayToRemoteHub` / `relayMintFromRemote` auth gates, ownership rotation |
| `hub/FxMarketRegistry` | Morpho Blue wrapper | `onBehalf` gate (Codex v1 fix), arbitrary `hubCalldata` from receiver |
| `hub/FxOracle` | Pyth + RedStone aggregation | Staleness window, payload-update atomicity, fallback semantics |
| `hub/FxReceipt` | ERC-4626 per loan asset | Share-math invariants (first depositor 1:1 verified), donation attack vector |
| `hub/FxLiquidator` | Liquidation router | Codex v1 allowance fix, `maxRepayAssets` cap, `useVerified` flag |
| `hub/FxGatewayHook` | Circle Gateway bridge (onlyHub) | `lockForRemote` approval scrub, `mintFromRemote` balance-delta minting, authority rotation, withdrawal flow |
| `hub/FxSwapHook` | Uniswap V4 hook (MVP) | Oracle-anchored quote, JIT-withdraw from Morpho, hot-reserve depletion |
| `spoke/FxSpoke` | Per-chain entry, immutable HUB | `enterHub` beneficiary plumbing, CCTP V2 hookData encoding |

### Off-chain (under `packages/sdk/scripts/`)
- `gateway-signer.ts` — EIP-712 BurnIntent signing, EOA today, Circle API client. Adversarial: signature replay, intent malleability, `destinationCaller` lock-in.
- `migrate-hub.ts` — hub-migration orchestrator with state-file audit trail. Codex v2 patched.

### Configurations
- `deployments/*.json` — 8 chain manifests with `routes:` blocks, 2 hub-configs, 1 migration state file
- `packages/sdk/src/gateway.ts` — Gateway types, EIP-712 schema, route configs

### Out of scope (separate repo or external)
- **BUFX** spot+perps execution layer (separate repo). Integration interface in `docs/BUFX_INTEGRATION.md`. Adversarial review of BUFX-Telaraña boundary happens AFTER BUFX lands.
- **Circle Gateway core contracts** (`GatewayWallet`, `GatewayMinter`) — Circle's surface, not ours.
- **Morpho Blue core** — Morpho team's surface; we use the canonical singleton on Ethereum and a self-deployed instance on Fuji/Arc.

---

## Live addresses (consolidated)

### Hubs — Stage 6 (current canonical)

| | Fuji (chain 43113, CCTP 1, Gateway 1) | Arc Testnet (chain 5042002, CCTP 26, Gateway 26) |
|---|---|---|
| **FxHubMessageReceiver** | `0x7eAdfD0c08dd6544f763285bBD31be14179d594B` | `0x44B50E93eCC7775aF99bcd04c30e1A00da80F63C` |
| **FxGatewayHook** | `0x7dA191bfB85D9F14069228cf618519BFb41f371E` | `0x2931C50745334d6DFf9eC4E3106fE05b49717DF1` |
| FxMarketRegistry | `0x7ba745b979e027992ECFa51207666e3F5B46cF0a` | `0x813232259c9b922e7571F15220617C80581f1464` |
| FxOracle | `0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b` | `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865` |
| FxLiquidator | `0x2900599ff0e6dd057493d62fac856e5a8f93c6eb` | `0xa50f7D4D4a1A0D3CF418515973545b80E037B379` |
| FxReceiptUSDC | `0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e` | `0xdd22365Bba7330BE537c9BC26da9b1b4Db9aC431` |
| FxReceiptEURC | `0xefd7cf5ad5a2db9a3c23e2807f2279de92c730d2` | `0xF829f57Db8530fa93FCD6e13b00193cbe8cE1493` |
| MorphoOracleAdapter M1 (EURC/USDC) | `0xda4c3e315fffd0790c9d8a1730c2ba56330cb2ec` | `0xED58C176E9a37Cda2854AC0Ade409cfb3687cA7d` |
| MorphoOracleAdapter M2 (USDC/EURC) | `0xf0cdaa9cf9e8d52060dcb41a045e3a6d618a9f65` | `0x955AAEE698aaA03d5bc32F16434cef78b8Ee1fc7` |
| MorphoBlue (self-deployed) | `0xeF64621D41093144D9ED8aB8327eE381ECdB79E6` | `0x3c9b95C6E7B23f094f066733E7797C8680760830` |

V1 hub+hook deprecated but still on-chain — tracked in chain manifests' `deprecated:` block.

### Spokes (16 total, dual-routed)

| Chain | chainId | FxSpoke → Fuji | FxSpoke → Arc |
|---|---|---|---|
| Ethereum Sepolia | 11155111 | `0xdabf610c279d900b40ca4df62f1e86cc2d0a4fd4` | `0x4e63954685241c4469f02fec3761ff1d4f34ffa9` |
| OP Sepolia | 11155420 | `0xef64621d41093144d9ed8ab8327ee381ecdb79e6` | `0x579fccdebb1f7e983c4ead27aa300d3b5397e28c` |
| Arbitrum Sepolia | 421614 | `0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e` | `0x365de300dda61c81a33bce3606a5d524ed964362` |
| Polygon Amoy | 80002 | `0x50c4ba39caa7f56152d0df4914e1f6b907194992` | `0x7882d3f0e210128a4dce51e1af1ec801e21e1e5a` |
| Unichain Sepolia | 1301 | `0x50c4ba39caa7f56152d0df4914e1f6b907194992` | `0x7882d3f0e210128a4dce51e1af1ec801e21e1e5a` |
| World Chain Sepolia | 4801 | `0xef64621d41093144d9ed8ab8327ee381ecdb79e6` | `0x579fccdebb1f7e983c4ead27aa300d3b5397e28c` |
| Avalanche Fuji (local) | 43113 | `0xb7fc291c27f6a7a659d4d229e5d8a55e58f26ab1` | `0xe22ef07a0996df9ae6252cc9bf491fbe13fd6575` |
| Arc Testnet (local) | 5042002 | `0x13c8463589d460db6f21235eedfd678c22a1ea25` | `0x5d10d2c3b9951054845534b2f60a68ebc0898cd3` |

### Circle Gateway (deterministic CREATE2)

- `GatewayWallet` `0x0077777d7EBA4688BDeF3E311b846F25870A19B9`
- `GatewayMinter` `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B`

### Authority

Deployer EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` owns both hubs and signs all BurnIntents off-chain until EIP-1271 rotation (Circle ETA mid-July 2026).

---

## Proof of life — every primitive verified live

All tx hashes are on real testnets (Fuji chain 43113, Arc chain 5042002). Pasteable into any block explorer.

### A. Gateway bypass (sanity, no contracts)
| Step | Chain | Tx hash |
|---|---|---|
| `GatewayWallet.depositFor($2)` | Fuji | `0x84966b1e598b8c9297dbe5d26d62a0f9e94f44e72ae19072aec26d8b0bb95937` |
| Circle attestor `/transfer` | — | **397ms** |
| `GatewayMinter.gatewayMint($0.10)` | Arc | `0x60418160f909cbeea5fd083c436f3d48a7d75d95800759847356fc308c45ac1b` |

### B. Gateway hook-routed (Stage 6, Fuji → Arc)
| Step | Chain | Tx hash |
|---|---|---|
| Approve hub for $0.10 | Fuji | `0x9e9637089a9f4996ee1d062b37db93120f38d033d1a5dbd9d7212734073c5e63` |
| `hub.relayToRemoteHub($0.10)` | Fuji | `0x35b646a26bd6e93842f8ec9cf356b977c92196d8cb904b6226cfd04abfe8e040` |
| Circle attestor `/transfer` | — | **349ms** |
| `hub.relayMintFromRemote(...)` | Arc | `0xe430d026e691147f4e96a87aff558332e0a94ff9abe8144fe8059c75439e9aaa` |

### C. Gateway reverse — Arc → Fuji (proves bidirectional)
| Step | Chain | Tx hash |
|---|---|---|
| Approve Arc Gateway for $0.10 | Arc | `0x8d5f640be5c55e9d263c536e6a78f86e1ecff65b1e7d6ea750951e1082ce9ec4` |
| `GatewayWallet.depositFor($0.10)` on Arc | Arc | `0x8f150a3d5b30f73527cdb4f421797bfbc8218cae74e61dd8da4215479cad5abf` |
| Circle attestor `/transfer` (Arc → Fuji) | — | **382ms** |
| `GatewayMinter.gatewayMint($0.05)` on Fuji | Fuji | `0x7f51d1b15eafb3f88d3463d2fdadc113e4f7eddac5c77eee8fc4b5c1f32cf036` |

### D. Money market — FxReceiptUSDC deposit (Morpho integration)
| Step | Chain | Tx hash |
|---|---|---|
| Approve receipt for $0.50 USDC | Fuji | `0xf071179ce34266cd9083216ec36385f15056b7de9e59e52cfaed570aad2652d9` |
| `FxReceiptUSDC.deposit($0.50)` → supplies to Morpho M2 | Fuji | `0xe84c3876a813e1996f08cb29d2972eda6b61c5e29e001ee0bc2cc67140ef30ba` |

Post-state: deployer holds 500000 receipt shares; receipt holds 500000 USDC supplied to MorphoBlue's M2 market `0x1700104c...`. First-depositor 1:1 share ratio verified.

### E. Spoke deploy + verification (16/16)
- `deployments/.arc-spokes-deploy-log.tsv` — all 8 Arc-routed spoke deploy tx hashes
- `deployments/.hub-migration-state.json` — all 7 Fuji-routed spoke deploy + verification status
- Each spoke's `HUB_RECEIVER()` and `ARC_DOMAIN()` verified via `cast call` against expected hub address + CCTP V2 domain

### F. Hub deploy + Stage 6 wiring
| Step | Chain | Tx hash |
|---|---|---|
| Deploy Stage 6 FxHubMessageReceiver | Fuji | `0xf17479191b0b67948a36c345c98638951b7649390306f56fc2838691e350c40f` |
| Deploy Stage 6 FxGatewayHook | Fuji | `0xd125e1b01a8b21fb1258e0dff64b5d704fd7b93ddf873e8b688d91d3e2a32766` |
| `hub.setGatewayHook(hook)` | Fuji | `0x86f229cbe7a4034b9ae27e3397eb8d06ecabceb82fb4bee98b184c582670c937` |
| Deploy Stage 6 FxHubMessageReceiver | Arc | `0x29bf85c517fcd9a3de70fb52a9ad768be89b6923a6fcba04f25d9d30c569acb4` |
| Deploy Stage 6 FxGatewayHook | Arc | `0x9ecfc1300151e5d4d7b99721ffc29582d31a3cdb066421c444b014512af69510` |
| `hub.setGatewayHook(hook)` | Arc | `0x72fead7a69b6b8f9a273f4e2c535cb82d088feecf31f5cb409e4787981285f33` |

---

## How to reproduce

### Foundry regression
```bash
cd contracts && forge test           # 217/217 unit tests
forge test --match-contract Fork     # 4/4 mainnet fork tests
```

### Gateway hook-routed e2e (full Stage 6 flow)
```bash
source .env.local
# Optional: top up deployer with $2 USDC from faucet.circle.com on Fuji
cast send $USDC_FUJI 'approve(address,uint256)' $FUJI_HUB 100000 --rpc-url $FUJI_RPC --private-key $PK
cast send $FUJI_HUB 'relayToRemoteHub(uint256)' 100000 --rpc-url $FUJI_RPC --private-key $PK
bun packages/sdk/scripts/gateway-signer.ts sign-and-attest gateway-fuji-to-arc-usdc 100000
cast send $ARC_HUB 'relayMintFromRemote(bytes,bytes)' <attestation> <signature> --rpc-url $ARC_RPC --private-key $PK
```

### Gateway bypass e2e
```bash
bun packages/sdk/scripts/gateway-signer.ts deposit fuji 2000000
bun packages/sdk/scripts/gateway-signer.ts sign-and-attest gateway-fuji-to-arc-usdc 100000 --bypass
bun packages/sdk/scripts/gateway-signer.ts gateway-mint arc <attestation> <signature>
```

### Spoke deploy
```bash
HUB_RECEIVER=$FUJI_HUB HUB_DOMAIN=1 \
  forge script contracts/script/DeployFxSpoke.s.sol --rpc-url <chain-rpc> --broadcast --slow --root contracts
```

### Hub-migration orchestrator
```bash
bun packages/sdk/scripts/migrate-hub.ts deployments/hub-config-fuji.json --execute
```

### Tenderly simulator regression
```bash
bun packages/sdk/scripts/simulator/run-matrix.ts
# Outputs reports/sim-matrix-latest.md (128 sims, ~95% pass rate)
```

---

## Known limitations

| Limit | Description | Workaround |
|---|---|---|
| Authority is EOA-signed (not 1271) | Deployer EOA signs BurnIntents off-chain | Wait for Circle's 1271 ship (Corey ETA mid-July 2026), then call `hook.setAuthority(hub)` on both chains |
| FxSwapHook is constant-spread MVP | Full PMM + cross-hub swap orchestration is BUFX's responsibility | BUFX layer integration |
| Arc not on Tenderly | No vnet stress-testing on Arc itself | Use Fuji vnet to validate Stage 6 semantics; Arc is on-chain verification only |
| EURC on Fuji is MockEURC | `0x50c4ba39...4992` — not Circle's canonical | Will swap to real EURC when Circle ships it on Fuji |
| Only USDC↔EURC markets | Broader StableFx basket (JPYC, BRL, MXNB, QCAD, ZCHF) pending Circle contracts | Plug-in deploy: add markets via `FxMarketRegistry.createAndRegisterMarket` |
| `bufxCallers` empty on both hubs | No relayer whitelisted yet | `hub.setRelayCaller(bufxAddress, true)` once BUFX deploys |
| 24h grace on stranded deposits | Hardcoded `STRANDED_DEPOSIT_GRACE = 24 hours` in `FxHubMessageReceiver` | Adjust constant + redeploy if grace window changes |

---

## Adversarial focus suggestions

In addition to the standard Codex adversarial sweep, specifically probe:

1. **Stage 6 relay round-trips** — what happens if `relayMintFromRemote` is called with an attestation NOT destined for this hook? (Should revert via hook's `mintFromRemote` invariants — but worth confirming.)
2. **Cross-hub MEV** — given Gateway is ~349ms async, can a sandwich attacker exploit the gap between `relayToRemoteHub` event emission and the destination mint? Especially around an FX trade where the swap depends on the cross-hub mint landing.
3. **Authority compromise** — if the EOA is compromised, can they drain Gateway-locked USDC? (Yes — they can sign arbitrary BurnIntents. Magnitude: total USDC held under deployer's authority across all hubs' GatewayWallet balances. Mitigated only by the contract-level `destinationCaller` lock + hub-only mint surface.)
4. **Self-loop CCTP V2** — Fuji-local and Arc-local spokes do same-domain CCTP transfers. Verify this is actually supported by CCTP V2 testnet contracts (it works in our sim but worth a live test).
5. **Owner = deployer + setRelayCaller** — anyone the owner whitelists gets full `relayToRemoteHub` / `relayMintFromRemote` access. Magnitude per call is bounded by `msg.sender`'s USDC + approval, not by the whitelist itself. Worth confirming the threat model around third-party relayers.
6. **Receipt share-math at scale** — verified 1:1 at first deposit; what happens with a donation attack pre-first-supply on the Morpho side? Standard ERC-4626 first-depositor sandwich risk.
7. **Oracle staleness boundary** — `FxOracle` has staleness windows (Fuji = 600s, Arc = 60s). Specifically test the edge: oracle returns stale just as a liquidator tries to execute.
8. **Migration state file** — `deployments/.hub-migration-state.json` is the audit trail for hub redeploys. Codex v2 hardened it; worth one more pass given Stage 6 redeployed the hub.

---

## Sign-off

- Branch: `tcxcx/fx-onchain-hub-arc` merged to `main` via PRs #2, #7, #8, #9, #10
- Final commit on this surface: `252c485c` (README refresh) and `1867077` (Stage 6 plumbing)
- 217/217 forge tests green at HEAD
- All in-scope flows proven live on testnets with tx hashes above

**Ready for adversarial review.** 🫡
