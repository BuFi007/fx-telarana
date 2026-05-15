# Mainnet Hub Deployment Plan — fx-Telaraña on Avalanche (with Arc testnet)

**Status:** Mainnet launch readiness plan. Companion to `SPEC_PHASE_3_MULTI_STABLECOIN.md`.
**Author:** Claude, 2026-05-14.
**Scope:** Hub on **Avalanche C-Chain mainnet** (primary), Arc testnet for StableFX-compatible dev environment, Fuji for cheap testnet iteration, Arc mainnet as future migration target.
**Constraint:** Final "swap mocks for real contracts" step is a deploy-script env-var change, not a refactor.

---

## 0. Headline strategy

1. **Hub = Avalanche C-Chain mainnet.** Decisive reason: 5+ of the 7 basket stablecoins are native on Avalanche today (JPYC, MXNB, KRW1, AUDF, ZCHF-via-CCIP). Morpho Blue is live. CCTP V2 is live (Domain 1). Real contracts beat mocks for institutional and hackathon demos.
2. **Testnet hubs = Arc testnet + Avalanche Fuji.** Arc testnet for the StableFX-compatible dev environment (Permit2, FxEscrow, USDC-as-gas semantics). Fuji for cheap fast iteration. Existing Fuji hub migration plumbing (`bbb0302`, `ccb1568`) is the starting point.
3. **Spokes = every CCTP V2 chain.** Spokes are thin: CCTP V2 burn-and-mint of USDC into the Hub, plus stranded-deposit recovery. Existing `FxSpoke` contract handles this. Arc, Base, Ethereum, Polygon, Arbitrum, Optimism, Unichain all eligible.
4. **Local stablecoins live on the Hub.** Users don't bridge JPYC / MXNB / BRLA cross-chain. They send USDC from any spoke → Hub mints local stablecoin liquidity via Morpho borrow → FX swap → return USDC via CCTP.
5. **Testnet uses mocks for what's missing.** Most basket stablecoins are not on Arc testnet, so `MockStablecoin` instances fill the gap there. Avalanche Fuji can use mainnet-bridged or mocked variants depending on issuer cooperation. Mainnet uses issuer-canonical addresses.
6. **No new contracts.** Every contract used is already on the §2 whitelist of `SPEC_PHASE_3_MULTI_STABLECOIN.md`. This doc is deployment plumbing only.

### 0.1 Why Avalanche over Arc / Base for v1

| Factor | Avalanche C-Chain | Arc mainnet | Base mainnet |
|---|---|---|---|
| Basket native coverage | **5-6 of 7** | 0 (no mainnet yet) | 2-3 of 7 |
| Morpho Blue available | ✅ | ❌ (not deployed) | ✅ |
| CCTP V2 live | ✅ Domain 1 | ✅ Domain 26 (testnet only) | ✅ Domain 6 |
| Pyth + RedStone | ✅ both | partial | ✅ both |
| StableFX integration | ❌ (Arc only) | ✅ when GA | ❌ |
| Hackathon timing fit | ✅ Avalanche hackathon | ❌ mainnet not ready | ❌ |
| Time-to-mainnet | weeks | months | weeks |
| USDC-as-gas | ❌ (AVAX gas) | ✅ | ❌ (ETH gas) |

**Trade-off accepted:** lose StableFX direct-rail integration in v1. Pasillo (separate repo, per `.context/PASILLO_HANDOFF_USYC_KYB_INSTITUTIONAL.md`) still routes institutional flow to StableFX on Arc as a parallel rail. The protocol stays permissionless DeFi on Avalanche.

**Future:** Arc mainnet, when GA, becomes either (a) a *spoke* into the Avalanche Hub, or (b) a second Hub for a StableFX-native institutional product. Hub-and-spoke architecture supports both — decision deferred to when Arc ships.

---

## 1. Arc testnet — confirmed contracts (deploy targets)

Source: `.context/attachments/pasted_text_2026-05-14_18-32-45.txt` (Arc Testnet contract addresses, official Circle/Arc docs).

### 1.1 Stablecoins (live on Arc testnet)

| Asset | Address | Decimals | Notes |
|---|---|---|---|
| USDC | `0x3600000000000000000000000000000000000000` | 6 (ERC-20) / 18 (native gas) | Native gas token on Arc. Faucet at faucet.circle.com. |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | 6 | Faucet at faucet.circle.com (select Arc Testnet). |
| USYC | `0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C` | 6 | **Gated** — KYB allowlist via Circle Support ticket, 24-48h. Not used in this protocol; flagged for Pasillo. |
| USYC Entitlements | `0xcc205224862c7641930c87679e98999d23c26113` | n/a | Allowlist registry contract. Pasillo concern. |
| USYC Teller | `0x9fdF14c5B14173D74C08Af27AebFf39240dC105A` | n/a | Mint/redeem USYC from USDC. Pasillo concern. |

### 1.2 CCTP V2 (Arc testnet — Domain 26)

| Contract | Address |
|---|---|
| TokenMessengerV2 | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` |
| MessageTransmitterV2 | `0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275` |
| TokenMinterV2 | `0xb43db544E2c27092c107639Ad201b3dEfAbcF192` |
| MessageV2 | `0xbaC0179bB358A8936169a63408C8481D582390C4` |

### 1.3 Other infrastructure (Arc testnet)

| Contract | Address | Notes |
|---|---|---|
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Canonical, same across EVM. Required for FxRouter (Phase 2.6R). |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` | Batched read aggregation. |
| CREATE2 Factory (Arachnid) | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | Deterministic deploys. |
| StableFX FxEscrow | `0x867650F5eAe8df91445971f14d89fd84F0C9a9f8` | Reference only — Pasillo integrates this, fx-Telaraña does not. |
| Gateway Wallet | `0x0077777d7EBA4688BDeF3E311b846F25870A19B9` | Circle's chain-abstracted USDC. Reserved for future use. |
| Gateway Minter | `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B` | Same. |

### 1.4 Missing on Arc (require mocks for testnet OR await issuer)

| Asset | Status on Arc | Action |
|---|---|---|
| JPYC | Not deployed | **Deploy MockJPYC (18 dec)** on Arc testnet. |
| BRLA | Not deployed | **Deploy MockBRLA (18 dec)** on Arc testnet. |
| MXNB | Not deployed | **Deploy MockMXNB (6 dec)** on Arc testnet. |
| AUDF | Not deployed | **Deploy MockAUDF (6 dec)** on Arc testnet. |
| PHPC | Rumored | Confirm before relying on it; otherwise **deploy MockPHPC (6 dec)**. |
| ZCHF | Not deployed | **Deploy MockZCHF (18 dec)** on Arc testnet. |
| KRW1 | Pending BDACS reply | Wait for reply; otherwise mock when adding pair. |
| Morpho Blue | Not deployed | Confirmed blocker. Either wait or self-deploy (immutable singleton, ~3KB). |
| AdaptiveCurveIRM | Not deployed | Same — co-deploy with Morpho self-deploy if going that route. |
| Pyth | Confirm per pair | Pyth `0x2880aB155794e7179c9eE2e38200202908C17B43` per `project-fx-telarana` memory — verify each FX pair feed is live on Arc. |
| RedStone | Confirm signer set | Verify production signer set publishes Arc-targeted payloads. |

---

## 2. Mainnet target addresses (per asset, per chain)

Source: Tomás's mainnet stablecoin reference (`.context/attachments/pasted_text_2026-05-14_18-33-11.txt`).

**Important:** Arc mainnet addresses for Circle infrastructure (USDC, EURC, CCTP V2) are **not yet published**. This plan is for the moment they go live; the deploy script reads them from env vars.

### 2.1 Stablecoins — per-chain mainnet addresses

| Asset | Ethereum | Polygon | Avalanche | Arbitrum | Base | Optimism | Other |
|---|---|---|---|---|---|---|---|
| **USDC** | `0xA0b8...EB48` | `0x3c49...4174` | `0xB97E...e33E` | `0xaf88...8831` | `0x8335...2913` | `0x0b2C...3B85` | Per CCTP chain list |
| **EURC** | `0x1aBa...C3a8` | tbd | tbd | tbd | `0x60a3...9DA0` | tbd | Arc mainnet pending |
| **AUDF** | `0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b` | same | same | — | same | — | Redbelly: same |
| **BRLA** | pending | `0xe6a537a407488807f0bbeb0038b79004f19dddfb` | — | — | pending | — | Celo/Moonbeam/Gnosis pending |
| **JPYC** | `0x431D5dfF03120AFA4bDf332c61A6e1766eF37BDB` | same | same | — | — | — | — |
| **KRW1** | pending | pending | `0x25a8ef2df91f8ee0a98f261f4803a6eab5ff0318` | — | — | — | Plume: `0x8304d1b1d04c968270ae66a0c7758f7471b8ec3f` |
| **MXNB** | `0xF197FFC28c23E0309B5559e7a166f2c6164C80aA` | — | same | same | — | — | — |
| **PHPC** | — | `0x87a25dc121Db52369F4a9971F664Ae5e372CF69A` | — | — | — | — | Ronin pending |
| **ZCHF** (native) | `0xB58E61C3098d85632Df34EecfB899A1Ed80921cB` | — | — | — | — | — | — |
| **ZCHF** (CCIP-bridged) | — | `0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553` | same | same | same | same | Gnosis/Sonic: same |

**Fill in USDC + EURC mainnet rows from Circle's canonical addresses page (https://developers.circle.com/stablecoins/usdc-contract-addresses) at deploy time** — do not hardcode here, they shift across chain expansions.

### 2.2 CCTP V2 mainnet (per chain, when domains confirmed)

CCTP V2 domain IDs — confirm against Circle's mainnet docs at deploy time. Domains do NOT match chain IDs:

| Chain | CCTP V2 Domain | TokenMessenger | MessageTransmitter |
|---|---|---|---|
| Ethereum | 0 | per Circle docs | per Circle docs |
| Avalanche | 1 | per Circle docs | per Circle docs |
| Optimism | 2 | per Circle docs | per Circle docs |
| Arbitrum | 3 | per Circle docs | per Circle docs |
| Base | 6 | per Circle docs | per Circle docs |
| Polygon | 7 | per Circle docs | per Circle docs |
| Unichain | 10 | per Circle docs | per Circle docs |
| Arc | 26 (testnet, confirm mainnet) | pending | pending |

**Source the addresses programmatically** from Circle's docs at deploy time. Hardcoding rotates with chain additions and creates deploy-time drift.

---

## 3. Mock testnet strategy

### 3.1 Mock contracts (NEW — minimal)

`contracts/src/test-helpers/MockStablecoin.sol` — single parameterized contract:

```solidity
// Use OZ ERC20 + ERC20Burnable + ERC20Permit (EIP-2612).
// Constructor params: name, symbol, decimals, initialMint, owner.
// Public mint() for testnet faucet access (gated to owner OR open per deploy env flag).
contract MockStablecoin is ERC20, ERC20Burnable, ERC20Permit, Ownable {
    uint8 private immutable _decimals;
    bool  public faucetOpen;          // testnet only
    uint256 public constant FAUCET_AMOUNT = 1_000 * 10**18; // adjusted per decimals at mint

    constructor(string memory n, string memory s, uint8 d, address owner_)
        ERC20(n, s) ERC20Permit(n) Ownable(owner_) { _decimals = d; }

    function decimals() public view override returns (uint8) { return _decimals; }
    function mint(address to, uint256 amount) external onlyOwner { _mint(to, amount); }
    function faucet() external {
        require(faucetOpen, "faucet closed");
        _mint(msg.sender, FAUCET_AMOUNT / (10 ** (18 - _decimals)));
    }
    function setFaucetOpen(bool v) external onlyOwner { faucetOpen = v; }
}
```

**Why this is allowed under "no new contracts" rule:** test helper, deployed under `test-helpers/`, never reachable from mainnet deploy script. It's audit-line zero risk surface. Extends OZ audited primitives.

### 3.2 Mock deployment instances on Arc testnet

| Symbol | Name | Decimals | Mock purpose |
|---|---|---|---|
| `mAUDF` | "Mock AUDF (test)" | 6 | Stand in for Forte AUDF on Arc testnet. |
| `mBRLA` | "Mock BRLA (test)" | 18 | Stand in for Avenia BRLA on Arc testnet. |
| `mJPYC` | "Mock JPYC (test)" | **18** | **Mirror mainnet 18-dec, NOT Sepolia 6-dec.** |
| `mKRW1` | "Mock KRW1 (test)" | TBD | Confirm KRW1 mainnet decimals first. |
| `mMXNB` | "Mock MXNB (test)" | 6 | Stand in for Bitso/Juno MXNB. |
| `mPHPC` | "Mock PHPC (test)" | 6 | Stand in for Coins.PH PHPC. |
| `mZCHF` | "Mock ZCHF (test)" | 18 | Stand in for Frankencoin ZCHF. |

Deploy script: `contracts/script/DeployArcTestnetMocks.s.sol`. Logs all addresses to `deployments/arc-testnet-mocks.json`.

### 3.3 Mock-to-real switching

The Hub deploy script reads stablecoin addresses from env vars per chain. Testnet env points to mock addresses; mainnet env points to real issuer addresses. Switching is a deploy-config change, no contract change:

```bash
# Arc testnet (current)
export FXT_TOKEN_AUDF=$(jq -r .mAUDF deployments/arc-testnet-mocks.json)
export FXT_TOKEN_BRLA=$(jq -r .mBRLA deployments/arc-testnet-mocks.json)
# ...

# Arc mainnet (future)
export FXT_TOKEN_AUDF=0xd2a530170D71a9Cfe1651Fb468E2B98F7Ed7456b   # Forte
export FXT_TOKEN_BRLA=0x<once-Avenia-deploys-on-Arc-mainnet>
# ...
```

### 3.4 Mock oracle handling

For testnet pairs that use mocks, we need a mock-friendly Pyth/RedStone path. Two options:

- **Option A (preferred):** still use real Pyth on Arc testnet (assuming feed exists). Mock stablecoin price tracks the real-world rate. This is most realistic.
- **Option B (fallback):** add `MockOracle.sol` (extends `IFxOracle`) that returns admin-set prices. Use only when real Pyth feed not available on Arc testnet for that FX pair.

Pre-deploy check per pair: confirm Pyth feed exists on Arc testnet. If yes → Option A. If no → log to `BLOCKED_PAIRS.md` and use Option B for development only; production deploy waits for real feed.

---

## 4. Hub deployment matrix

### 4.1 Hub-chain options

| Hub chain | Status | Use case |
|---|---|---|
| **Avalanche C-Chain mainnet** | 🎯 **Primary production target** | All v1 mainnet flow. JPYC/MXNB/KRW1/AUDF/ZCHF native; Morpho live; CCTP V2 Domain 1. Avalanche hackathon launchpad. |
| **Avalanche Fuji** | ✅ Migrated (`bbb0302`) | Cheap testnet iteration, mirrors mainnet. Use for pre-mainnet rehearsals. |
| **Arc testnet** | ✅ Available | StableFX-compatible dev environment. Useful for the integrator surface tests (Permit2 + FxEscrow shape + USDC-as-gas). Not production. |
| **Base Sepolia** | ✅ Legacy testnet hub | Original Phase 0-2 work. Kept running for backward compatibility; new work targets Fuji or Arc testnet. |
| **Tenderly vnet** | ✅ Always-on | Forked from current hub chain for fast iteration. Primed-state recommended. |
| **Arc mainnet** | ⏳ Future | When Arc GA + Morpho-on-Arc + StableFX-on-Arc all converge. Migration target as either (a) spoke into Avalanche Hub, or (b) second institutional Hub. |
| **Base mainnet** | ❌ Skipped | Lower basket coverage (2-3 of 7); not pursued for v1. |

### 4.2 Hub contracts to deploy (no changes — same set as today)

| Contract | Purpose | Already audited? |
|---|---|---|
| `FxOracle` | Pyth + RedStone deviation-gated price reads | Internal review |
| `MorphoOracleAdapter` | Adapts IFxOracle for Morpho Blue's `IOracle` interface | Internal |
| `FxMarketRegistry` | Pool discovery + per-asset risk params | Internal |
| `FxLiquidator` | Liquidation routing | Internal |
| `FxReceipt` | LP receipt token (ERC-4626 wrapper) | Internal |
| `FxSwapHook` | Per-pair Uniswap v4 hook (one instance per pair) | Pre-mainnet audit pending |
| `FxHubMessageReceiver` | CCTP V2 hook callback on Hub side | Internal |
| `FxRouter` | Phase 2.6R signed-intent entry (deployed once, multi-pair) | Pre-mainnet audit pending |

Total: 8 core contracts + N hook instances (one per pair). Same as already-deployed Base Sepolia stack, plus FxRouter.

### 4.3 Deploy order

1. `FxOracle` → register Pyth feed IDs + RedStone signer set per pair.
2. `MorphoOracleAdapter` → wraps FxOracle for Morpho.
3. `FxMarketRegistry` → initial per-asset risk params (conservative).
4. `FxLiquidator` + `FxReceipt` → liquidation + receipt token.
5. Per pair: deploy `FxSwapHook` (HookMiner for v4 perm bits), create 2 Morpho markets via `Morpho.createMarket()`.
6. `FxHubMessageReceiver` → registered with Hub-side CCTP V2 MessageTransmitter.
7. `FxRouter` → register all pair pool keys via `setPairAllowed`.
8. Transfer admin to Compound Timelock per `script/Deploy.s.sol` pattern (existing).
9. Register all contracts with Circle SCP via `bun run sdk:circle:register`.
10. Update `packages/sdk/src/addresses/index.ts` under `ChainId.ArcMainnet`.

---

## 5. Spoke deployment matrix

Spokes are thin — each chain that holds a stablecoin we route to, OR is a major USDC entry point, gets a `FxSpoke` deployment.

### 5.1 Spoke priorities (chains)

Order by usefulness for the basket:

| Chain | Why | Stablecoins exposed | CCTP V2 status |
|---|---|---|---|
| **Ethereum** | All 5 of AUDF/JPYC/MXNB/ZCHF native + Brazil pending | AUDF, JPYC, MXNB, ZCHF native | ✅ Live |
| **Polygon** | BRLA mainnet, JPYC, AUDF, PHPC, ZCHF (CCIP) | BRLA, JPYC, AUDF, PHPC, ZCHF | ✅ Live |
| **Avalanche** | JPYC, MXNB, KRW1, AUDF, ZCHF (CCIP) | JPYC, MXNB, KRW1, AUDF, ZCHF | ✅ Live |
| **Arbitrum** | MXNB, ZCHF (CCIP) | MXNB, ZCHF | ✅ Live |
| **Base** | AUDF, ZCHF (CCIP), USDC depth | AUDF, ZCHF | ✅ Live (current spoke) |
| **Optimism** | ZCHF (CCIP) | ZCHF | ✅ Live |
| **Unichain** | USDC entry point, low fees | — | ✅ Live (current spoke) |
| **Plume** | KRW1 | KRW1 | Confirm CCTP V2 status |
| **Solana** | If ZARU/KRW1/JPYC SPL emerge | Future | ✅ Live (Spoke-only model) |

### 5.2 What changes per spoke

Nothing in the spoke contract. It's chain-agnostic — burns USDC via CCTP V2 to the Hub, receives USDC back via CCTP V2. **Local stablecoins are never bridged.** They exist on the Hub, get FX'd there, and the user receives the *output* (USDC) back via CCTP V2.

**This means:** even though JPYC lives on Ethereum + Polygon + Avalanche, the protocol only needs JPYC on the **Hub** (Arc). Spokes don't touch local stablecoins.

### 5.3 Spoke deploy commands (extend existing `SPOKE_DEPLOY.md`)

Pattern is already documented for Unichain Sepolia + Avalanche Fuji. Extend for each new chain. Per-spoke needs:
- Faucet drip for the deployer EOA (`0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69`).
- Source `.env.local` with HUB_RECEIVER + HUB_DOMAIN set to Arc mainnet values.
- `forge script` with the spoke's RPC.
- Persist to `deployments/<chain>.json`.

---

## 6. Pre-mainnet checklist (extends `PRE_DEPLOY_CHECKLIST.md`)

In addition to existing items in `PRE_DEPLOY_CHECKLIST.md`:

### 6.1 Hub readiness (Avalanche C-Chain mainnet — PRIMARY)

- [ ] Avalanche C-Chain mainnet addresses recorded in env vars (USDC, USDC-native if any, Permit2 canonical, CCTP V2 TokenMessenger + MessageTransmitter Domain 1).
- [ ] Morpho Blue on Avalanche confirmed live with `enableIrm` + `enableLltv` for our chosen AdaptiveCurveIRM + 86% LLTV (or per-asset override).
- [ ] Pyth Network on Avalanche, feed IDs confirmed for: EUR/USD, JPY/USD, BRL/USD, MXN/USD, AUD/USD, CHF/USD, KRW/USD (Tier 1-3 + KRW1 ready set).
- [ ] RedStone production signer set publishing on Avalanche for same pairs.
- [ ] Issuer-canonical stablecoin addresses verified on-chain via `cast call <addr> "decimals()"` + `symbol()`: AUDF, JPYC, MXNB, KRW1, ZCHF.
- [ ] Smart-contract audit complete (CertiK or Spearbit) for FxSwapHook + FxRouter + adapter layer. Findings remediated.
- [ ] Avalanche-specific gas accounting: deployer EOA funded with AVAX; document AVAX-vs-USDC-gas UX in product copy.

### 6.1.a Arc mainnet readiness (FUTURE, when GA)

- [ ] Arc mainnet GA confirmed by Circle.
- [ ] Arc mainnet USDC + EURC + Permit2 + CCTP V2 addresses published. Recorded in env vars.
- [ ] Morpho Blue deployed to Arc mainnet (either by Morpho Labs or our self-deploy).
- [ ] Pyth Network deployed to Arc mainnet, with feed IDs confirmed for Tier 1-3 pairs.
- [ ] RedStone production signer set confirmed publishing on Arc mainnet for same pairs.
- [ ] **Decision:** Arc as spoke into Avalanche Hub OR Arc as second institutional Hub (StableFX-native). Defer until Arc GA.

### 6.2 Per-pair readiness (per Tier 1 anchor — JPYC, BRLA)

- [ ] Local stablecoin contract address confirmed on Arc mainnet (issuer-deployed) OR mock-substitution decision logged.
- [ ] Issuer contacted, communication channel established for incident response.
- [ ] Pyth + RedStone feeds verified for the pair.
- [ ] Risk params set in `FxMarketRegistry`: cap $1M initial, lltv 80%, fee 5-15 bps, max oracle deviation 50 bps.
- [ ] Morpho markets created (both directions), market IDs recorded.
- [ ] FxSwapHook deployed at HookMiner-mined address, permission bits verified.
- [ ] Pool seeded with treasury LP (anti-share-inflation hygiene).
- [ ] Tenderly vnet smoke test against forked Arc mainnet: deposit, swap both directions, redeem.

### 6.3 Spoke readiness (per chain)

- [ ] CCTP V2 mainnet addresses confirmed for that chain.
- [ ] Deployer EOA funded with chain-native gas (Polygon: MATIC; Avax: AVAX; Ethereum: ETH; etc.).
- [ ] HUB_RECEIVER + HUB_DOMAIN env vars updated to Arc mainnet values.
- [ ] `deployments/<chain>.json` template ready.
- [ ] Faucet/funding drip path documented for ongoing ops (if relayer-funded).

### 6.4 Governance + ops

- [ ] Compound Timelock deployed on Arc mainnet (vendor sub-project 0.5.16 build path).
- [ ] Multisig (Safe / Circle Modular Wallet) configured with 3-of-5 ops members.
- [ ] Admin transfer atomic in `script/Deploy.s.sol` — post-condition asserts succeed.
- [ ] Pause + emergency-stop runbook in `docs/INCIDENT_RESPONSE.md` (new doc — create if missing).
- [ ] On-call rotation defined.

### 6.5 Monitoring

- [ ] Circle SCP event monitors set up for: `DepositStranded`, `DepositSwept`, `OracleDeviation`, `MarketRegistered`, `Entered`, `Exited`, `IntentExecuted`, `Pause`.
- [ ] Tenderly Alerts as redundant notification path.
- [ ] Pyth / RedStone feed-staleness monitor (off-chain, alerts if either feed > 5 min stale).
- [ ] Per-pair TVL + utilization dashboard published.

---

## 7. Testnet mock deploy sequence (do this first, before mainnet thinking)

This is the immediate work. Mainnet waits on Arc GA + Circle publishing addresses + Morpho Arc deploy.

### 7.1 Mock token deploy (Arc testnet)

1. Implement `contracts/src/test-helpers/MockStablecoin.sol` per §3.1.
2. Implement `contracts/script/DeployArcTestnetMocks.s.sol` deploying all 6-7 mocks (mAUDF, mBRLA, mJPYC, mMXNB, mPHPC, mZCHF, optionally mKRW1).
3. `forge script ... --broadcast` against Arc testnet RPC.
4. Log addresses to `deployments/arc-testnet-mocks.json`.
5. Update `packages/sdk/src/addresses/index.ts` `ChainId.ArcTestnet.tokens` map to include mock addresses.

### 7.2 Hub deploy on Arc testnet (once Morpho available)

1. Resolve Morpho Blue Arc testnet (await Morpho Labs OR self-deploy via `vendor/morpho-blue-deployment/`).
2. Run existing `DeployArcTestnet.s.sol` with env pointing to:
   - Real USDC (`0x3600...0000`)
   - Real EURC (`0x89B5...D72a`)
   - Mock JPYC/BRLA/MXNB/AUDF/PHPC/ZCHF addresses
   - Real Pyth + RedStone (if feeds confirmed)
   - Real CCTP V2 (Domain 26)
   - Real Permit2 (canonical)
3. Per pair, run the §3.2 onboarding playbook from `SPEC_PHASE_3_MULTI_STABLECOIN.md`.
4. Smoke-test each pair end-to-end via Tenderly vnet forked from Arc testnet.
5. 14-day clean monitoring window.

### 7.3 Faucet setup

- Mock contracts have `faucet()` method open on testnet (gate via owner before mainnet).
- Test users `cast send <mockAddr> "faucet()"` to receive 1000 units (decimal-adjusted).
- Document in `docs/TESTNET_USAGE.md` (new doc).

---

## 8. Mainnet launch sequence (Avalanche C-Chain)

Triggered when all checkboxes in §6.1 are green. Estimated path:

1. **Week T-2:** Final audit findings closed, address book frozen.
2. **Week T-1:** Tenderly vnet forked from Avalanche mainnet, full deploy dry-run, gas accounting confirmed (AVAX-denominated).
3. **Week T:**
   - Day 0: Deploy hub contracts to Avalanche mainnet via `script/DeployAvalancheMainnet.s.sol` (NEW — to be authored, mirroring `DeployAvalancheFuji.s.sol` with mainnet env). Transfer admin to Timelock atomically. Verify on Snowtrace.
   - Day 0: Register with Circle SCP. Set event monitors.
   - Day 0: Deploy spoke contracts to Ethereum, Polygon, Arbitrum, Base, Optimism, Unichain (and Arc when its mainnet ships) in parallel.
   - Day 1: Deploy FxSwapHook for USDC↔JPYC (anchor pair #1, Tier 1 — real JPYC `0x431D…7BDB` on Avalanche).
   - Day 2: Deploy FxSwapHook for USDC↔MXNB (Tier 2, real MXNB `0xF197…C80aA` on Avalanche). Wait on BRLA until Avenia confirms Avalanche deploy; otherwise route through a Polygon spoke that bridges into Hub.
   - Day 3-14: Closed beta — protocol team only, $25k cap per pool, watch for any oracle / Permit2 / hook anomaly.
   - Day 14+: Open public access. Cap raised to $1M per pool. Monitor.
4. **Week T+4:** First risk-param relax (if clean). Caps to $5M, lltv potentially loosened by 2-4%.
5. **Week T+8:** Wave 2 deploy (AUDF, KRW1, ZCHF — all natively on Avalanche).
6. **Week T+16:** Wave 3 deploy: BRLA (if Avenia mainnet ships), PHPC (when Coins.PH expands beyond Polygon), or stay Hub-only with bridged variants.

### 8.1 BRLA + PHPC fallback path

Both currently mainnet-only on Polygon. Two options:
- **Wait** for issuer to deploy on Avalanche (preferred — cleanest custody).
- **Use a Polygon spoke** that lets users deposit BRLA-on-Polygon → spoke-side bridge swap → USDC via CCTP V2 to Hub → Hub holds USDC, executes FX as if BRLA. This loses the "BRLA-native borrow market" feature but enables BRL FX flow immediately.

Recommend: **wait if expected < 8 weeks; spoke-bridge variant otherwise.**

---

## 9. What we are NOT doing in this plan

- ❌ Bridging local stablecoins cross-chain. Local stables live on Hub. Period.
- ❌ Integrating Chainlink CCIP (ZCHF's bridging mechanism). ZCHF is a single-chain pair on the Hub.
- ❌ Deploying USYC integration. KYB-gated, Pasillo concern, see handoff doc.
- ❌ Integrating QCAD legacy. Wait for post-relaunch contract.
- ❌ Integrating ZARU. Solana-only, out of scope.
- ❌ Self-deploying any stablecoin. We use issuer-canonical addresses or mocks for testnet.
- ❌ Hardcoding mainnet addresses. All from env vars resolved at deploy time.

---

## 10. Open questions for project owner

1. **Arc mainnet timeline.** Circle has not published Arc mainnet GA date. What's the operational plan if it slips to Q4 2026 or beyond? Ship to Base mainnet instead, then migrate? Or wait?
2. **Morpho Arc deploy.** Self-deploy or wait for Morpho Labs? Self-deploying is fast (~3KB immutable singleton) but adds an audit-line for *our* deployment (vs. Morpho's blessed one). My recommendation: wait if delay < 6 weeks; self-deploy if longer.
3. **KRW1 decimals.** Not specified in Tomás's reference. Need confirmation from BDACS before mock deploy.
4. **PHPC on Arc.** "Rumored" — chase Coins.PH for confirmation before we mock.
5. **Per-pair launch cap.** Default $1M conservative — confirm or adjust based on Pasillo's institutional pipeline.
6. **Audit firm.** CertiK (used for similar protocols) vs Spearbit (deeper review) vs Sherlock contest. Recommend Spearbit + a Sherlock contest before mainnet.

— end of deploy plan —
