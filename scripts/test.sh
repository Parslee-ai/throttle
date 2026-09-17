#!/usr/bin/env bash
# Runs the Throttle unit test target on this Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

xcodebuild test \
  -project Throttle.xcodeproj \
  -scheme Throttle \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData
