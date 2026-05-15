#!/usr/bin/env bash
#
# Seed the canonical Telaraña Spider-Web basket manifest from an EXISTING
# hub-config-*.json so Phase 2 can layer multi-asset pairs (JPYC, MXNB,
# AUDF, KRW1, ZCHF) on top of the v1.2.x USDC/EURC hub stack already
# deployed on a real testnet.
#
# Usage:
#   bash scripts/bootstrap-basket-manifest.sh fuji
#   bash scripts/bootstrap-basket-manifest.sh arc
#
# The seeded manifest is written to:
#   deployments/<basket>-basket.json
#
# and Phase 2 scripts read it via FXT_BASKET_MANIFEST.

set -euo pipefail

PROFILE="${1:-fuji}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "$PROFILE" in
  fuji)
    HUB_CONFIG="$REPO/deployments/hub-config-fuji.json"
    DEPLOYMENT="$REPO/deployments/avalanche-fuji.json"
    MANIFEST="$REPO/deployments/fuji-l1-basket.json"
    NETWORK="avalanche-fuji"
    CHAIN_ID=43113
    ;;
  arc)
    HUB_CONFIG="$REPO/deployments/hub-config-arc.json"
    DEPLOYMENT="$REPO/deployments/arc-testnet.json"
    MANIFEST="$REPO/deployments/arc-l1-basket.json"
    NETWORK="arc-testnet"
    CHAIN_ID=5042002
    ;;
  *)
    echo "FATAL: unknown profile '$PROFILE' (expected fuji or arc)" >&2
    exit 1
    ;;
esac

if [[ ! -f "$HUB_CONFIG" ]]; then
  echo "FATAL: hub config not found: $HUB_CONFIG" >&2
  exit 1
fi

mkdir -p "$REPO/deployments/_basket-phases-$PROFILE"

# Map the hub-config shape into the canonical basket manifest shape that the
# Phase 2 + Phase 3 + Smoke scripts read via vm.parseJsonAddress.
#
# hub-config-fuji.json structure (read):
#   .hubStack.MorphoBlue       → MorphoBlue
#   .hubStack.IrmMock          → Irm
#   .hubStack.FxOracle         → FxOracle
#   .hubStack.FxMarketRegistry → FxMarketRegistry
#   .hubStack.FxLiquidator     → FxLiquidator
#   .hubStack.FxHubMessageReceiver → FxHubMessageReceiver
#   .external.USDC             → USDC
#   .external.Pyth             → MockPyth (real Pyth on Fuji; we map the
#                                slot name so Phase 2 can use it as a price
#                                oracle target — see note below)
#   .external.CctpMessageTransmitterV2 → CctpMessageTransmitterV2
#
# Phase 2 calls `MockPyth.setPrice(...)`. On real testnets where we use real
# Pyth, setPrice will revert (Pyth doesn't have a permissionless setter).
# Detect: if FXT_PRICE_SOURCE=real, skip the setPrice call inside Phase 2
# (env passed through forge). Otherwise the bootstrap also expects a separate
# MockPyth to have been deployed alongside the hub stack — fail loudly.
PYTH_SLOT="$(jq -r '.external.Pyth // empty' "$HUB_CONFIG")"
if [[ -z "$PYTH_SLOT" ]]; then
  echo "WARNING: $HUB_CONFIG has no .external.Pyth — Phase 2 setPrice will fail." >&2
fi

# The Phase 2 script expects PoolManager + PoolSwapTest to exist for v4 hook
# integration. v1.2.x Fuji hub stack does NOT include them — they're new in
# the basket. Phase 1 *partial* mode would deploy ONLY these two and merge in.
# For now we emit a placeholder and let the operator know.
POOL_MANAGER_PLACEHOLDER='"PoolManager": "0x0000000000000000000000000000000000000000"'

# Build the consolidated manifest. Uses jq -n to construct from scratch.
jq -n --arg network "$NETWORK" \
      --argjson chainId "$CHAIN_ID" \
      --arg deployer "$(jq -r '.deployer // ""' "$DEPLOYMENT")" \
      --arg morpho "$(jq -r '.hubStack.MorphoBlue // ""' "$HUB_CONFIG")" \
      --arg irm "$(jq -r '.hubStack.IrmMock // ""' "$HUB_CONFIG")" \
      --arg pyth "$PYTH_SLOT" \
      --arg usdc "$(jq -r '.external.USDC // ""' "$HUB_CONFIG")" \
      --arg oracle "$(jq -r '.hubStack.FxOracle // ""' "$HUB_CONFIG")" \
      --arg registry "$(jq -r '.hubStack.FxMarketRegistry // ""' "$HUB_CONFIG")" \
      --arg liq "$(jq -r '.hubStack.FxLiquidator // ""' "$HUB_CONFIG")" \
      --arg recv "$(jq -r '.hubStack.FxHubMessageReceiver // ""' "$HUB_CONFIG")" \
      --arg cctp "$(jq -r '.external.CctpMessageTransmitterV2 // ""' "$HUB_CONFIG")" \
      '{
        network: $network,
        chainId: $chainId,
        deployer: $deployer,
        MorphoBlue: $morpho,
        Irm: $irm,
        MockPyth: $pyth,
        USDC: $usdc,
        FxOracle: $oracle,
        FxMarketRegistry: $registry,
        FxLiquidator: $liq,
        FxHubMessageReceiver: $recv,
        CctpMessageTransmitterV2: $cctp,
        PoolManager: "0x0000000000000000000000000000000000000000",
        PoolSwapTest: "0x0000000000000000000000000000000000000000",
        feed_USDC: "0x0000000000000000000000000000000000000000000000000000000000000000",
        notes: "Bootstrapped from hub-config; PoolManager/PoolSwapTest must be added before Phase 2 hooks can deploy. setPrice calls will fail against real Pyth — use FXT_PRICE_SOURCE=real to skip."
      }' > "$MANIFEST"

echo
echo "Bootstrapped basket manifest at: $MANIFEST"
echo
echo "Existing hub stack contents:"
jq '. | {network, chainId, deployer, FxOracle, FxMarketRegistry, FxLiquidator, FxHubMessageReceiver, USDC, MorphoBlue, MockPyth}' "$MANIFEST"
echo
echo "Next steps:"
echo "  1. Deploy a fresh Uniswap v4 PoolManager + PoolSwapTest on $NETWORK"
echo "     (or set existing addresses by editing the manifest .PoolManager / .PoolSwapTest)."
echo "  2. Deploy a MockPyth or wire real Pyth (see FXT_PRICE_SOURCE note)."
echo "  3. Run Phase 2 per asset:"
echo "       FXT_BASKET_MANIFEST=$MANIFEST \\"
echo "       FXT_PHASE_ASSET=JPYC \\"
echo "       forge script script/DeployTenderlyBasket/Phase2_AddPair.s.sol:Phase2_AddPair \\"
echo "         --rpc-url \$RPC --broadcast --slow --legacy --private-key \$KEY"
echo "  4. Then Phase 3 + Smoke."
