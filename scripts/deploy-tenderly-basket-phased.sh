#!/usr/bin/env bash
#
# Phased Tenderly Avalanche Fuji basket broadcast.
#
# Splits the monolithic DeployTenderlyAvalancheBasket.s.sol into 7 forge
# invocations spaced by sleeps to stay under the Tenderly Pro per-second
# TUs ceiling. After each phase the per-phase JSON sub-manifest is merged
# into the canonical manifest at deployments/tenderly-avalanche-fuji-basket.json
# so subsequent phases can vm.readFile their predecessors' outputs.
#
# Required env (do not commit):
#   TENDERLY_FUJI_ADMIN_RPC   bearer-tokenized admin RPC for the active vnet
#   DEPLOYER_PRIVATE_KEY      funded key on the active vnet
#
# Optional env:
#   FXT_PHASE_SLEEP            seconds between phases (default 60)
#   FXT_PHASE_ASSETS           space-separated list of assets to deploy
#                              (default "JPYC MXNB AUDF KRW1 ZCHF")
#   FXT_SKIP_PHASES            comma-separated phase slugs to skip (idempotency)

set -euo pipefail

if [[ -z "${TENDERLY_FUJI_ADMIN_RPC:-}" ]]; then
  echo "FATAL: TENDERLY_FUJI_ADMIN_RPC not set" >&2
  exit 1
fi
if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "FATAL: DEPLOYER_PRIVATE_KEY not set" >&2
  exit 1
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO/contracts"

SLEEP_SECS="${FXT_PHASE_SLEEP:-60}"
ASSETS="${FXT_PHASE_ASSETS:-JPYC MXNB AUDF KRW1 ZCHF}"
SKIP_PHASES="${FXT_SKIP_PHASES:-}"

PHASES_DIR="$REPO/deployments/_tenderly-basket-phases"
MANIFEST="$REPO/deployments/tenderly-avalanche-fuji-basket.json"
mkdir -p "$PHASES_DIR"

export FXT_BASKET_MANIFEST="$MANIFEST"
export FXT_BASKET_PHASES_DIR="$PHASES_DIR"

# Initialize the canonical manifest with an empty JSON object if missing —
# Phase 2+ scripts call vm.readFile on it for upstream addresses.
if [[ ! -f "$MANIFEST" ]]; then
  echo '{}' > "$MANIFEST"
fi

skip() {
  local slug="$1"
  case ",$SKIP_PHASES," in *",$slug,"*) return 0 ;; esac
  [[ -f "$PHASES_DIR/$slug.json" ]] && {
    echo "[skip] $slug already has sub-manifest"
    return 0
  }
  return 1
}

merge_manifest() {
  local slug="$1"
  local sub="$PHASES_DIR/$slug.json"
  [[ -f "$sub" ]] || { echo "[merge] $slug sub-manifest missing — phase failed?" >&2; return 1; }
  # jq -s 'add' merges keys; later files win on conflict. Order: manifest, sub.
  local tmp
  tmp="$(mktemp)"
  jq -s '.[0] * .[1]' "$MANIFEST" "$sub" > "$tmp"
  mv "$tmp" "$MANIFEST"
  echo "[merge] $slug merged into $MANIFEST"
}

run_phase() {
  local slug="$1"
  local contract_path="$2"
  shift 2

  if skip "$slug"; then
    merge_manifest "$slug" || true
    return 0
  fi

  echo "[phase] $slug → $contract_path"
  forge script "$contract_path" \
    --rpc-url "$TENDERLY_FUJI_ADMIN_RPC" \
    --broadcast --slow --legacy \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$@"
  merge_manifest "$slug"
  echo "[sleep] waiting ${SLEEP_SECS}s before next phase"
  sleep "$SLEEP_SECS"
}

# Phase 1 — core
run_phase phase1-core \
  "script/DeployTenderlyBasket/Phase1_Core.s.sol:Phase1_Core"

# Phase 2 — per-asset pairs
for asset in $ASSETS; do
  FXT_PHASE_ASSET="$asset" \
    run_phase "phase2-$asset" \
    "script/DeployTenderlyBasket/Phase2_AddPair.s.sol:Phase2_AddPair"
done

# Phase 3 — governance handoff (we just slept after Phase 2-final; skip the
# pre-Phase-3 sleep)
SLEEP_SECS=0 \
  run_phase phase3-handoff \
  "script/DeployTenderlyBasket/Phase3_Handoff.s.sol:Phase3_Handoff"

echo
echo "============================================"
echo "Tenderly Avalanche basket phased broadcast complete"
echo "Manifest: $MANIFEST"
echo "Sub-manifests: $PHASES_DIR/"
echo "============================================"
