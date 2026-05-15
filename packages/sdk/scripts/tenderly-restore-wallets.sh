#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Idempotent restore of every deployer-wallet entry across the chains
# we've deployed to. Designed to run on a loop until Pro quota propagates.
#
# Usage:
#   sh packages/sdk/scripts/tenderly-restore-wallets.sh
#
# Reads TENDERLY_* env from .env.local. Each POST is independent — quota_limit_reached
# on one wallet doesn't block the others. Re-run after Pro propagation to mop up.
#
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
set -a
. "$REPO_ROOT/.env.local"
set +a

API="https://api.tenderly.co/api/v1/account/$TENDERLY_ACCOUNT/project/$TENDERLY_PROJECT"
DEPLOYER=0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69

add_wallet() {
  local cid="$1" name="$2"
  local resp
  resp=$(curl -s -X POST \
    -H "X-Access-Key: $TENDERLY_ACCESS_KEY" \
    -H "Content-Type: application/json" \
    "$API/wallet" \
    -d "{\"address\":\"$DEPLOYER\",\"network_ids\":[\"$cid\"],\"display_name\":\"fx-Telarana Deployer ($name)\"}")
  if echo "$resp" | grep -q '"error"'; then
    local slug
    slug=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("error",{}).get("slug",""))')
    printf "  %-40s : %s\n" "$name ($cid)" "$slug"
  else
    printf "  %-40s : OK\n" "$name ($cid)"
  fi
}

# All chains where we have deployer activity. Arc-testnet is intentionally
# skipped — Tenderly doesn't index chain 5042002 yet.
add_wallet 11155111 "ethereum-sepolia"
add_wallet 11155420 "op-sepolia"
add_wallet 421614   "arbitrum-sepolia"
add_wallet 43113    "avalanche-fuji"
add_wallet 80002    "polygon-amoy"
add_wallet 59141    "linea-sepolia"
add_wallet 1301     "unichain-sepolia"
add_wallet 4801     "worldchain-sepolia"

echo
echo "=== project total after run ==="
curl -s -X GET -H "X-Access-Key: $TENDERLY_ACCESS_KEY" "$API/contracts" \
  | python3 -c 'import sys,json; print(f"  {len(json.load(sys.stdin))} entries")'
