#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/.build/iAgentPanel.app"
CONTENTS="$APP/Contents"

cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/iagent-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/iagent-swift-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/private/tmp/iagent-swift-cache}"
swift "$ROOT/Scripts/generate-calendar-day-assets.swift"
swift build --disable-sandbox

mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
cp "$ROOT/.build/debug/iAgentPanel" "$CONTENTS/MacOS/iAgentPanel"
cp "$ROOT/Sources/iAgentPanel/Info.plist" "$CONTENTS/Info.plist"
for bundle in "$ROOT"/.build/debug/*.bundle; do
  ditto "$bundle" "$CONTENTS/Resources/${bundle:t}"
done
codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$ROOT/Sources/iAgentPanel/iAgentPanel.entitlements" \
  --requirements '=designated => identifier "com.platon.iagent-panel"' \
  "$APP"

print "$APP"
