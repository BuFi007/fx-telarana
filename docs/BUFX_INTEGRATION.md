# BUFX ↔ FX Telaraña Integration Reference

Live addresses + interfaces for the BUFX perp/spot layer to integrate with the
Telaraña borrow/lend substrate.

**Repo split:** Telaraña is the money-market substrate (this repo). BUFX is the
spot+perp execution layer (separate repo). They share state via the addresses and
contracts below.

---

## Live deployments

### Avalanche Fuji — PRIMARY HUB (chainId 43113, CCTP V2 domain 1, Gateway domain 1)

User deposits can route here via the Fuji-routed CCTP V2 spokes. Each spoke
chain now also has an Arc-routed spoke, so the user or integrator must choose
the destination hub per intent.

| Contract | Address |
|---|---|
| `FxSpoke` (local, Fuji-side entry) | `0x6EC2197aC1c35Fbe64533101a3DFf081BD45Ed99` |
| `FxSpokeToArc` (Fuji -> Arc entry) | `0x225cca22879593b41c7dcceb9e961b7881061368` |
| **`FxHubMessageReceiver` (Stage 6)** | **`0xbBc9AE9dbd3F6D3dB672F0CA2419d0f4C8513062`** |
| **`FxGatewayHook` (Stage 6)** | **`0x1527f0230e07B202812A0F0E437995323A1a98cB`** |
| `FxMarketRegistry` | `0x9316246c42436ad74d81c8f5c9b295da5f2a8EE9` |
| `FxOracle` | `0x4178F9D64F64eD05C25B0D6284f64522436A2a1F` |
| `FxLiquidator` | `0x113A539625D208b5EcC59f300Be14b9b3508E559` |
| `FxReceiptEURC` (ERC-4626) | `0x971b6ED14521f354eD13d64506Bf47D84E70F4fc` |
| `FxReceiptUSDC` (ERC-4626) | `0x629144FDC1d0A6f9F2B12d9747557Cc508728739` |
| MorphoBlue (self-deployed) | `0xeF64621D41093144D9ED8aB8327eE381ECdB79E6` |
| AdaptiveCurveIrm | `0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA` |
| Circle EURC | `0x5E44db7996c682E92a960b65AC713a54AD815c6B` |
| USDC (Circle) | `0x5425890298aed601595a70AB815c96711a31Bc65` |

Market IDs:
- M1 EURC/USDC: `0x164ab95c126ae7f5227bc5026e66642ea05b41f3ab50d086704bc7f1dd6470a1`
- M2 USDC/EURC: `0x77bae5f5fb07741f0873c163edfa5573e7136cb690bb1deff35aa3e664a37a75`

### Arc Testnet — BASKET + TRADING-EXECUTION HUB (chainId 5042002, CCTP V2 domain 26, Gateway domain 26)

Receives USDC liquidity from Fuji via `FxGatewayHook` (never user-initiated). This
is where high-frequency trading and perp execution should live. Arc also hosts
the basket money-market proof of concept: EURC plus mAUDF/mJPYC/mMXNB/mKRW1/mZCHF
against USDC, both directions.

| Contract | Address |
|---|---|
| `FxSpoke` (Arc -> Fuji) | `0xf93834070e4e4e7ff0e161feca2aeba65c2c6a38` |
| `FxSpoke` (Arc-local) | `0x10b1ddc4a061991d44643893a24b754b8fc0dc98` |
| **`FxHubMessageReceiver` (Stage 6)** | **`0x4FBe4cc4ab09648d65195f5B9490D20D12D49a2c`** |
| **`FxGatewayHook` (Stage 6)** | **`0x412f0CE9cb7697458dF3804d56de259c3e38371B`** |
| `FxMarketRegistry` | `0xdB59d712a3cD19DccD98F5a245302a94d43f9A8c` |
| `FxOracle` | `0x625e2870a94F67F575Ed82678C2c619994721D29` |
| `FxLiquidator` | `0x3DD99ace9ab896C613b47749e6Daae84ceF0433B` |
| `FxReceiptEURC` (ERC-4626) | `0x8A88024AE640B26b082E5D01BF0BDea9e0F89f3d` |
| `FxReceiptUSDC` (ERC-4626) | `0x3b94E6A9Dc100CC390B56D1f0BB6a0B706ad3aAA` |
| MorphoBlue (self-deployed) | `0x3c9b95C6E7B23f094f066733E7797C8680760830` |
| AdaptiveCurveIrm | `0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1` |
| FxTimelock / receiver owner | `0x6b44F29DFf260D4426116c313a83e10f741A5a7a` |
| USDC (Arc native 6-dec form) | `0x3600000000000000000000000000000000000000` |
| EURC (Circle native) | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |

Arc basket market IDs:

| Asset | Token | Asset-loan market | USDC-loan market |
|---|---|---|---|
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | `0xfd39280abf7d487fdacb075964282ef40cfbc05d29f3dd0de33fd106f999e321` | `0xcd92ddbcde6eac8b696f8f55cff1e0a397c43a10b9c5ea62d3a134333961853b` |
| mAUDF | `0x4DeB6B4C83588c987C952858225A4725F6e1B1f2` | `0xdecc6eac359fccc90312bcc10d4e3f041b24499e6f5fc6c9b979c63ed3324827` | `0x30b2b4f9a060a4106af7d648ee2997af663dba4a13a80bdaa3b7dcdd86ad024e` |
| mJPYC | `0xD9eCFc78BDFbD121E8b07Bf96D6E27a1C11C6331` | `0x45af7bde15cc90c3d746c5c33ffe8f841d9a13691d4b61b37488f0728c6d3c4b` | `0x85bd7c3e24560aa9e9e92b38b343f30e7699bd40b5c8623a9da6dddb3fa37c61` |
| mMXNB | `0xdb6EC7E8ad32D2c6fe05c0862d626A84049c24c5` | `0x2a9537d6924829e4885754f4d5bc162540c85215edcd2a617e4b44237ceb5b03` | `0x44cd73ea5727fab16c3f4eeb4e33d61e3679709ec026423a7cedd135b0fd2a9c` |
| mKRW1 | `0x204E306FBc71D876E4F105111bBBB1E8113886C3` | `0x9128daa773043c0356fd98ff060eef6cc149eca6efb55b147c600d62d170d379` | `0x19a08dbc14b7db6dbe151ac2bdc5fb7490acc8e2f95ccb8eea768486c93b0b89` |
| mZCHF | `0xF50D7B5B6699f2D1FB7BCFC80261Ae0fca48396C` | `0x175e4e8d24841d73e51f118e6318e429ff9c772df512de1168a3b8f666647ae3` | `0xa900dd90f3d9e8de4546a2be44c54ff6d0ece155766cd4480e5ec9b20c2e98bb` |

The mock basket is for testnet UI/API integration only. When real issuer
testnet contracts arrive, deploy new Morpho markets; market IDs depend on token
addresses. Per-market receipt wrappers are in
[`deployments/arc-testnet-basket.json`](../deployments/arc-testnet-basket.json)
under `receipt_*`; BUFX should still read live position state from Morpho by
market id.

### Circle Gateway (deterministic CREATE2 — same on every testnet chain)

| Contract | Address |
|---|---|
| `GatewayWallet` (source side, deposits) | `0x0077777d7EBA4688BDeF3E311b846F25870A19B9` |
| `GatewayMinter` (destination side, mints) | `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B` |

### Authority for BurnIntent signing

EOA `0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69` (deployer). Migrates to the local
`FxHubMessageReceiver` contract via EIP-1271 once Circle ships 1271 on Gateway
burn intents (Corey's mid-July 2026 ETA).

---

## Read-only surface (call anytime, no permission)

Everything below is callable from any address — read state, build UIs, generate
trades:

### Per-chain hub state
- `FxMarketRegistry.listPools()` → registered market params
- `FxMarketRegistry.marketIdOf(loanToken, collateralToken)` → Morpho market id
- `FxMarketRegistry.paramsOf(loanToken, collateralToken)` → market config
- `FxMarketRegistry.isPoolLive(loanToken, collateralToken)` → entry-side live flag
- `FxMarketRegistry.MORPHO()` → MorphoBlue address
- `Morpho.position(marketId, account)` → supply shares, borrow shares, collateral
- `Morpho.market(marketId)` → supply/borrow totals
- `FxReceipt{EURC,USDC}.totalAssets() / totalSupply() / balanceOf(account)` → optional ERC-4626 receipt-token share math
- `FxOracle.getMid(base, quote)` → cached mid price and last publish time
- `FxOracle.getMidWithUpdate(base, quote, pythPayload)` payable → fresh Pyth-backed price

### Gateway state (via FxGatewayHook)
- `gatewayBalance()` → USDC currently locked under our authority on this chain
- `gatewayWithdrawalUnlockBlock()` → block at which an in-progress withdrawal becomes withdrawable

---

## Write surface — what BUFX CAN call today

### Borrow / lend (Morpho-Blue-style, via FxMarketRegistry)

BUFX contracts (or BUFX-signed txs) can call the registry directly. Registry
gates direct `withdraw`, `withdrawCollateral`, and `borrow` so `onBehalf` must
equal `msg.sender`. Trusted relayers use `borrowDelegated` after the user has
called `setBorrowDelegate(delegate, true)`. Supply / supplyCollateral / repay
accept arbitrary `onBehalf`.

```solidity
interface IFxMarketRegistry {
    function supply(address loanToken, address collateralToken, uint256 assets, address onBehalf) external returns (uint256 sharesMinted);
    function withdraw(address loanToken, address collateralToken, uint256 shares, address onBehalf, address receiver) external returns (uint256 assetsOut);
    function supplyCollateral(address loanToken, address collateralToken, uint256 collateral, address onBehalf) external;
    function withdrawCollateral(address loanToken, address collateralToken, uint256 collateral, address onBehalf, address receiver) external;
    function borrow(address loanToken, address collateralToken, uint256 assets, address onBehalf, address receiver) external returns (uint256 borrowedShares);
    function borrowDelegated(address loanToken, address collateralToken, uint256 assets, address onBehalf, address receiver) external returns (uint256 borrowedShares);
    function repay(address loanToken, address collateralToken, uint256 assets, address onBehalf) external returns (uint256 sharesBurned);
    function setBorrowDelegate(address delegate, bool allowed) external;
}
```

### FxReceipt (ERC-4626) — supply liquidity for receipt tokens
Standard ERC-4626 surface: `deposit`, `mint`, `withdraw`, `redeem`. Backed by the
Morpho market. BUFX can use these as collateral or yield substrate.

---

## Write surface — what BUFX CANNOT call directly (and why)

### FxGatewayHook (`lockForRemote`, `mintFromRemote`) — go through the hub

**Hub-only.** The `onlyHub` modifier rejects everyone except `FxHubMessageReceiver`
on that chain. This is the deliberate trust boundary: only the protocol moves
USDC across hubs, never users (or BUFX) directly.

**Stage 6 plumbing is LIVE.** Hub now exposes:

```solidity
// On FxHubMessageReceiver (gated by owner OR relayCallers whitelist):
function relayToRemoteHub(uint256 amount) external;
function relayMintFromRemote(
    bytes calldata attestation,
    bytes calldata signature
) external returns (uint256 minted);

// Admin (owner-only):
function setRelayCaller(address relayer, bool allowed) external;
function setGatewayHook(address newHook) external;
function transferOwnership(address newOwner) external;
function sweepHubBalance(address token, address to, uint256 amount) external;
```

> **Codex adversarial-review v3 hardening.** `relayMintFromRemote` performs
> a balance-delta check after the hook mints, then atomically routes the
> minted USDC to `msg.sender` (the calling relayer). Round 2 of the review
> rejected an arbitrary `recipient` arg because it made Gateway attestations
> bearer claims for any whitelisted relayer. **BUFX must therefore call
> `relayMintFromRemote` from the same contract/account it wants to receive
> the minted USDC** — typically the BUFX execution contract itself, which
> then routes to user sub-accounts internally. Trust model: any address
> whitelisted via `setRelayCaller` is trusted with full claim authority
> over in-flight Gateway attestations; whitelist exactly one production
> relayer per hub.

**To onboard BUFX:**

1. BUFX deploys their perp/spot contracts on Fuji + Arc.
2. We call `hub.setRelayCaller(bufxAddress, true)` on each chain.
3. BUFX's contract:
   - Pulls user USDC + approves the hub
   - Calls `hub.relayToRemoteHub(amount)` to lock USDC into Gateway under the
     hub's authority. The off-chain signer service watches the
     `LockedForRemote` event, signs the BurnIntent for `destDomain`, POSTs to
     Circle's operator.
   - Once the attestation lands (`~349ms` typical), BUFX's contract on the
     destination chain calls `hub.relayMintFromRemote(payload, signature)`.
     The hook receives the USDC and forwards it to the hub, which immediately
     routes the verified delta to `msg.sender` (the BUFX contract itself).
     Funds are now available for BUFX's local FX execution.

**Verified end-to-end live on 2026-05-15** — see [`reports/gateway-fuji-to-arc-bypass.md`](../reports/gateway-fuji-to-arc-bypass.md) for tx hashes + latencies for both bypass and hook-routed flows.

**Signer service:**
[`packages/sdk/scripts/gateway-signer.ts`](../packages/sdk/scripts/gateway-signer.ts)
— Bun CLI. Modes: `info`, `balances`, `deposit`, `sign-and-attest`,
`gateway-mint`, `watch`. Use `watch` for daemon mode; emits per-event JSONL
attestation logs to `reports/gateway-attestations.jsonl`.

---

## How to use cross-hub liquidity today

Use Stage 6 hub relay. Do not call `FxGatewayHook` directly from BUFX.

1. Ask governance/ops to whitelist the BUFX execution contract on each hub with
   `FxHubMessageReceiver.setRelayCaller(bufxAddress, true)`.
2. From the whitelisted BUFX contract on the source hub, call
   `relayToRemoteHub(amount)`.
3. The signer service watches `LockedForRemote`, builds the Circle Gateway
   `BurnIntent`, signs with the pre-1271 deployer EOA authority, and submits it
   to Circle Gateway.
4. When Circle returns the attestation, call `relayMintFromRemote(payload, sig)`
   from the BUFX contract on the destination hub.
5. The destination hub verifies the mint delta and forwards the minted USDC to
   `msg.sender`, so the caller must be the BUFX contract/account that should
   receive the funds.

Signer service:
[`packages/sdk/scripts/gateway-signer.ts`](../packages/sdk/scripts/gateway-signer.ts).
Gateway authority remains the deployer EOA until Circle's EIP-1271 support is
live; then authority rotates to the hub path.

---

## Tenderly Virtual TestNet for dogfooding

We have a post-deploy Fuji vnet that mirrors mainnet state with the full hub stack
loaded. Snapshot ID + RPC URL on request — useful for E2E without burning real
testnet gas.

Note: Tenderly doesn't index Arc Testnet yet. On-chain verification only for Arc.

---

## Open Qs

1. Does BUFX want to be a whitelisted hub caller (Option A) or get its own slot
   on the hook (Option B)?
2. Authority rotation timeline — happy to coordinate the EOA → hub-via-1271
   migration so BUFX's burn-intent expectations don't break.
3. Should we share an EOA for the testnet burn-intent signing, or does BUFX want
   its own authority address allowlisted as a co-signer? (Gateway supports
   `contractSignersAllowlister` for multiple sources.)

Ping `tomas.cordero.esp@gmail.com` or the BuFi007 GitHub for follow-ups.
