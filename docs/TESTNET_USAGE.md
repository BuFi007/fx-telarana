# Testnet Usage — fx-Telaraña on Arc Testnet

**Last revision:** 2026-05-17.
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

### 2.2 Phase 3 mock basket (live Arc basket hub)

Addresses live in `deployments/arc-testnet-basket.json` and
`deployments/arc-testnet.json`. Each mock has a self-serve faucet method because
`faucetOpen` is currently enabled for UI/API testing:

```bash
# Pay-out is 1000 whole tokens, decimal-adjusted.
cast send <mockAddr> "faucet()" --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY
```

| Symbol | Decimals | Faucet payout |
|---|---|---|
| mAUDF `0x4DeB6B4C83588c987C952858225A4725F6e1B1f2` | 6 | 1000 mAUDF (= 1_000_000_000 raw) |
| mJPYC `0xD9eCFc78BDFbD121E8b07Bf96D6E27a1C11C6331` | 18 | 1000 mJPYC (= 1e21 raw) |
| mMXNB `0xdb6EC7E8ad32D2c6fe05c0862d626A84049c24c5` | 6 | 1000 mMXNB (= 1_000_000_000 raw) |
| mKRW1 `0x204E306FBc71D876E4F105111bBBB1E8113886C3` | 0 | 1000 mKRW1 (= 1000 raw) |
| mZCHF `0xF50D7B5B6699f2D1FB7BCFC80261Ae0fca48396C` | 18 | 1000 mZCHF (= 1e21 raw) |

Faucet is gated by `faucetOpen`. Close it before any mainnet-shape rehearsal.

### 2.3 Tokens NOT mocked on Arc

- `mPHPC`, `mBRLA` — explicitly excluded from Phase 3 basket.

---

## 3. Interacting with the protocol

### 3.1 Supply (be an LP)

```bash
# 1. Pick a registered market. Example: lend 1 USDC into the USDC/mJPYC market.
export FX_MARKET_REGISTRY=0xdB59d712a3cD19DccD98F5a245302a94d43f9A8c
export FX_ORACLE=0x625e2870a94F67F575Ed82678C2c619994721D29
export FX_HUB_RECEIVER=0x4FBe4cc4ab09648d65195f5B9490D20D12D49a2c
export MORPHO=0x3c9b95C6E7B23f094f066733E7797C8680760830
export USDC=0x3600000000000000000000000000000000000000
export MJPYC=0xD9eCFc78BDFbD121E8b07Bf96D6E27a1C11C6331

# 2. Approve the registry.
cast send $USDC "approve(address,uint256)" $FX_MARKET_REGISTRY 1000000 \
  --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY

# 3. Supply 1 USDC as the loan asset for the USDC/mJPYC market.
cast send $FX_MARKET_REGISTRY "supply(address,address,uint256,address)" \
  $USDC $MJPYC 1000000 $YOUR_ADDR \
  --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY
```

### 3.2 Borrow

Borrowing requires collateral first. Example: use mJPYC as collateral to borrow
USDC from the USDC/mJPYC market.

```bash
cast send $MJPYC "approve(address,uint256)" $FX_MARKET_REGISTRY 100000000000000000000 \
  --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY

cast send $FX_MARKET_REGISTRY "supplyCollateral(address,address,uint256,address)" \
  $USDC $MJPYC 100000000000000000000 $YOUR_ADDR \
  --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY

cast send $FX_MARKET_REGISTRY "borrow(address,address,uint256,address,address)" \
  $USDC $MJPYC 100000 $YOUR_ADDR $YOUR_ADDR \
  --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY
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
# All registered pools:
cast call $FX_MARKET_REGISTRY "listPools()" --rpc-url $ARC_TESTNET_RPC

# Market id for a pair:
export MARKET_ID=$(cast call $FX_MARKET_REGISTRY "marketIdOf(address,address)(bytes32)" \
  $USDC $MJPYC --rpc-url $ARC_TESTNET_RPC)

# Per-pool risk params:
cast call $FX_MARKET_REGISTRY "paramsOf(address,address)" $USDC $MJPYC \
  --rpc-url $ARC_TESTNET_RPC

# User Morpho position: supplyShares, borrowShares, collateral.
cast call $MORPHO "position(bytes32,address)(uint256,uint128,uint128)" \
  $MARKET_ID $YOUR_ADDR --rpc-url $ARC_TESTNET_RPC

# Market totals: totalSupplyAssets, totalSupplyShares, totalBorrowAssets,
# totalBorrowShares, lastUpdate, fee.
cast call $MORPHO "market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)" \
  $MARKET_ID --rpc-url $ARC_TESTNET_RPC

# Token's USD price through FxOracle:
cast call $FX_ORACLE "priceOf(address)" $USDC --rpc-url $ARC_TESTNET_RPC
```

Receipt wrappers still exist for supported LP receipt-token flows, but the live
money-market UI/API path should read user positions from Morpho by market id and
use `FxMarketRegistry` for actions.

---

## 5. Exit

Withdrawals + repays always work, even when a pool is paused. Pause only blocks new deposits / borrows.

```bash
# Repay, then withdraw. Shares and exact position math should be read from
# Morpho before constructing production UI actions.
cast send $FX_MARKET_REGISTRY "repay(address,address,uint256,address)" \
  $USDC $MJPYC 100000 $YOUR_ADDR \
  --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY

cast send $FX_MARKET_REGISTRY "withdrawCollateral(address,address,uint256,address,address)" \
  $USDC $MJPYC 100000000000000000000 $YOUR_ADDR $YOUR_ADDR \
  --rpc-url $ARC_TESTNET_RPC --private-key $PRIVATE_KEY

cast send $FX_MARKET_REGISTRY "withdraw(address,address,uint256,address,address)" \
  $USDC $MJPYC $SUPPLY_SHARES $YOUR_ADDR $YOUR_ADDR \
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
