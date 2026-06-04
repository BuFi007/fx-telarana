#!/usr/bin/env bash
# Persistent Arbitrum One Pyth pusher wrapper — keeps the MXNB/USDC Morpho
# market oracle (USD/MXN + USDC/USD) fresh. Run under launchd/systemd/pm2.
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
set -a; . /Users/criptopoeta/coding-dojo/defi-web-app/.env.local 2>/dev/null; set +a
export PYTH_PUSHER_RPC_URL="${ARBITRUM_RPC_URL:-https://arb1.arbitrum.io/rpc}"
export PYTH_ADDRESS="0xff1a0f4744e8582DF1aE09D5611b887B6a12925C"
export PYTH_FEEDS="0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a 0xe13b1c1ffb32f34e1be9545583f01ef385fde7f42ee66049d30570dc866b77ca"
export PYTH_PUSH_INTERVAL=120
case "${KEEPER_PRIVATE_KEY:-}" in 0x*) export PYTH_PUSHER_PRIVATE_KEY="$KEEPER_PRIVATE_KEY";; *) export PYTH_PUSHER_PRIVATE_KEY="0x$KEEPER_PRIVATE_KEY";; esac
exec bash contracts/script/pyth-fx-pusher.sh
