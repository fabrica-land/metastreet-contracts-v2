#!/usr/bin/env bash
#
# ENG-3306 — deployable-pool size gate.
#
# Fabrica deploys exactly ONE configuration from this fork:
# WeightedRateERC1155CollectionPool. Its runtime bytecode MUST fit under
# EIP-170 (24576 bytes). This script asserts that and is the authoritative
# size gate for the fork.
#
# Why this instead of `forge build --sizes` exit code: the 5 OTHER upstream
# pool configurations (WeightedRateCollectionPool, ...Merkle, ...Blast,
# ...NodePass, ...Set) are over EIP-170 at the runs=800 default and are kept
# byte-identical to upstream metastreet-contracts-v2 for audit fidelity.
# Fabrica does not deploy them, so a blanket `--sizes` exit-0 is neither
# achievable nor meaningful here. If a future phase deploys another config,
# that phase owns its own size fix and should extend CONTRACTS below.
#
# The pool only fits because it co-compiles at runs=1 in a unit alongside its
# sibling ecosystem (PoolFactory / EnglishAuctionCollateralLiquidator /
# SimpleSignedPriceOracle) — see the MECHANISM comment in foundry.toml. This
# gate exists to catch any regression in that composition.
set -euo pipefail

LIMIT=24576
# Contracts Fabrica deploys and therefore must fit under EIP-170.
CONTRACTS=("WeightedRateERC1155CollectionPool")
BUILD_PATHS=(
  "contracts/configurations/WeightedRateERC1155CollectionPool.sol"
  "contracts/PoolFactory.sol"
  "contracts/liquidators/EnglishAuctionCollateralLiquidator.sol"
  "contracts/oracle/SimpleSignedPriceOracle.sol"
  "script"
  "test"
)

cd "$(dirname "$0")/.."

# Make the measurement independent of whatever test/script compilation artifacts
# happened to exist before this gate ran.
forge clean

# `forge build --sizes` exits non-zero because the undeployed upstream configs
# are over EIP-170 (see header) — that exit code is expected and NOT the gate.
# Capture the JSON regardless; this script's own exit code is the gate.
SIZES_JSON="$(forge build --sizes --json "${BUILD_PATHS[@]}" 2>/dev/null || true)"
if [ -z "$SIZES_JSON" ]; then
  echo "FAIL: forge build produced no --sizes JSON output"
  exit 1
fi

fail=0
for c in "${CONTRACTS[@]}"; do
  size="$(printf '%s' "$SIZES_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
e=d.get('$c')
if e is None:
    print('MISSING'); sys.exit(0)
print(e['runtime_size'])
")"
  if [ "$size" = "MISSING" ]; then
    echo "FAIL: contract '$c' not found in forge build output"
    fail=1
    continue
  fi
  margin=$((LIMIT - size))
  if [ "$size" -le "$LIMIT" ]; then
    echo "OK:   $c runtime=${size}B  (EIP-170 limit ${LIMIT}B, margin ${margin}B)"
  else
    echo "FAIL: $c runtime=${size}B EXCEEDS EIP-170 limit ${LIMIT}B by $((size - LIMIT))B"
    fail=1
  fi
done

exit "$fail"
