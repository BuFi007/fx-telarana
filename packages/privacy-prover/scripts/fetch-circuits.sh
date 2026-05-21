#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0
#
# Fetch the Groth16 circuit artifacts for the fx-Telarana Privacy Hook.
# The verifying keys (.vkey.json files) are committed to this repo; the
# .wasm witness generators and .zkey proving keys are too large for git
# and are fetched here.
#
# All artifacts originate from the 0xbow privacy-pools-core trusted-setup
# ceremony output (commit a80836a4, May 2026). See
# docs/PRIVACY_HOOK_VENDOR_MAP.md for the exact upstream lineage.
#
# Usage:
#   ./scripts/fetch-circuits.sh                       # default URL
#   PROVER_CIRCUITS_BASE=https://my.cdn/ ./scripts/fetch-circuits.sh
#
# Override PROVER_CIRCUITS_BASE to mirror the artifacts on your own
# infrastructure for production / CI / air-gapped use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${SCRIPT_DIR}/../circuits"

# Default: GitHub raw on the upstream 0xbow repo, pinned to the audited
# commit recorded in PRIVACY_HOOK_VENDOR_MAP.md. Operators are strongly
# encouraged to mirror these to their own CDN and override
# PROVER_CIRCUITS_BASE for stability.
DEFAULT_BASE="https://raw.githubusercontent.com/0xbow-io/privacy-pools-core/a80836a47451e662f127af17e11430ffa976c234/packages/circuits"
BASE="${PROVER_CIRCUITS_BASE:-$DEFAULT_BASE}"

# (filename in target, source path under BASE, expected sha256)
ARTIFACTS=(
  "commitment.wasm:build/commitment/commitment_js/commitment.wasm:254d2130607182fd6fd1aee67971526b13cfe178c88e360da96dce92663828d8"
  "withdraw.wasm:build/withdraw/withdraw_js/withdraw.wasm:36cda22791def3d520a55c0fc808369cd5849532a75fab65686e666ed3d55c10"
  "commitment.zkey:trusted-setup/final-keys/commitment.zkey:494ae92d64098fda2a5649690ddc5821fcd7449ca5fe8ef99ee7447544d7e1f3"
  "withdraw.zkey:trusted-setup/final-keys/withdraw.zkey:2a893b42174c813566e5c40c715a8b90cd49fc4ecf384e3a6024158c3d6de677"
)

mkdir -p "$TARGET_DIR"

for entry in "${ARTIFACTS[@]}"; do
  local_name="${entry%%:*}"
  rest="${entry#*:}"
  src_path="${rest%%:*}"
  expected_sha="${rest##*:}"

  out="${TARGET_DIR}/${local_name}"
  url="${BASE}/${src_path}"

  if [ -f "$out" ]; then
    actual_sha="$(shasum -a 256 "$out" | awk '{print $1}')"
    if [ "$actual_sha" = "$expected_sha" ]; then
      echo "✔ ${local_name} already present (sha256 ok)"
      continue
    fi
    echo "× ${local_name} checksum mismatch — re-fetching"
  fi

  echo "↓ ${local_name} from ${url}"
  if command -v curl >/dev/null 2>&1; then
    curl -fSL "$url" -o "$out.tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$out.tmp"
  else
    echo "ERROR: need curl or wget to fetch ${local_name}" >&2
    exit 1
  fi

  actual_sha="$(shasum -a 256 "$out.tmp" | awk '{print $1}')"
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "ERROR: ${local_name} sha256 mismatch" >&2
    echo "  expected: $expected_sha" >&2
    echo "  got:      $actual_sha" >&2
    rm -f "$out.tmp"
    exit 1
  fi

  mv "$out.tmp" "$out"
  echo "✔ ${local_name} fetched + verified"
done

echo
echo "All circuit artifacts present in $TARGET_DIR:"
ls -la "$TARGET_DIR"
