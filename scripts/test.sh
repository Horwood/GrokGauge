#!/usr/bin/env bash
# Run the unit tests. Works with Xcode or with Command Line Tools only
# (CLT ships swift-testing in a framework folder SwiftPM doesn't search by default).
set -euo pipefail
cd "$(dirname "$0")/.."
args=(--build-system "${SWIFT_BUILD_SYSTEM:-native}")
CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
if [[ "$(xcode-select -p 2>/dev/null)" == "/Library/Developer/CommandLineTools" && -d "$CLT_FW" ]]; then
  args+=(-Xswiftc -F -Xswiftc "$CLT_FW" -Xlinker -F -Xlinker "$CLT_FW" -Xlinker -rpath -Xlinker "$CLT_FW")
fi
exec swift test "${args[@]}" "$@"
