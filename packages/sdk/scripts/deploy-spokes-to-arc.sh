#!/usr/bin/env bash
# Deploys one additional FxSpoke per chain, routed to the Arc hub.
# Additive — does NOT touch the existing Fuji-routed spokes.
#
# Reads DEPLOYER_PRIVATE_KEY from env. Idempotent in the sense that each run
# creates a new spoke (broadcast artifacts kept in contracts/broadcast/).

set -uo pipefail

ARC_HUB_RECEIVER="${ARC_HUB_RECEIVER:-0x4FBe4cc4ab09648d65195f5B9490D20D12D49a2c}"
ARC_HUB_DOMAIN="${ARC_HUB_DOMAIN:-26}"

CHAINS=(
  "ethereum-sepolia|https://ethereum-sepolia-rpc.publicnode.com|11155111"
  "op-sepolia|https://sepolia.optimism.io|11155420"
  "arbitrum-sepolia|https://sepolia-rollup.arbitrum.io/rpc|421614"
  "polygon-amoy|https://rpc-amoy.polygon.technology|80002"
  "unichain-sepolia|https://sepolia.unichain.org|1301"
  "worldchain-sepolia|https://worldchain-sepolia.g.alchemy.com/public|4801"
  "avalanche-fuji|https://api.avax-test.network/ext/bc/C/rpc|43113"
  "arc-testnet|https://rpc.testnet.arc.network|5042002"
)

OUT_FILE="${OUT_FILE:-deployments/.arc-spokes-deploy-log.tsv}"
mkdir -p "$(dirname "$OUT_FILE")"
echo -e "chain\tchainId\tnewSpoke\ttxHash" > "$OUT_FILE"

for entry in "${CHAINS[@]}"; do
  IFS="|" read -r name rpc chainid <<<"$entry"
  echo ""
  echo "── $name (chainId $chainid) → Arc hub ──"

  legacy_flag=""
  if [ "$chainid" = "5042002" ] || [ "$chainid" = "43113" ]; then
    legacy_flag="--legacy"
  fi

  HUB_RECEIVER="$ARC_HUB_RECEIVER" HUB_DOMAIN="$ARC_HUB_DOMAIN" \
    forge script contracts/script/DeployFxSpoke.s.sol:DeployFxSpoke \
      --rpc-url "$rpc" --broadcast --slow --root contracts $legacy_flag \
      > /tmp/spoke-deploy-"$chainid".log 2>&1
  status=$?

  if [ "$status" -ne 0 ]; then
    echo "  FAIL (forge script exit $status). See /tmp/spoke-deploy-$chainid.log"
    echo -e "$name\t$chainid\tERROR\t-" >> "$OUT_FILE"
    continue
  fi

  artifact="contracts/broadcast/DeployFxSpoke.s.sol/$chainid/run-latest.json"
  if [ ! -f "$artifact" ]; then
    echo "  FAIL (no broadcast artifact)"
    echo -e "$name\t$chainid\tNO_ARTIFACT\t-" >> "$OUT_FILE"
    continue
  fi

  addr=$(python3 -c "import json,sys
d=json.load(open('$artifact'))
for t in d.get('transactions',[]):
    if t.get('transactionType')=='CREATE' and t.get('contractName')=='FxSpoke':
        print(t.get('contractAddress'));break" 2>/dev/null)
  tx=$(python3 -c "import json,sys
d=json.load(open('$artifact'))
for t in d.get('transactions',[]):
    if t.get('transactionType')=='CREATE' and t.get('contractName')=='FxSpoke':
        print(t.get('hash'));break" 2>/dev/null)

  if [ -z "$addr" ]; then
    echo "  FAIL (could not parse address)"
    echo -e "$name\t$chainid\tPARSE_ERR\t-" >> "$OUT_FILE"
    continue
  fi

  echo "  → FxSpoke (Arc-routed) $addr  tx $tx"
  echo -e "$name\t$chainid\t$addr\t$tx" >> "$OUT_FILE"
done

echo ""
echo "Done. Summary at $OUT_FILE:"
column -t -s $'\t' "$OUT_FILE"
