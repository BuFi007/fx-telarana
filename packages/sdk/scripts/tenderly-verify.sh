#!/bin/sh
#
# Tenderly verify-contract pipeline for the fx-Telaraña Hub on Base Sepolia.
#
# Submits each v3 contract to Tenderly's etherscan-compat verifier with the
# correct constructor arguments. Tenderly's verifier rejects forge's
# --guess-constructor-args ("Action not supported"), so we encode the args
# manually based on the deploy-time constants.
#
# Usage:
#   ./packages/sdk/scripts/tenderly-verify.sh
#
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
set -a
# shellcheck disable=SC1091
. "$REPO_ROOT/.env.local"
set +a

if [ -z "${TENDERLY_ACCESS_KEY:-}" ]; then
  echo "missing TENDERLY_* env in .env.local"; exit 1
fi

CHAIN_ID=84532
VURL="https://api.tenderly.co/api/v1/account/$TENDERLY_ACCOUNT/project/$TENDERLY_PROJECT/etherscan/verify/network/$CHAIN_ID"

CAST=/Users/criptopoeta/.foundry/bin/cast
FORGE=/Users/criptopoeta/.foundry/bin/forge

# ── Base Sepolia v3 deployment constants ────────────────────────────────────
PYTH=0xA2aa501b19aff244D90cc15a4Cf739D2725B5729
DEPLOYER=0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69
MORPHO=0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb
IRM=0x46415998764C29aB2a25CbeA6254146D50D22687
USDC=0x036CbD53842c5426634e7929541eC2318f3dCF7e
EURC=0x808456652fdb597867f38412077A9182bf77359F
ORACLE=0x4cf0403ee262a5f4E964658C428aC9D7EfF37076
ADAPTER_M1=0x0A1e5Df9E1767d8B9691E77b97Bf6BfE51D28DD8
ADAPTER_M2=0x15561478B91a2B17eaA8D54E0BD4dd145A6D2b02
REGISTRY=0x0cb2dd5296e06c86cb96aeef2c59d2a92cfd9b9e
RECEIPT_EURC=0xe6bA492FC3256Ba05c80be30436Cdf069BE23b80
RECEIPT_USDC=0xD5A6cB32f2635f90C3Ccb9EB2d5d2Cc59f1C333c
LIQUIDATOR=0xb9f81d14bdc2d96d99222aafcad1752ea18e80e4
HUB_RECEIVER=0x17afd89bd6888c393b8c5d7e7c0baee8259581a5
SWAP_HOOK=0xc7260EF7D95D155aD6CA18ED539373a7576c8AC8
CCTP_MT=0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275
LLTV=860000000000000000

# FxSwapHook is wired to v2 oracle/registry (LP + pool still live)
V2_ORACLE=0x7a2a612820f3f697b40f93c026758f2dfafcdbce
V2_REGISTRY=0x30f4c7bce1e0c5ca5d2ecd2ebdbf13f6273fe7fe
POOL_MANAGER=0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408

cd "$REPO_ROOT/contracts"

verify_one() {
  NAME="$1"; ADDR="$2"; SRC="$3"; ARGS="$4"
  echo
  echo "--- $NAME @ $ADDR ---"
  $FORGE verify-contract "$ADDR" "$SRC" \
    --constructor-args "$ARGS" \
    --verifier custom \
    --verifier-url "$VURL" \
    --etherscan-api-key "$TENDERLY_ACCESS_KEY" \
    --watch 2>&1 | /usr/bin/tail -6
  # Set display_name (rename endpoint) so dashboards distinguish multiple
  # instances of the same contract (e.g. FxReceiptEURC vs FxReceiptUSDC).
  ADDR_LC=$(echo "$ADDR" | /usr/bin/tr A-Z a-z)
  /usr/bin/curl -s -X POST -H "X-Access-Key: $TENDERLY_ACCESS_KEY" -H "Content-Type: application/json" \
    "https://api.tenderly.co/api/v1/account/$TENDERLY_ACCOUNT/project/$TENDERLY_PROJECT/contract/$CHAIN_ID/$ADDR_LC/rename" \
    -d "{\"display_name\":\"$NAME\"}" > /dev/null
}

# FxOracle(pyth, owner, maxAge=600, maxDevBps=50, maxConfBps=30)
ARGS=$($CAST abi-encode "constructor(address,address,uint256,uint256,uint256)" \
  $PYTH $DEPLOYER 600 50 30)
verify_one "FxOracle" $ORACLE src/hub/FxOracle.sol:FxOracle "$ARGS"

# MorphoOracleAdapter(oracle, base, quote)
ARGS=$($CAST abi-encode "constructor(address,address,address)" $ORACLE $EURC $USDC)
verify_one "MorphoOracleAdapterM1 (EURC/USDC)" $ADAPTER_M1 src/hub/MorphoOracleAdapter.sol:MorphoOracleAdapter "$ARGS"
ARGS=$($CAST abi-encode "constructor(address,address,address)" $ORACLE $USDC $EURC)
verify_one "MorphoOracleAdapterM2 (USDC/EURC)" $ADAPTER_M2 src/hub/MorphoOracleAdapter.sol:MorphoOracleAdapter "$ARGS"

# FxMarketRegistry(morpho, owner)
ARGS=$($CAST abi-encode "constructor(address,address)" $MORPHO $DEPLOYER)
verify_one "FxMarketRegistry" $REGISTRY src/hub/FxMarketRegistry.sol:FxMarketRegistry "$ARGS"

# FxReceipt(asset, name, symbol, morpho, MarketParams)
#   MarketParams = (loanToken, collateralToken, oracle, irm, lltv)
# fxEURC: asset=EURC, MP={EURC, USDC, adapterM1, irm, lltv}
ARGS=$($CAST abi-encode \
  "constructor(address,string,string,address,(address,address,address,address,uint256))" \
  $EURC "fxEURC supply receipt" "fxEURC" $MORPHO "($EURC,$USDC,$ADAPTER_M1,$IRM,$LLTV)")
verify_one "FxReceiptEURC (fxEURC)" $RECEIPT_EURC src/hub/FxReceipt.sol:FxReceipt "$ARGS"

# fxUSDC: asset=USDC, MP={USDC, EURC, adapterM2, irm, lltv}
ARGS=$($CAST abi-encode \
  "constructor(address,string,string,address,(address,address,address,address,uint256))" \
  $USDC "fxUSDC supply receipt" "fxUSDC" $MORPHO "($USDC,$EURC,$ADAPTER_M2,$IRM,$LLTV)")
verify_one "FxReceiptUSDC (fxUSDC)" $RECEIPT_USDC src/hub/FxReceipt.sol:FxReceipt "$ARGS"

# FxLiquidator(morpho, registry, oracle)
ARGS=$($CAST abi-encode "constructor(address,address,address)" $MORPHO $REGISTRY $ORACLE)
verify_one "FxLiquidator" $LIQUIDATOR src/hub/FxLiquidator.sol:FxLiquidator "$ARGS"

# FxHubMessageReceiver(messageTransmitter, usdc, marketRegistry)
ARGS=$($CAST abi-encode "constructor(address,address,address)" $CCTP_MT $USDC $REGISTRY)
verify_one "FxHubMessageReceiver" $HUB_RECEIVER src/hub/FxHubMessageReceiver.sol:FxHubMessageReceiver "$ARGS"

# FxSwapHook(poolManager, oracle_v2, registry_v2, owner, token0, token1, morpho)
ARGS=$($CAST abi-encode "constructor(address,address,address,address,address,address,address)" \
  $POOL_MANAGER $V2_ORACLE $V2_REGISTRY $DEPLOYER $USDC $EURC $MORPHO)
verify_one "FxSwapHook" $SWAP_HOOK src/hub/FxSwapHook.sol:FxSwapHook "$ARGS"

echo
echo "dashboard: https://dashboard.tenderly.co/$TENDERLY_ACCOUNT/$TENDERLY_PROJECT/contracts"
