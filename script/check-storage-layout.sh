#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$ROOT_DIR/test/fixtures/WeightedRateERC1155CollectionPool.storage-layout.json"
CURRENT="$(mktemp)"
BASELINE_NORMALIZED="$(mktemp)"
CURRENT_NORMALIZED="$(mktemp)"
trap 'rm -f "$CURRENT" "$BASELINE_NORMALIZED" "$CURRENT_NORMALIZED"' EXIT

cd "$ROOT_DIR"

forge inspect \
  contracts/configurations/WeightedRateERC1155CollectionPool.sol:WeightedRateERC1155CollectionPool \
  storage-layout \
  --json > "$CURRENT"

jq '
  def normalize_type_ids:
    if type == "string" then
      gsub("\\)[0-9]+_storage"; ")_storage") | gsub("\\)[0-9]+"; ")")
    else
      .
    end;
  def normalize_layout:
    if type == "object" then
      with_entries(select(.key != "astId") | .key |= normalize_type_ids | .value |= normalize_layout)
    elif type == "array" then
      map(normalize_layout)
    else
      normalize_type_ids
    end;
  normalize_layout
' "$BASELINE" > "$BASELINE_NORMALIZED"
jq '
  def normalize_type_ids:
    if type == "string" then
      gsub("\\)[0-9]+_storage"; ")_storage") | gsub("\\)[0-9]+"; ")")
    else
      .
    end;
  def normalize_layout:
    if type == "object" then
      with_entries(select(.key != "astId") | .key |= normalize_type_ids | .value |= normalize_layout)
    elif type == "array" then
      map(normalize_layout)
    else
      normalize_type_ids
    end;
  normalize_layout
' "$CURRENT" > "$CURRENT_NORMALIZED"

diff -u "$BASELINE_NORMALIZED" "$CURRENT_NORMALIZED"
echo "OK: WeightedRateERC1155CollectionPool storage layout matches baseline"
