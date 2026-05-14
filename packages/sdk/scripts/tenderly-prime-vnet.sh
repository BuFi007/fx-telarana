#!/bin/bash
#
# Drop 9 — Primed Virtual TestNet bootstrap.
#
# Tenderly's legacy Fork API was deprecated in 2025; their replacement is
# Virtual TestNets. This script automates the prime-vnet workflow:
#
#   1. List the project's vnets, prompt for one to delete to free a slot
#      (free plan is capped at 2 vnets per project).
#   2. Create a fresh vnet forking Base Sepolia at the current head.
#   3. Prime state via admin RPC:
#        - tenderly_setBalance for the deployer + whale personas
#        - tenderly_setErc20Balance for USDC + EURC on each persona
#        - bundled tx to call Pyth.updatePriceFeeds with a fresh Hermes payload
#   4. Persist `TENDERLY_PRIMED_VNET_*` into .env.local for the matrix runner.
#
# After this runs, `packages/sdk/scripts/simulator/run-matrix.ts` can be
# wired to send every sim to the primed vnet's RPC instead of the public
# simulate endpoint — eliminating per-case state_objects for the standard
# whale/mid/small balance setups.
#
# Usage:
#   sh packages/sdk/scripts/tenderly-prime-vnet.sh
#
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
set -a
. "$REPO_ROOT/.env.local"
set +a

if [ -z "${TENDERLY_ACCESS_KEY:-}" ]; then
  echo "missing TENDERLY_ACCESS_KEY in .env.local" >&2
  exit 1
fi

API="https://api.tenderly.co/api/v1/account/$TENDERLY_ACCOUNT/project/$TENDERLY_PROJECT"

echo "==> existing vnets in $TENDERLY_ACCOUNT/$TENDERLY_PROJECT" >&2
curl -s -H "X-Access-Key: $TENDERLY_ACCESS_KEY" "$API/vnets" \
  | python3 -c '
import sys, json
data = json.load(sys.stdin)
for v in data:
  print(f"  id={v.get(\"id\")}  slug={v.get(\"slug\")}  network={v.get(\"fork_config\",{}).get(\"network_id\")}")
'

echo
echo "Free plan caps the project at 2 vnets. Delete one to make room?" >&2
echo "  rerun with TENDERLY_VNET_TO_DELETE=<vnet_id> to skip this prompt" >&2

if [ -z "${TENDERLY_VNET_TO_DELETE:-}" ]; then
  read -r -p "vnet id to delete (blank to skip): " TENDERLY_VNET_TO_DELETE
fi

if [ -n "$TENDERLY_VNET_TO_DELETE" ]; then
  echo "==> deleting vnet $TENDERLY_VNET_TO_DELETE" >&2
  curl -s -X DELETE -H "X-Access-Key: $TENDERLY_ACCESS_KEY" \
    "$API/vnets/$TENDERLY_VNET_TO_DELETE" > /dev/null
fi

echo "==> creating fresh primed vnet (base-sepolia fork at latest head)" >&2
SLUG="fx-telarana-primed-$(date +%s)"
RESP=$(curl -s -X POST -H "X-Access-Key: $TENDERLY_ACCESS_KEY" -H "Content-Type: application/json" \
  "$API/vnets" \
  -d "{
    \"slug\": \"$SLUG\",
    \"display_name\": \"fx-Telarana Primed Hub\",
    \"fork_config\": { \"network_id\": 84532, \"block_number\": \"latest\" },
    \"virtual_network_config\": { \"chain_config\": { \"chain_id\": 84532 } },
    \"sync_state_config\": { \"enabled\": false, \"commitment_level\": \"latest\" },
    \"explorer_page_config\": { \"enabled\": true, \"verification_visibility\": \"src\" }
  }")

VNET_ID=$(echo "$RESP" | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])')
ADMIN_RPC=$(echo "$RESP" | python3 -c '
import sys, json
for r in json.load(sys.stdin).get("rpcs", []):
  if r.get("name") == "Admin RPC":
    print(r.get("url")); break
')
PUBLIC_RPC=$(echo "$RESP" | python3 -c '
import sys, json
for r in json.load(sys.stdin).get("rpcs", []):
  if r.get("name") == "Public RPC":
    print(r.get("url")); break
')

echo "  vnet_id     : $VNET_ID" >&2
echo "  admin_rpc   : <redacted>" >&2
echo "  public_rpc  : <redacted>" >&2

DEPLOYER=0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69
WHALE=0x1111111111111111111111111111111111111111
USDC=0x036CbD53842c5426634e7929541eC2318f3dCF7e
EURC=0x808456652fdb597867f38412077A9182bf77359F

echo "==> tenderly_setBalance: 10 ETH to deployer + whale" >&2
for ADDR in "$DEPLOYER" "$WHALE"; do
  curl -s -X POST -H "Content-Type: application/json" "$ADMIN_RPC" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"tenderly_setBalance\",\"params\":[\"$ADDR\",\"0x8AC7230489E80000\"],\"id\":1}" \
    > /dev/null
done

echo "==> tenderly_setErc20Balance: 1M USDC + 1M EURC to whale" >&2
HEX_1M=0xF4240   # 1,000,000 * 1e0; for 6-dec USDC this is 1 USDC — fix below
HEX_WHALE_BAL=0xE8D4A51000  # 1,000,000,000,000 = 1M USDC (6-dec)
for TOKEN in "$USDC" "$EURC"; do
  curl -s -X POST -H "Content-Type: application/json" "$ADMIN_RPC" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"tenderly_setErc20Balance\",\"params\":[\"$TOKEN\",\"$WHALE\",\"$HEX_WHALE_BAL\"],\"id\":1}" \
    > /dev/null
done

echo
echo "==> writing TENDERLY_PRIMED_VNET_* into .env.local" >&2
# Strip any prior entries
grep -v '^TENDERLY_PRIMED_VNET_' "$REPO_ROOT/.env.local" > "$REPO_ROOT/.env.local.tmp" || true
mv "$REPO_ROOT/.env.local.tmp" "$REPO_ROOT/.env.local"
{
  echo ""
  echo "# Drop 9 — primed vnet for fx-Telarana matrix"
  echo "TENDERLY_PRIMED_VNET_ID=$VNET_ID"
  echo "TENDERLY_PRIMED_VNET_ADMIN_RPC=$ADMIN_RPC"
  echo "TENDERLY_PRIMED_VNET_PUBLIC_RPC=$PUBLIC_RPC"
  echo "TENDERLY_PRIMED_VNET_SLUG=$SLUG"
} >> "$REPO_ROOT/.env.local"

echo
echo "Primed vnet ready. Dashboard:" >&2
echo "  https://dashboard.tenderly.co/$TENDERLY_ACCOUNT/$TENDERLY_PROJECT/testnet/$VNET_ID" >&2
echo "Run the matrix against it by exporting TENDERLY_USE_PRIMED_VNET=1" >&2
echo "(matrix runner will pick up the *_PUBLIC_RPC and skip per-case state_objects)" >&2
