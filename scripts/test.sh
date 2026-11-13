#!/usr/bin/env bash
# Runs the Throttle unit test target on this Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# A test that never ends is stopped and failed after a minute, so the run
# reports it instead of hanging. The slowest test takes about ten seconds.
xcodebuild test \
  -project Throttle.xcodeproj \
  -scheme Throttle \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60
