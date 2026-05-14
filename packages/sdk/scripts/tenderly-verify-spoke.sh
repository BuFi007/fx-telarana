#!/bin/sh
#
# Tenderly verify-contract for an `FxSpoke` deployed to a non-hub chain.
#
# Reads the spoke deployment manifest at `deployments/<chain>.json` and submits
# the source + constructor args to Tenderly's etherscan-compat verifier so the
# contract shows up as a verified Contract (not a Wallet) in the dashboard.
#
# Usage:
#   ./packages/sdk/scripts/tenderly-verify-spoke.sh <deployments-json>
#
# The manifest must contain `chainId`, `contracts.FxSpoke`, and
# `external.{CctpTokenMessengerV2, USDC}`. It must also have `hub` block with
# `messageReceiver` and `cctpDomain` so we can re-derive the constructor args.
#
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
MANIFEST_ARG="${1:-}"
if [ -z "$MANIFEST_ARG" ]; then
  echo "usage: $0 <deployments-json>"; exit 1
fi
# Resolve manifest to an absolute path so later cwd changes don't break re-reads.
case "$MANIFEST_ARG" in
  /*) MANIFEST="$MANIFEST_ARG" ;;
  *)  MANIFEST="$(pwd)/$MANIFEST_ARG" ;;
esac
if [ ! -f "$MANIFEST" ]; then
  echo "manifest not found: $MANIFEST"; exit 1
fi

set -a
. "$REPO_ROOT/.env.local"
set +a

if [ -z "${TENDERLY_ACCESS_KEY:-}" ]; then
  echo "missing TENDERLY_ACCESS_KEY in .env.local"; exit 1
fi

CHAIN_ID=$(/usr/bin/python3 -c "import json; print(json.load(open('$MANIFEST'))['chainId'])")
SPOKE_ADDR=$(/usr/bin/python3 -c "import json; print(json.load(open('$MANIFEST'))['contracts']['FxSpoke'])")
USDC=$(/usr/bin/python3 -c "import json; print(json.load(open('$MANIFEST'))['external']['USDC'])")
TOKEN_MSGR=$(/usr/bin/python3 -c "import json; print(json.load(open('$MANIFEST'))['external']['CctpTokenMessengerV2'])")
HUB_RECEIVER=$(/usr/bin/python3 -c "import json; print(json.load(open('$MANIFEST'))['hub']['messageReceiver'])")
HUB_DOMAIN=$(/usr/bin/python3 -c "import json; print(json.load(open('$MANIFEST'))['hub']['cctpDomain'])")

CAST=/Users/criptopoeta/.foundry/bin/cast
FORGE=/Users/criptopoeta/.foundry/bin/forge
VURL="https://api.tenderly.co/api/v1/account/$TENDERLY_ACCOUNT/project/$TENDERLY_PROJECT/etherscan/verify/network/$CHAIN_ID"

echo "chain      : $CHAIN_ID"
echo "FxSpoke    : $SPOKE_ADDR"
echo "tokenMsgr  : $TOKEN_MSGR"
echo "usdc       : $USDC"
echo "hubReceiver: $HUB_RECEIVER"
echo "hubDomain  : $HUB_DOMAIN"

ARGS=$($CAST abi-encode "constructor(address,address,address,uint32)" \
  "$TOKEN_MSGR" "$USDC" "$HUB_RECEIVER" "$HUB_DOMAIN")

cd "$REPO_ROOT/contracts"
$FORGE verify-contract "$SPOKE_ADDR" src/spoke/FxSpoke.sol:FxSpoke \
  --constructor-args "$ARGS" \
  --verifier custom \
  --verifier-url "$VURL" \
  --etherscan-api-key "$TENDERLY_ACCESS_KEY" \
  --watch 2>&1 | /usr/bin/tail -8

# Set display_name
ADDR_LC=$(echo "$SPOKE_ADDR" | /usr/bin/tr A-Z a-z)
CHAIN_NAME=$(/usr/bin/python3 -c "import json; print(json.load(open('$MANIFEST'))['network'])")
/usr/bin/curl -s -X POST -H "X-Access-Key: $TENDERLY_ACCESS_KEY" -H "Content-Type: application/json" \
  "https://api.tenderly.co/api/v1/account/$TENDERLY_ACCOUNT/project/$TENDERLY_PROJECT/contract/$CHAIN_ID/$ADDR_LC/rename" \
  -d "{\"display_name\":\"FxSpoke ($CHAIN_NAME)\"}" > /dev/null
echo
echo "labeled: FxSpoke ($CHAIN_NAME)"
echo "dashboard: https://dashboard.tenderly.co/$TENDERLY_ACCOUNT/$TENDERLY_PROJECT/contracts"
