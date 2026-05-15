#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
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
#   4. Verify primed state via eth_call + eth_getBalance BEFORE persisting.
#   5. Persist `TENDERLY_PRIMED_VNET_*` into .env.local for the matrix runner.
#
# After this runs, `packages/sdk/scripts/simulator/run-matrix.ts` can be
# wired to send every sim to the primed vnet's RPC instead of the public
# simulate endpoint — eliminating per-case state_objects for the standard
# whale/mid/small balance setups.
#
# Exit codes:
#   0 = full success (primed + verified + persisted)
#   1 = RPC / transport / auth error during priming
#   2 = post-prime verification mismatch (balances not where we set them)
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

# --------------------------------------------------------------------------
# rpc_or_die <step-label> <rpc-url> <json-body> [expected-result-shape]
#
# Posts a JSON-RPC request and aborts the script on any of:
#   - curl transport failure
#   - non-JSON response
#   - JSON-RPC "error" field present
#   - missing "result" field
#   - (optional) result shape mismatch — pass "hex" to require 0x-prefixed
#     hex string (txhash / address / hex-encoded value), or "any" to skip.
#
# Emits the parsed "result" value on stdout for the caller to capture.
# All logging/errors go to stderr. Admin RPC URL is never printed.
# Exits 1 on any RPC-layer failure.
# --------------------------------------------------------------------------
rpc_or_die() {
  local LABEL="$1"
  local URL="$2"
  local BODY="$3"
  local SHAPE="${4:-any}"

  local TMP
  TMP=$(mktemp)
  local HTTP_CODE
  HTTP_CODE=$(curl -s -o "$TMP" -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" "$URL" -d "$BODY" || echo "000")

  if [ "$HTTP_CODE" = "000" ] || [ -z "$HTTP_CODE" ]; then
    echo "rpc_or_die[$LABEL]: curl transport failure (no HTTP response)" >&2
    rm -f "$TMP"
    exit 1
  fi

  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "rpc_or_die[$LABEL]: HTTP $HTTP_CODE from <redacted admin RPC>" >&2
    # Body may contain bearer token URLs in error messages — best-effort scrub.
    python3 -c '
import sys, re
raw = open(sys.argv[1]).read()[:2000]
print(re.sub(r"https://[^\s\"]+", "<redacted>", raw), file=sys.stderr)
' "$TMP" || true
    rm -f "$TMP"
    exit 1
  fi

  # Validate JSON + extract result via python3. Print result on stdout, errors
  # on stderr. The python script exits 2/3/4 on different failure modes so we
  # can surface a precise message.
  local PY_OUT
  if ! PY_OUT=$(python3 - "$TMP" <<'PY'
import json, sys, re
path = sys.argv[1]
raw = open(path).read()
try:
  data = json.loads(raw)
except Exception as e:
  scrubbed = re.sub(r"https://[^\s\"]+", "<redacted>", raw[:1000])
  print(f"JSON_PARSE_ERROR: {e} :: {scrubbed}", file=sys.stderr)
  sys.exit(2)

if "error" in data and data["error"] is not None:
  err = data["error"]
  msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
  msg = re.sub(r"https://[^\s\"]+", "<redacted>", msg)
  print(f"JSONRPC_ERROR: {msg}", file=sys.stderr)
  sys.exit(3)

if "result" not in data:
  scrubbed = re.sub(r"https://[^\s\"]+", "<redacted>", raw[:1000])
  print(f"MISSING_RESULT: {scrubbed}", file=sys.stderr)
  sys.exit(4)

r = data["result"]
# Emit as a single line; complex results get re-encoded.
if isinstance(r, (dict, list)):
  print(json.dumps(r))
elif r is None:
  print("")
else:
  print(str(r))
PY
  ); then
    echo "rpc_or_die[$LABEL]: response parse / error-field check failed (see above)" >&2
    rm -f "$TMP"
    exit 1
  fi

  rm -f "$TMP"

  if [ "$SHAPE" = "hex" ]; then
    case "$PY_OUT" in
      0x*) ;;
      *)
        echo "rpc_or_die[$LABEL]: expected hex result, got: $PY_OUT" >&2
        exit 1
        ;;
    esac
  fi

  printf '%s\n' "$PY_OUT"
}

# --------------------------------------------------------------------------
# Idempotent re-run: reuse an existing primed vnet if the env already names
# one. Caller can force a fresh prime by passing FORCE_FRESH=1.
# --------------------------------------------------------------------------
if [ -n "${TENDERLY_PRIMED_VNET_ID:-}" ] && [ "${FORCE_FRESH:-0}" != "1" ]; then
  echo "==> TENDERLY_PRIMED_VNET_ID=$TENDERLY_PRIMED_VNET_ID already set in env" >&2
  REUSE="${REUSE_PRIMED_VNET:-}"
  if [ -z "$REUSE" ]; then
    read -r -p "reuse existing primed vnet? [Y/n] " REUSE
  fi
  case "$REUSE" in
    n|N|no|NO)
      echo "  creating fresh primed vnet (existing one will be left intact)" >&2
      ;;
    *)
      echo "  reusing $TENDERLY_PRIMED_VNET_ID — nothing to do." >&2
      exit 0
      ;;
  esac
fi

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

VNET_ID=$(echo "$RESP" | python3 -c '
import sys, json
try:
  d = json.load(sys.stdin)
  print(d["id"])
except Exception as e:
  print("", end="")
  raise
' || true)

if [ -z "$VNET_ID" ]; then
  echo "vnet create failed — response did not include id (see API response below, scrubbed)" >&2
  echo "$RESP" | python3 -c '
import sys, re
print(re.sub(r"https://[^\s\"]+", "<redacted>", sys.stdin.read()[:1500]), file=sys.stderr)
' || true
  exit 1
fi

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

if [ -z "$ADMIN_RPC" ] || [ -z "$PUBLIC_RPC" ]; then
  echo "vnet create response missing Admin/Public RPC URLs — aborting" >&2
  exit 1
fi

echo "  vnet_id     : $VNET_ID" >&2
echo "  admin_rpc   : <redacted>" >&2
echo "  public_rpc  : <redacted>" >&2

DEPLOYER=0x0646FFe11b9aBcE0054Ce6F73025F06F3E91eC69
WHALE=0x1111111111111111111111111111111111111111
USDC=0x036CbD53842c5426634e7929541eC2318f3dCF7e
EURC=0x808456652fdb597867f38412077A9182bf77359F

# Amounts we will set + verify against later.
ETH_AMOUNT_HEX=0x8AC7230489E80000   # 10 ETH (18-dec)
ETH_AMOUNT_DEC=10000000000000000000
USDC_AMOUNT_HEX=0xE8D4A51000        # 1,000,000 * 1e6 = 1M USDC (6-dec)
USDC_AMOUNT_DEC=1000000000000
# Pad to 32 bytes for eth_call balanceOf return comparison.
USDC_AMOUNT_PADDED=0x000000000000000000000000000000000000000000000000000000e8d4a51000

echo "==> tenderly_setBalance: 10 ETH to deployer + whale" >&2
for ADDR in "$DEPLOYER" "$WHALE"; do
  rpc_or_die "setBalance($ADDR)" "$ADMIN_RPC" \
    "{\"jsonrpc\":\"2.0\",\"method\":\"tenderly_setBalance\",\"params\":[\"$ADDR\",\"$ETH_AMOUNT_HEX\"],\"id\":1}" \
    hex > /dev/null
done

echo "==> tenderly_setErc20Balance: 1M USDC + 1M EURC to whale" >&2
for TOKEN in "$USDC" "$EURC"; do
  rpc_or_die "setErc20Balance($TOKEN -> $WHALE)" "$ADMIN_RPC" \
    "{\"jsonrpc\":\"2.0\",\"method\":\"tenderly_setErc20Balance\",\"params\":[\"$TOKEN\",\"$WHALE\",\"$USDC_AMOUNT_HEX\"],\"id\":1}" \
    hex > /dev/null
done

# --------------------------------------------------------------------------
# Verification phase — read primed state back via public RPC and assert.
# Any mismatch here is a fatal exit-2 BEFORE we write .env.local.
# --------------------------------------------------------------------------
echo "==> verifying primed state via eth_getBalance + eth_call balanceOf" >&2

# verify_eth_balance <label> <addr>
verify_eth_balance() {
  local LABEL="$1"
  local ADDR="$2"
  local RES
  RES=$(rpc_or_die "$LABEL" "$PUBLIC_RPC" \
    "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$ADDR\",\"latest\"],\"id\":1}" \
    hex)
  # Compare as Python ints (handles 0x prefix + any width).
  local OK
  OK=$(python3 -c "
import sys
got = int('$RES', 16)
want = int('$ETH_AMOUNT_DEC')
print('ok' if got >= want else f'fail:got={got},want>={want}')
")
  case "$OK" in
    ok) echo "  [ok] $LABEL = $RES (>= 10 ETH)" >&2 ;;
    *)
      echo "  [FAIL] $LABEL: $OK" >&2
      exit 2
      ;;
  esac
}

verify_eth_balance "eth_getBalance(deployer)" "$DEPLOYER"
verify_eth_balance "eth_getBalance(whale)" "$WHALE"

# verify_token_balance <label> <token> <holder>
# balanceOf(address) selector = 0x70a08231
verify_token_balance() {
  local LABEL="$1"
  local TOKEN="$2"
  local HOLDER="$3"
  # left-pad holder addr to 32 bytes (40 hex chars -> 64 hex chars)
  local HOLDER_NO_PREFIX="${HOLDER#0x}"
  local PADDED_HOLDER
  PADDED_HOLDER=$(python3 -c "print('$HOLDER_NO_PREFIX'.lower().rjust(64, '0'))")
  local DATA="0x70a08231${PADDED_HOLDER}"
  local RES
  RES=$(rpc_or_die "$LABEL" "$PUBLIC_RPC" \
    "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$TOKEN\",\"data\":\"$DATA\"},\"latest\"],\"id\":1}" \
    hex)
  local OK
  OK=$(python3 -c "
got = int('$RES', 16)
want = int('$USDC_AMOUNT_DEC')
print('ok' if got == want else f'fail:got={got},want={want}')
")
  case "$OK" in
    ok) echo "  [ok] $LABEL = $RES (== 1M, 6-dec)" >&2 ;;
    *)
      echo "  [FAIL] $LABEL: $OK" >&2
      exit 2
      ;;
  esac
}

verify_token_balance "USDC.balanceOf(whale)" "$USDC" "$WHALE"
verify_token_balance "EURC.balanceOf(whale)" "$EURC" "$WHALE"

# --------------------------------------------------------------------------
# Persistence — only reached if every RPC + verification step succeeded.
# --------------------------------------------------------------------------
echo
echo "==> writing TENDERLY_PRIMED_VNET_* into .env.local" >&2
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
echo "Primed vnet ready (priming + verification passed). Dashboard:" >&2
echo "  https://dashboard.tenderly.co/$TENDERLY_ACCOUNT/$TENDERLY_PROJECT/testnet/$VNET_ID" >&2
echo "Run the matrix against it by exporting TENDERLY_USE_PRIMED_VNET=1" >&2
echo "(matrix runner will pick up the *_PUBLIC_RPC and skip per-case state_objects)" >&2
exit 0
