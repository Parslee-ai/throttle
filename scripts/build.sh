#!/usr/bin/env bash
# Builds Throttle.app in Release from a clean checkout.
# Output: build/Throttle.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED="build/DerivedData"
PRODUCT="$DERIVED/Build/Products/Release/Throttle.app"

mkdir -p build

xcodebuild \
  -project Throttle.xcodeproj \
  -scheme Throttle \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [ ! -d "$PRODUCT" ]; then
  echo "error: expected product not found at $PRODUCT" >&2
  exit 1
fi

rm -rf build/Throttle.app
cp -R "$PRODUCT" build/Throttle.app

echo "Built build/Throttle.app"
