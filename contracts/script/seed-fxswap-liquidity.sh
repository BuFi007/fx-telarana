#!/usr/bin/env bash
# Seed an FxSwapHook PMM pool (e.g. USDC/EURC on Arc Testnet) with a
# budget-capped, oracle-ratio-matched two-sided deposit.
#
# WHY a shell script and not the forge .s.sol:
#   Arc's native USDC (0x3600…) `transferFrom` calls the Arc blocklist
#   precompile at 0x1800…0001. `forge script` ALWAYS executes the whole
#   run() body in its local EVM first (to capture the broadcast tx set),
#   and that local execution StackUnderflows on the precompile — so a
#   forge broadcast can never move native USDC on Arc. `cast send`
#   estimates gas on the real node and sends raw, bypassing the local EVM.
#   The companion SeedFxSwapHookLiquidity.s.sol stays as the validated
#   reference for the math + a dry-run of the registry/ratio resolution.
#
# Usage:
#   ARC_RPC_URL=... KEEPER_PRIVATE_KEY=0x... \
#     ./seed-fxswap-liquidity.sh <USDC_BUDGET_6DEC> [QUOTE_SYMBOL] [--execute]
#
#   <USDC_BUDGET_6DEC>   USDC cap, 6-dec atoms (e.g. 100000000000 = 100k USDC)
#   [QUOTE_SYMBOL]       registry symbol of the paired token (default EURC)
#   [--execute]          actually broadcast; omit for a dry preview
#
# Env:
#   ARC_RPC_URL, KEEPER_PRIVATE_KEY      required
#   ASSET_REGISTRY                       default Arc 0x7618…efc
#   FX_SWAP_HOOK                         default USDC/EURC 0xC6F894…0aC8
set -euo pipefail

ARC_CHAIN_ID=5042002
ASSET_REGISTRY="${ASSET_REGISTRY:-0x7618dFA920B6416b9924FAFBf5AA56a6FE978efC}"
FX_SWAP_HOOK="${FX_SWAP_HOOK:-0xC6F894f30d0D28972C876B4af58C02A4E88A0aC8}"

USDC_BUDGET="${1:?usage: seed-fxswap-liquidity.sh <USDC_BUDGET_6DEC> [QUOTE_SYMBOL] [--execute]}"
QUOTE_SYMBOL="${2:-EURC}"
EXECUTE="${3:-}"
[ "${2:-}" = "--execute" ] && { QUOTE_SYMBOL="EURC"; EXECUTE="--execute"; }

: "${ARC_RPC_URL:?set ARC_RPC_URL}"
: "${KEEPER_PRIVATE_KEY:?set KEEPER_PRIVATE_KEY}"
RPC="$ARC_RPC_URL"; PK="$KEEPER_PRIVATE_KEY"

chain=$(cast chain-id --rpc-url "$RPC")
[ "$chain" = "$ARC_CHAIN_ID" ] || { echo "REFUSE: chain $chain != Arc $ARC_CHAIN_ID"; exit 1; }
OPERATOR=$(cast wallet address --private-key "$PK")

# --- Resolve token addresses from the registry (source of truth) ---
USDC=$(cast call "$ASSET_REGISTRY" 'tokenAddressOnChain(string,uint256)(address)' "USDC" "$ARC_CHAIN_ID" --rpc-url "$RPC")
QUOTE=$(cast call "$ASSET_REGISTRY" 'tokenAddressOnChain(string,uint256)(address)' "$QUOTE_SYMBOL" "$ARC_CHAIN_ID" --rpc-url "$RPC")

# --- Cross-check against the hook's configured pair ---
T0=$(cast call "$FX_SWAP_HOOK" 'TOKEN0()(address)' --rpc-url "$RPC")
T1=$(cast call "$FX_SWAP_HOOK" 'TOKEN1()(address)' --rpc-url "$RPC")
[ "$(echo $USDC | tr A-Z a-z)" = "$(echo $T0 | tr A-Z a-z)" ] || { echo "MISMATCH: registry USDC $USDC != hook TOKEN0 $T0"; exit 1; }
[ "$(echo $QUOTE | tr A-Z a-z)" = "$(echo $T1 | tr A-Z a-z)" ] || { echo "MISMATCH: registry $QUOTE_SYMBOL $QUOTE != hook TOKEN1 $T1"; exit 1; }

D0=$(cast call "$FX_SWAP_HOOK" 'TOKEN0_DECIMALS()(uint8)' --rpc-url "$RPC")
D1=$(cast call "$FX_SWAP_HOOK" 'TOKEN1_DECIMALS()(uint8)' --rpc-url "$RPC")
BASE=$(cast call "$FX_SWAP_HOOK" 'baseTargetE18()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
QUOTET=$(cast call "$FX_SWAP_HOOK" 'quoteTargetE18()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
SHARES=$(cast call "$FX_SWAP_HOOK" 'totalShares()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
[ "$SHARES" != "0" ] || { echo "REFUSE: pool not bootstrapped (run first owner deposit)"; exit 1; }

# --- Matched quote amount in E18 space then back to native (Python big-int) ---
AMOUNT0="$USDC_BUDGET"
AMOUNT1=$(python3 - "$AMOUNT0" "$D0" "$D1" "$BASE" "$QUOTET" <<'PY'
import sys
amount0, d0, d1, base, quote = (int(x) for x in sys.argv[1:6])
base0_e18 = amount0 * 10**(18 - d0)
amount1_e18 = base0_e18 * quote // base
print(amount1_e18 // 10**(18 - d1))
PY
)

BAL0=$(cast call "$USDC"  'balanceOf(address)(uint256)' "$OPERATOR" --rpc-url "$RPC" | awk '{print $1}')
BAL1=$(cast call "$QUOTE" 'balanceOf(address)(uint256)' "$OPERATOR" --rpc-url "$RPC" | awk '{print $1}')

echo "── seed plan ──────────────────────────────"
echo "  operator     $OPERATOR"
echo "  hook         $FX_SWAP_HOOK"
echo "  pair         USDC/$QUOTE_SYMBOL ($USDC / $QUOTE)"
echo "  ratio q/b    $(python3 -c "print($QUOTET/$BASE)") $QUOTE_SYMBOL per USDC"
echo "  USDC amount0 $AMOUNT0   (have $BAL0)"
echo "  $QUOTE_SYMBOL amount1 $AMOUNT1   (have $BAL1)"
echo "───────────────────────────────────────────"

[ "$BAL0" -ge "$AMOUNT0" ] || { echo "SHORT USDC: fund operator up to $AMOUNT0"; exit 1; }
[ "$BAL1" -ge "$AMOUNT1" ] || { echo "SHORT $QUOTE_SYMBOL: fund operator up to $AMOUNT1"; exit 1; }

if [ "$EXECUTE" != "--execute" ]; then
  echo "DRY RUN — preflight OK. Re-run with --execute to broadcast."
  exit 0
fi

# KEEPER often shares its nonce with the live matcher → transient
# `nonce too low` / `replacement transaction underpriced`. Retry, refetching
# the pending nonce each attempt (cast does this when --nonce is omitted).
send_retry() { # label, then cast send args
  local label="$1"; shift
  local i out
  for i in 1 2 3 4 5 6; do
    if out=$(cast send "$@" --private-key "$PK" --rpc-url "$RPC" --json 2>&1); then
      echo "  ${label} OK: $(echo "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["transactionHash"])' 2>/dev/null)"
      return 0
    fi
    echo "  ${label} try ${i}: $(echo "$out" | grep -oiE 'nonce too low|underpriced|revert|insufficient' | head -1) — retry"
    sleep 3
  done
  echo "  ${label} FAILED after retries"; return 1
}
send_retry "approve USDC ${AMOUNT0}"        "$USDC"  'approve(address,uint256)'  "$FX_SWAP_HOOK" "$AMOUNT0"
send_retry "approve ${QUOTE_SYMBOL} ${AMOUNT1}" "$QUOTE" 'approve(address,uint256)' "$FX_SWAP_HOOK" "$AMOUNT1"
send_retry "deposit(${AMOUNT0},${AMOUNT1})" "$FX_SWAP_HOOK" 'deposit(uint256,uint256)' "$AMOUNT0" "$AMOUNT1"
echo "new totalShares: $(cast call "$FX_SWAP_HOOK" 'totalShares()(uint256)' --rpc-url "$RPC")"
