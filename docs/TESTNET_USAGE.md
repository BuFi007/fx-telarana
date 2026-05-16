# Testnet Usage — fx-Telaraña on Arc Testnet

**Last revision:** 2026-05-14.
**Purpose:** Quick-start for users (or QA / integrators) interacting with the protocol on Arc Testnet ahead of Avalanche mainnet launch.

Tasks covered:
1. Get test-token balances via faucets.
2. Interact with the Phase 3 basket (USDC, EURC + the mock basket).
3. Exit the protocol cleanly.

---

## 1. Wallet setup

Add Arc Testnet to your wallet:

| Field | Value |
|---|---|
| Network name | Arc Testnet |
| RPC URL | per [Arc docs](https://www.arc.network/) |
| Chain ID | 5042002 |
| Native currency | USDC (6 dec ERC-20 / 18 dec native gas) |

USDC is the native gas token on Arc — fund via [faucet.circle.com](https://faucet.circle.com) (select Arc Testnet).

---

## 2. Get test tokens

### 2.1 USDC + EURC (Circle-issued, real on Arc testnet)

| Token | Address | Faucet |
|---|---|---|
| USDC | `0x3600000000000000000000000000000000000000` | [faucet.circle.com](https://faucet.circle.com) → Arc Testnet |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | [faucet.circle.com](https://faucet.circle.com) → Arc Testnet |

### 2.2 Phase 3 mock basket (deployed via `DeployArcTestnetMocks.s.sol`)

Addresses live in `deployments/arc-testnet-mocks.json` after the operator broadcast. Each mock has a self-serve faucet method when `faucetOpen` is set:

```bash
# Pay-out is 1000 whole tokens, decimal-adjusted.
cast send <mockAddr> "faucet()" --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY
```

| Symbol | Decimals | Faucet payout |
|---|---|---|
| mAUDF | 6 | 1000 mAUDF (= 1_000_000_000 raw) |
| mJPYC | 18 | 1000 mJPYC (= 1e21 raw) |
| mMXNB | 6 | 1000 mMXNB (= 1_000_000_000 raw) |
| mKRW1 | 0 | 1000 mKRW1 (= 1000 raw) |
| mZCHF | 18 | 1000 mZCHF (= 1e21 raw) |

Faucet is gated by `faucetOpen` (default off). Owner enables via `setFaucetOpen(true)`. Closes before any mainnet-shape rehearsal.

### 2.3 Tokens NOT mocked on Arc

- `mPHPC`, `mBRLA` — explicitly excluded from Phase 3 basket.

---

## 3. Interacting with the protocol

### 3.1 Supply (be an LP)

```bash
# 1. Approve the receipt wrapper
cast send $USDC "approve(address,uint256)" $FX_RECEIPT_USDC \
  100000000 --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY

# 2. Deposit 100 USDC → get fxUSDC shares (18 dec — note the _decimalsOffset=6)
cast send $FX_RECEIPT_USDC "deposit(uint256,address)" 100000000 $YOUR_ADDR \
  --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY
```

### 3.2 Swap (use the v4 hook)

For now: direct interactions go through Uniswap v4 Universal Router or the upcoming `FxRouter.executeIntent`. Per-step example deferred until PR-5 lands the router.

Quote without committing:
```bash
cast call $FX_SWAP_HOOK "quoteExactInput(address,uint256)" $USDC 100000000 \
  --rpc-url $ARC_TESTNET_RPC
# returns (buyAmount, oraclePriceE18)
```

### 3.3 Cross-chain (CCTP V2 deposit from another testnet)

```bash
# From a spoke chain (e.g. Avalanche Fuji):
cast send $FX_SPOKE "enterHub(address,uint256,address,bytes)" \
  $USDC_FUJI 1000000 $YOUR_HUB_ADDR $HUB_CALLDATA \
  --rpc-url $FUJI_RPC --private-key $PRIVATE_KEY
```

The Hub-side `FxHubMessageReceiver` receives the CCTP V2 message + executes `hubCalldata` against `FxMarketRegistry`. If anything reverts, the deposit is marked Stranded; sweep after 24 hours:

```bash
cast send $FX_HUB_RECEIVER "sweepStrandedDeposit(bytes32)" $NONCE \
  --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY
```

---

## 4. Reading state

```bash
# How much I supplied via the wrapper:
cast call $FX_RECEIPT_USDC "balanceOf(address)" $YOUR_ADDR --rpc-url $ARC_TESTNET_RPC
# How many USDC that represents:
cast call $FX_RECEIPT_USDC "convertToAssets(uint256)" $SHARES --rpc-url $ARC_TESTNET_RPC

# All registered pools:
cast call $FX_MARKET_REGISTRY "listPools()" --rpc-url $ARC_TESTNET_RPC

# Per-pool risk params:
cast call $FX_MARKET_REGISTRY "riskParamsOf(address,address)" $USDC $EURC \
  --rpc-url $ARC_TESTNET_RPC

# Token's USD price (Pyth):
cast call $FX_ORACLE "priceOf(address)" $USDC --rpc-url $ARC_TESTNET_RPC
```

---

## 5. Exit

Withdrawals + repays always work, even when a pool is paused. Pause only blocks new deposits / borrows.

```bash
# Redeem all shares for USDC:
cast send $FX_RECEIPT_USDC "redeem(uint256,address,address)" \
  $SHARES $YOUR_ADDR $YOUR_ADDR \
  --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY
```

---

## 6. Reporting issues

- Open a GitHub issue with the tx hash + a Tenderly trace link.
- For P0/P1 (see `docs/INCIDENT_RESPONSE.md` §0): page the on-call via the protocol's status page.
- For documentation gaps: PR welcome.

---

## Reference

- `docs/SPEC_PHASE_3_MULTI_STABLECOIN.md` — protocol spec.
- `docs/DEPLOY_MAINNET_HUB.md` — Avalanche mainnet target + Arc testnet plumbing.
- `docs/BLOCKED_PAIRS.md` — what's not on the basket and why.
- `docs/INCIDENT_RESPONSE.md` — pause buttons + recovery paths.
