#!/usr/bin/env bash
# FX Pyth pusher — keeps the FxOracle's spot-FX Pyth feeds fresh on Arc.
#
# WHY: Pyth is pull-based. The FxOracle (0x77b3A3…) reads
# PYTH.getPriceNoOlderThan(feedId, maxOracleAge=60s); if nothing pushes the
# feed on-chain it goes stale and getMid() reverts → FxSwapHook swaps revert.
# Chainlink/RedStone push feeds don't exist on Arc, so we push Pyth ourselves.
#
# Pushes the exact feeds FxOracle.pythFeedOf() returns for USDC / EURC / AUDF
# (one merged Hermes VAA → IPyth.updatePriceFeeds{value: fee}). MXNB/QCAD are
# NOT included — their FxOracle pyth feed isn't wired (MXNB) / has no Arc Pyth
# feed (CAD); wire those separately before adding them here.
#
# Run (background):
#   ARC_RPC_URL=… PYTH_PUSHER_PRIVATE_KEY=0x… ./pyth-fx-pusher.sh
#
# Env:
#   ARC_RPC_URL                required
#   PYTH_PUSHER_PRIVATE_KEY    required; EOA must hold USDC (native gas + update fee)
#   PYTH_ADDRESS               default 0x2880aB155794e7179c9eE2e38200202908C17B43
#   PYTH_PUSH_INTERVAL         seconds between pushes (default 20; < oracle 60s window)
set -uo pipefail   # NOT -e: the loop must survive transient RPC/Hermes errors

PYTH="${PYTH_ADDRESS:-0x2880aB155794e7179c9eE2e38200202908C17B43}"
RPC="${ARC_RPC_URL:?set ARC_RPC_URL}"
PK="${PYTH_PUSHER_PRIVATE_KEY:?set PYTH_PUSHER_PRIVATE_KEY}"
INTERVAL="${PYTH_PUSH_INTERVAL:-20}"
HERMES="https://hermes.pyth.network/v2/updates/price/latest"

# FxOracleV2 feeds: USDC/USD, EURC/USD, AUD/USD, USD/MXN (MXN priced inverted on the oracle)
FEEDS=(
  0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a
  0x76fa85158bf14ede77087fe3ae472f66213f6ea2f5b411cb2de472794990fa5c
  0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80
  0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca
)
Q=""; for f in "${FEEDS[@]}"; do Q="${Q}ids[]=${f}&"; done; Q="${Q}encoding=hex"

echo "$(date +%T) pyth-fx-pusher up: ${#FEEDS[@]} feeds, every ${INTERVAL}s, signer $(cast wallet address --private-key "$PK")"
while true; do
  vaa=$(curl -s -m 8 "${HERMES}?${Q}" | jq -r '.binary.data[0] // empty' 2>/dev/null)
  if [ -n "$vaa" ]; then
    data="[0x${vaa}]"
    fee=$(cast call "$PYTH" 'getUpdateFee(bytes[])(uint256)' "$data" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
    [ -z "$fee" ] && fee=1
    if tx=$(cast send "$PYTH" 'updatePriceFeeds(bytes[])' "$data" --value "$fee" --private-key "$PK" --rpc-url "$RPC" --json 2>/dev/null); then
      echo "$(date +%T) pushed (fee=$fee) $(echo "$tx" | jq -r .transactionHash 2>/dev/null)"
    else
      echo "$(date +%T) push failed (nonce/RPC) — retry next loop"
    fi
  else
    echo "$(date +%T) hermes fetch failed — retry next loop"
  fi
  sleep "$INTERVAL"
done
