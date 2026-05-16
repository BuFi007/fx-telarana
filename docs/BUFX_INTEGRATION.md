# BUFX ↔ FX Telaraña Integration Reference

Live addresses + interfaces for the BUFX perp/spot layer to integrate with the
Telaraña borrow/lend substrate.

**Repo split:** Telaraña is the money-market substrate (this repo). BUFX is the
spot+perp execution layer (separate repo). They share state via the addresses and
contracts below.

---

## Live deployments

### Avalanche Fuji — PRIMARY HUB (chainId 43113, CCTP V2 domain 1, Gateway domain 1)

User deposits route here via CCTP V2 spokes. All `enterHub` flows from any spoke
chain land on Fuji's `FxHubMessageReceiver`.

| Contract | Address |
|---|---|
| `FxSpoke` (local, Fuji-side entry) | `0xb7fc291c27f6a7a659d4d229e5d8a55e58f26ab1` |
| **`FxHubMessageReceiver` (Stage 6)** | **`0x7eAdfD0c08dd6544f763285bBD31be14179d594B`** |
| **`FxGatewayHook` (Stage 6)** | **`0x7dA191bfB85D9F14069228cf618519BFb41f371E`** |
| `FxMarketRegistry` | `0x7ba745b979e027992ECFa51207666e3F5B46cF0a` |
| `FxOracle` | `0xf7fcdca3f9c92418a980a31df7f87de7e1a1a04b` |
| `FxLiquidator` | `0x2900599ff0e6dd057493d62fac856e5a8f93c6eb` |
| `FxReceiptEURC` (ERC-4626) | `0xefd7cf5ad5a2db9a3c23e2807f2279de92c730d2` |
| `FxReceiptUSDC` (ERC-4626) | `0x9f0947d7fff3b7e15d149fbbc61d83a07c46b88e` |
| `MorphoOracleAdapter M1` (EURC/USDC) | `0xda4c3e315fffd0790c9d8a1730c2ba56330cb2ec` |
| `MorphoOracleAdapter M2` (USDC/EURC) | `0xf0cdaa9cf9e8d52060dcb41a045e3a6d618a9f65` |
| MorphoBlue (self-deployed) | `0xeF64621D41093144D9ED8aB8327eE381ECdB79E6` |
| IrmMock | `0x0B5D18BBE92F07eC0111Ae6d2E102858268D6aCA` |
| MockEURC | `0x50c4ba39caa7f56152d0df4914e1f6b907194992` |
| USDC (Circle) | `0x5425890298aed601595a70AB815c96711a31Bc65` |
| (deprecated V1 hub) | `0x365DE300dDa61C81a33bcE3606A5d524eD964362` |
| (deprecated V1 hook) | `0xc63634ebc99f9c9616ee126971CCa486f3AFfF6E` |

Market IDs:
- M1 EURC/USDC: `0x7d99088a9fe61331c49a92eb16fa3794b0bc2862b211f5a70f31a64cef25029e`
- M2 USDC/EURC: `0x1700104cf29eceb113e01a1bcdc913e5e10d3d37314cee235752aa88bf153197`

### Arc Testnet — TRADING-EXECUTION HUB (chainId 5042002, CCTP V2 domain 26, Gateway domain 26)

Receives USDC liquidity from Fuji via `FxGatewayHook` (never user-initiated). This
is where high-frequency trading and perp execution should live — sub-second
finality, native USDC gas.

| Contract | Address |
|---|---|
| `FxSpoke` (routes to Fuji hub) | `0x13c8463589d460db6f21235eedfd678c22a1ea25` |
| **`FxHubMessageReceiver` (Stage 6)** | **`0x44B50E93eCC7775aF99bcd04c30e1A00da80F63C`** |
| **`FxGatewayHook` (Stage 6)** | **`0x2931C50745334d6DFf9eC4E3106fE05b49717DF1`** |
| `FxMarketRegistry` | `0x813232259c9b922e7571F15220617C80581f1464` |
| `FxOracle` | `0x77b3A3B420dB98B01085b8C46a753Ed9879e2865` |
| `FxLiquidator` | `0xa50f7D4D4a1A0D3CF418515973545b80E037B379` |
| `FxReceiptEURC` (ERC-4626) | `0xF829f57Db8530fa93FCD6e13b00193cbe8cE1493` |
| `FxReceiptUSDC` (ERC-4626) | `0xdd22365Bba7330BE537c9BC26da9b1b4Db9aC431` |
| `MorphoOracleAdapter M1` | `0xED58C176E9a37Cda2854AC0Ade409cfb3687cA7d` |
| `MorphoOracleAdapter M2` | `0x955AAEE698aaA03d5bc32F16434cef78b8Ee1fc7` |
| MorphoBlue (self-deployed) | `0x3c9b95C6E7B23f094f066733E7797C8680760830` |
| IrmMock | `0x8CC1B64D712eE2ff2891D56a5108eC4FDa73b9c1` |
| USDC (Arc native 6-dec form) | `0x3600000000000000000000000000000000000000` |
| EURC (Circle native) | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |
| (deprecated V1 hub) | `0x07db64fb19C6c4a1eBB1B7bfdaFd4676b43Cf276` |
| (deprecated V1 hook) | `0x004cfa0305c365b1d9b2365f85acf216c96b0e13` |

Market IDs:
- M1 EURC/USDC: `0xf6fac2b9b801a7ae3deeccfa95a7f1e768b4873a22f0def0d93f7f0172cc2da2`
- M2 USDC/EURC: `0x9e187a5f252de56b9ffe35f72cdc4137568f9d51698560751cdaff3df60cb5d3`

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
- `FxMarketRegistry.morphoMarketParams(bytes32 marketId)` → market config
- `FxMarketRegistry.morpho()` → MorphoBlue address
- `FxReceipt{EURC,USDC}.totalAssets() / totalSupply() / balanceOf(account)` → ERC-4626 share math
- `FxOracle.getMid(token)` → cached mid price (last update)
- `FxOracle.getMidWithUpdate(token, bytes pythPayload)` payable → fresh Pyth-backed price (deduct `getUpdateFee` first)
- `FxLiquidator.previewLiquidation(...)` → liquidation math without execution

### Gateway state (via FxGatewayHook)
- `gatewayBalance()` → USDC currently locked under our authority on this chain
- `gatewayWithdrawalUnlockBlock()` → block at which an in-progress withdrawal becomes withdrawable

---

## Write surface — what BUFX CAN call today

### Borrow / lend (Morpho-Blue-style, via FxMarketRegistry)

BUFX contracts (or BUFX-signed txs) can call the registry directly. **Codex-patched
gate**: `onBehalf` MUST equal `msg.sender` on withdraw / withdrawCollateral / borrow.
Supply / supplyCollateral / repay accept arbitrary `onBehalf`.

```solidity
interface IFxMarketRegistry {
    function supply(bytes32 marketId, uint256 assets, address onBehalf, bytes calldata) external returns (uint256 sharesOut);
    function supplyCollateral(bytes32 marketId, uint256 assets, address onBehalf, bytes calldata) external;
    function withdraw(bytes32 marketId, uint256 assets, address onBehalf, address receiver) external returns (uint256 assetsOut);
    function withdrawCollateral(bytes32 marketId, uint256 assets, address onBehalf, address receiver) external;
    function borrow(bytes32 marketId, uint256 assets, address onBehalf, address receiver) external returns (uint256 assetsOut);
    function repay(bytes32 marketId, uint256 assets, address onBehalf, bytes calldata) external returns (uint256 assetsRepaid);
    function liquidate(bytes32 marketId, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata) external returns (uint256, uint256);
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

## How to use cross-hub liquidity today (manual, pre-Stage-6)

Until Stage 6 lands, BUFX can use the EOA-signed flow:

1. Hub on Fuji (or someone) approves `FxGatewayHook` to spend USDC
2. Call `FxGatewayHook.lockForRemote(amount)` AS the hub (only works with hub privkey — for testing, use a hub-impersonating sim on the Fuji vnet)
3. Off-chain: deployer EOA `0x0646...c69` signs a `BurnIntent` with:
   - `sourceDomain=1`, `destinationDomain=26`
   - `sourceContract=GatewayWallet`, `destinationContract=GatewayMinter`
   - `sourceDepositor=0x0646...c69` (authority)
   - `destinationRecipient=0x004cfa03...0e13` (Arc FxGatewayHook)
   - `destinationCaller=0x004cfa03...0e13` (locks mint to the hook only)
   - `value=<amount>`
4. POST the intent to Circle's operator API → receive attestation
5. Call `FxGatewayHook.mintFromRemote(attestationPayload, signature)` on Arc — USDC lands on Arc hub

Burn intent format + signing helper: see `/tmp/circle-gateway/src/lib/BurnIntents.sol`
(EIP-712 typed-data hash, `BURN_INTENT_TYPEHASH = 0x8b99d17a83a2dd1add9fc2a450e22732c7e8564aa110ab99c20485a7a10ba37c`).

The off-chain signer service is queued on our side — `packages/sdk/scripts/gateway-signer.ts`.
Happy to share once it lands.

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
