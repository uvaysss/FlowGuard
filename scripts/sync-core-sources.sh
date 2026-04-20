#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
MANIFEST="$ROOT_DIR/FlowGuardCoreTests/core_sources_manifest.tsv"
TARGET_DIR="$ROOT_DIR/FlowGuardCoreTests/CoreSources"

if [[ ! -f "$MANIFEST" ]]; then
  echo "Manifest not found: $MANIFEST" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

find "$TARGET_DIR" -maxdepth 1 -type l -name "Core_*.swift" -exec rm -f {} +

while IFS=$'\t' read -r link_name relative_target; do
  [[ -z "${link_name:-}" ]] && continue
  [[ "$link_name" =~ ^# ]] && continue

  ln -s "$relative_target" "$TARGET_DIR/$link_name"
done < "$MANIFEST"
