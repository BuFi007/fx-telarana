# Spider Web Testnet Runbook — Telaraña on Fuji L1 + Arc Testnet

**Goal:** stand up the full Telaraña Spider Web — spokes + Fuji hub + Arc hub + hub-to-hub Circle Gateway USDC liquidity — on real testnet chains. Replaces the Tenderly-vnet drill once and for all.

**Branch:** `codex/frontend-handoff-avalanche-fx`. PR #5.

**Deployer EOA:** `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` (canonical, per CLAUDE.md).

---

## 1. Gas needs per chain (operator action)

| Chain | Token | Amount needed | Faucet |
|---|---|---|---|
| Avalanche Fuji (43113) | AVAX | ≥ 5 AVAX | [faucet.avax.network](https://faucet.avax.network/) — `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` |
| Arc Testnet (5042002) | USDC (native gas) | ≥ 15 USDC | [faucet.circle.com](https://faucet.circle.com/) — select Arc Testnet → `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` |
| Base Sepolia (84532) | ETH | ≥ 0.05 ETH (for spoke fleet retest) | [faucet.quicknode.com/base/sepolia](https://faucet.quicknode.com/base/sepolia) |
| Sepolia (11155111) | ETH | ≥ 0.05 ETH (optional) | [faucet.quicknode.com/ethereum/sepolia](https://faucet.quicknode.com/ethereum/sepolia) |

Pre-flight: confirm balances before each stage. Stages 1-4 below total ~3 AVAX on Fuji and ~5 USDC on Arc with comfortable buffer.

---

## 2. Required env in `.env.local` (gitignored)

```bash
DEPLOYER_PRIVATE_KEY=0x…
FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
ARC_TESTNET_RPC=https://rpc.testnet.arc.network
ARC_USDC=0x3600000000000000000000000000000000000000
ARC_EURC=0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a
```

Optional (only if you want to use the existing v1.2.x hub stack instead of deploying a fresh basket-only Oracle/Registry):
```bash
FXT_USDC=<real-USDC-on-this-chain>
FXT_PYTH=<real-Pyth-on-this-chain>
FXT_PRICE_SOURCE=real   # skip MockPyth.setPrice on real Pyth
```

---

## 3. Architecture choice — parallel vs extend

We have two paths for the Phase 3 multi-asset basket (JPYC, MXNB, AUDF, KRW1, ZCHF) on Fuji L1:

### Path A — **parallel basket** (recommended for first run)
Deploy a fresh FxOracle / FxMarketRegistry / FxLiquidator / FxHubMessageReceiver for the basket. The existing v1.2.x USDC/EURC stack at `0xf7fcdca3…` / `0x7ba745b9…` / etc stays untouched.

Pros: clean blast radius. Each pair stands on its own.
Cons: the spoke fleet must know which hub it routes to.

### Path B — **extend** the existing hub
Add JPYC/MXNB/etc as new markets on the v1.2.x registry. Hooks attach to a single oracle.

Pros: single hub, single spoke target.
Cons: existing oracle was deployed pre-PR-6 with deployer-as-owner. Admin shape may not match the new `AccessControl` pattern.

**Path A** is the default for tonight. We'll layer extend later.

---

## 4. Stage-by-stage runbook

### Stage 1 — Fuji L1 basket broadcast (~3 AVAX, ~10 min)

Phased script splits the deploy across 7 forge invocations with 60s sleeps so we don't trip block-builder rate limits.

```bash
cd /Users/criptopoeta/coding-dojo/fx-onchain
export TENDERLY_FUJI_ADMIN_RPC="$FUJI_RPC_URL"
export DEPLOYER_PRIVATE_KEY=…
bash scripts/deploy-tenderly-basket-phased.sh
```

Note: the script's env var is named `TENDERLY_FUJI_ADMIN_RPC` for historical reasons — it accepts any Fuji RPC URL, not just Tenderly. We'll rename in a follow-up.

Outputs:
- `deployments/tenderly-avalanche-fuji-basket.json` — full manifest with all addresses.
- `deployments/_tenderly-basket-phases/phase{1,2-*,3}.json` — per-phase sub-manifests.

Each phase runs:
- Phase 1 (core) — `MockPyth + USDC mock + PoolManager + PoolSwapTest + FxOracle + FxMarketRegistry + FxLiquidator + FxHubMessageReceiver`. ~10 txs, ~30s.
- Phase 2 × 5 (assets) — one per JPYC/MXNB/AUDF/KRW1/ZCHF. Each ~17 txs.
- Phase 3 (handoff) — `FxTimelock + admin role transfers + assert deployer renounced`. ~7 txs.

### Stage 2 — Fuji gateway-wiring smoke against REAL Circle Gateway (~0.1 AVAX, ~1 min)

**Real Circle Gateway is live on Fuji + Arc** at deterministic CREATE2 addresses (confirmed via `circle contract address gateway`):

```
GatewayWallet  0x0077777d7EBA4688BDeF3E311b846F25870A19B9
GatewayMinter  0x0022222ABE238Cc2C7Bb1f21003F0a260052475B
```

Same addresses on both chains. The new smoke `SmokeGatewayWiring.s.sol` deploys a `TelaranaGatewayHubHook` pointed at the real Circle Minter on the current chain and runs **5 in-broadcast probes** that don't need a real Circle-signed attestation:

| Probe | What it asserts |
|---|---|
| A — `setGatewayRoute` | Route config accepted by the hook (real Circle minter + real USDC) |
| B — `gatewayRoute(routeId)` read | Configured slots round-trip correctly |
| C — disabled route | `receiveGatewayMint` reverts when `enabled=false` (short-circuits before minter call) |
| D — Pausable gate | `pause()` blocks entry-side `receiveGatewayMint`; `unpause()` restores |
| E — real-minter call with fake attestation | Circle's real minter rejects the fabricated signature — proves the call **path** is physically wired through Circle |

```bash
cd /Users/criptopoeta/coding-dojo/fx-onchain/contracts
FXT_GATEWAY_DESTINATION_HUB="$(jq -r '.hubStack.FxHubMessageReceiver' ../deployments/hub-config-fuji.json)" \
  forge script script/SmokeGatewayWiring.s.sol:SmokeGatewayWiring \
  --rpc-url "$FUJI_RPC_URL" --broadcast --slow --legacy \
  --private-key "$DEPLOYER_PRIVATE_KEY"
```

The full happy-path mint (deposit-on-source + Circle-signed attestation + real cross-chain mint into our hook) requires the relayer EOA to hold `EXECUTOR_ROLE` on the hook and the depositor to call `circle gateway deposit` on the source chain. That's a separate operator drill — `SmokeGatewayWiring.s.sol` proves the contract-level wiring is in place; the rest is done via the `circle` CLI + the Circle Gateway relayer.

A legacy `SmokeTenderlyGatewayAvaxToArc.s.sol` is preserved for Tenderly-vnet / mock-minter coverage; it tests the happy mint+forward+idempotency logic without needing real Circle infrastructure.

### Stage 3 — Arc Testnet hub (~5 USDC, ~12 min)

Prerequisite: Morpho Blue is **not** deployed on Arc Testnet yet. Per `docs/TODOS.md`, we plan to self-deploy. This is a one-shot Solidity 0.8.19 immutable singleton.

3a — Self-deploy Morpho + AdaptiveCurveIrm:
```bash
cd /Users/criptopoeta/coding-dojo/fx-onchain
# (script to be added: scripts/deploy-morpho-blue-arc.sh)
```

3b — Update `deployments/hub-config-arc.json` with the resulting Morpho address + IRM address.

3c — Run Phase 1-3 on Arc:
```bash
export TENDERLY_FUJI_ADMIN_RPC="$ARC_TESTNET_RPC"    # see naming note above
export FXT_USDC=0x3600000000000000000000000000000000000000   # real USDC on Arc
export FXT_PYTH=0x2880aB155794e7179c9eE2e38200202908C17B43   # real Pyth on Arc
export FXT_PRICE_SOURCE=real
bash scripts/deploy-tenderly-basket-phased.sh
```

(Phase 1 needs a small adapt to accept `FXT_USDC` + skip MockUSDC if set; same for `FXT_PYTH`.)

### Stage 4 — Arc gateway-wiring smoke (~0.5 USDC, ~1 min)

Same `SmokeGatewayWiring.s.sol`, on Arc. The script auto-detects `chainid` and picks the right (sourceDomain, destinationDomain, local USDC) tuple — no flag needed.

```bash
cd /Users/criptopoeta/coding-dojo/fx-onchain/contracts
FXT_GATEWAY_DESTINATION_HUB="<Arc-side FxHubMessageReceiver after Stage 3>" \
  forge script script/SmokeGatewayWiring.s.sol:SmokeGatewayWiring \
  --rpc-url "$ARC_TESTNET_RPC" --broadcast --slow --legacy \
  --private-key "$DEPLOYER_PRIVATE_KEY"
```

Result: Arc-side `TelaranaGatewayHubHook` wired to the same Circle Gateway Minter, route configured for "Fuji → this Arc hub" (sourceDomain=1, destDomain=26).

### Stage 4b — Real cross-chain Gateway USDC flow (end-to-end)

Once both hubs have their gateway hooks wired (Stages 2 + 4), the full hub-to-hub USDC liquidity flow runs via the `circle` CLI on the source side + Circle's relayer on the destination side:

```bash
# Source-side: deposit USDC into Circle Gateway Wallet on Fuji.
circle gateway deposit --chain AVAX-FUJI --amount 5

# Wait for the relayer to sign the attestation (Circle's API).
# Then the relayer EOA (must hold EXECUTOR_ROLE on the destination hook)
# calls receiveGatewayMint on the Arc-side hook with the real attestation.

# Status check during the flow:
circle gateway balance --chain AVAX-FUJI
circle gateway balance --chain ARC-TESTNET
```

The destination hook's `receiveGatewayMint` calls Circle's real GatewayMinter; on a real attestation the mint lands, the hook forwards USDC to the configured destination hub (the `FxHubMessageReceiver`), and the receipt records under `gatewayRequestState(requestId) == MINTED`.

**This is the Spider Web's hub-to-hub leg.** Spokes feed USDC into either hub via CCTP V2; hubs share liquidity via Circle Gateway.

### Stage 5 — Spoke fleet retest (optional, ~0.1 ETH per chain)

Existing spokes on Base Sepolia, Unichain Sepolia, Sepolia, OP Sepolia, Arbitrum Sepolia, Polygon Amoy, WorldChain Sepolia, Arc Testnet (in `deployments/*.json`) currently route to the v1.2.x Fuji hub at `0x365de300…4362`. After Stage 1 there's a new basket FxHubMessageReceiver — spokes need re-pointing OR we deploy parallel spokes per hub. See PR follow-up.

### Stage 6 — Ghost Mode end-to-end (privacy)

Status: spoke router + commitment registry + withdrawal scaffold exist (see `contracts/src/ghost/`). Production ZK verifier is not yet deployed — see `docs/TODOS.md` Phase 1 §1.

Reachable tonight: deploy the Ghost spoke router + commitment registry on each spoke chain pointing at the basket hub. Synthetic-proof withdrawal can be smoked with the mock verifier already in tests. Real ZK proof generation needs a circuit + prover — out of scope tonight.

---

## 5. Verification matrix

After each stage, verify:

| Stage | Verification |
|---|---|
| 1 | `cast call <FxOracle> "maxOracleAge()(uint256)" --rpc-url $FUJI_RPC_URL` → 300. Snowtrace shows all 30+ contracts created. |
| 1 | `cast call <FxOracle> "hasRole(bytes32,address)(bool)" 0x000…000 <FxTimelock> --rpc-url $FUJI_RPC_URL` → `true` (deployer renounced post-Phase 3). |
| 2 | `cast call <TelaranaGatewayHubHook> "gatewayRequestState(bytes32)(uint8)" <requestId_A> --rpc-url $FUJI_RPC_URL` → 1 (MINTED). |
| 2 | `cast call <USDC> "balanceOf(address)(uint256)" <FxHubMessageReceiver_basket> --rpc-url $FUJI_RPC_URL` → ≥ 100e6 (the smoke's amountA). |
| 3 | Same as Stage 1 but on Arc. Arcscan shows the basket stack. |
| 4 | Same as Stage 2 but on Arc. |

---

## 6. Honest caveats

**What we CAN test on real testnets tonight:**
- Full Phase 3 basket deploy + admin handoff on Fuji L1.
- Gateway hook + mock minter on both hubs (proves the destination-hub mint+forward logic).
- Per-pair oracle + market + receipt + hook creation.
- Cross-chain spoke entry via real CCTP V2 (Circle's testnet attestation service is live).

**What we CANNOT test fully tonight (depends on upstream):**
- Real Circle Gateway happy-path mint requires Circle's relayer signing a deposit attestation. The contract wiring is complete (`SmokeGatewayWiring.s.sol` Probe E exercises the call path against the real minter); the cross-chain end-to-end runs via `circle gateway deposit` from a depositor + Circle's relayer pushing a signed attestation to an `EXECUTOR_ROLE` holder on the destination hook.
- Real ZK proof generation for Ghost withdrawals. Mock proof verifier is wired; real circuit + prover are Phase 1+ work per `docs/TODOS.md`.
- v4 Universal Router quote/swap path through the new hooks — needs UR deployment on Fuji + Arc (separate ask).

**Risk surface:**
- Self-deploying Morpho on Arc Testnet — straightforward (immutable singleton ~3KB) but irreversible. Stick to Morpho v1.1 source matched against Ethereum mainnet bytecode.
- Per CLAUDE.md, Morpho on Fuji is already self-deployed by `0x0646…eC69`. Verify deployer still has IRM/LLTV enable rights before Phase 1's `_ensureMorphoConfig` runs.

---

## 7. Push to PR after success

```bash
cd /Users/criptopoeta/coding-dojo/fx-onchain
git add deployments/tenderly-avalanche-fuji-basket.json \
        deployments/_tenderly-basket-phases/ \
        deployments/arc-l1-basket.json \
        deployments/hub-config-arc.json \
        reports/SPIDER_WEB_LIVE_<DATE>.md
git commit -m "feat(spider-web): live Fuji L1 + Arc basket deploy + gateway smoke"
git push origin codex/frontend-handoff-avalanche-fx
gh pr comment 5 --body "Live broadcast complete. See reports/SPIDER_WEB_LIVE_<DATE>.md"
```
