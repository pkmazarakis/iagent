#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SIGNING_IDENTITY="${IAGENT_CODESIGN_IDENTITY:--}"
PROVISIONING_PROFILE="${IAGENT_PROVISIONING_PROFILE:-}"
ENTITLEMENTS="${IAGENT_CODESIGN_ENTITLEMENTS:-$ROOT/Sources/iAgentPanel/iAgentPanelRelease.entitlements}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  DEFAULT_APP="$ROOT/.build/iAgentPanel.app"
else
  DEFAULT_APP="$ROOT/.build/iAgentPanel-Production.app"
fi
APP="${IAGENT_APP_OUTPUT_PATH:-$DEFAULT_APP}"
CONTENTS="$APP/Contents"
SWIFTPM_SCRATCH_PATH="${IAGENT_SWIFTPM_SCRATCH_PATH:-$ROOT/.build}"
SWIFTPM_SCRATCH_PATH="${SWIFTPM_SCRATCH_PATH:A}"
if [[ -n "${IAGENT_BUILD_CONFIGURATION:-}" ]]; then
  BUILD_CONFIGURATION="$IAGENT_BUILD_CONFIGURATION"
elif [[ "$SIGNING_IDENTITY" == "-" ]]; then
  BUILD_CONFIGURATION="debug"
else
  BUILD_CONFIGURATION="release"
fi

if [[ "$BUILD_CONFIGURATION" != "debug" && "$BUILD_CONFIGURATION" != "release" ]]; then
  print -u2 -- "IAGENT_BUILD_CONFIGURATION must be debug or release."
  exit 2
fi
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  if [[ -z "$PROVISIONING_PROFILE" || ! -f "$PROVISIONING_PROFILE" ]]; then
    print -u2 -- "Set IAGENT_PROVISIONING_PROFILE to a CloudKit-enabled macOS distribution profile."
    exit 2
  fi
  if [[ ! -f "$ENTITLEMENTS" ]]; then
    print -u2 -- "Code-signing entitlements do not exist at $ENTITLEMENTS."
    exit 2
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$ENTITLEMENTS" 2>/dev/null || true)" != "true" ]]; then
    print -u2 -- "Code-signing entitlements must allow Apple Events automation for direct Messages sends."
    exit 2
  fi
fi
if [[ "${IAGENT_REQUIRE_FRESH_APP:-0}" == "1" && -e "$APP" ]]; then
  print -u2 -- "Refusing to reuse an existing app staging path: $APP"
  exit 2
fi

cd "$ROOT"
mkdir -p "$SWIFTPM_SCRATCH_PATH/module-cache/clang" "$SWIFTPM_SCRATCH_PATH/module-cache/swift"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$SWIFTPM_SCRATCH_PATH/module-cache/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$SWIFTPM_SCRATCH_PATH/module-cache/swift}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$SWIFTPM_SCRATCH_PATH/module-cache/swift}"
swift "$ROOT/Scripts/generate-calendar-day-assets.swift"
SWIFT_BUILD_ARGS=(
  --configuration "$BUILD_CONFIGURATION"
  --disable-sandbox
  --disable-build-manifest-caching
  --scratch-path "$SWIFTPM_SCRATCH_PATH"
)
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
if [[ ! -x "$BIN_PATH/iAgentPanel" ]]; then
  print -u2 -- "Built iAgentPanel executable is missing at $BIN_PATH/iAgentPanel."
  exit 2
fi

mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
cp "$BIN_PATH/iAgentPanel" "$CONTENTS/MacOS/iAgentPanel"
cp "$ROOT/Sources/iAgentPanel/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Sources/iAgentPanel/Resources/iAgentPanel.icns" "$CONTENTS/Resources/iAgentPanel.icns"
for bundle in "$BIN_PATH"/*.bundle; do
  ditto "$bundle" "$CONTENTS/Resources/${bundle:t}"
done

PANEL_RESOURCE_BUNDLE="$CONTENTS/Resources/iAgentPanel_iAgentPanel.bundle"
EXPECTED_PANEL_RESOURCES=(
  "Brand/openai-blossom.svg"
  "Brand/message-circle.svg"
  "Brand/message-cloud-check.svg"
  "Brand/message-cloud-sync-arrows.svg"
  "Brand/message-cloud-sync-cloud.svg"
  "CalendarDays/calendar-outline.svg"
  "CalendarDays/calendar-digit-0.svg"
  "ThirdPartyNotices/openclaw-imsg-LICENSE.txt"
)
if [[ ! -d "$PANEL_RESOURCE_BUNDLE" ]]; then
  print -u2 -- "Packaged SwiftPM resource bundle is missing at $PANEL_RESOURCE_BUNDLE."
  exit 2
fi
for resource in "${EXPECTED_PANEL_RESOURCES[@]}"; do
  if [[ ! -f "$PANEL_RESOURCE_BUNDLE/$resource" ]]; then
    print -u2 -- "Packaged SwiftPM resource is missing: $resource"
    exit 2
  fi
done

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  rm -f "$CONTENTS/embedded.provisionprofile"
else
  cp "$PROVISIONING_PROFILE" "$CONTENTS/embedded.provisionprofile"
fi

/usr/bin/xattr -dr com.apple.quarantine "$APP"
QUARANTINE_ENTRIES="$(/usr/bin/xattr -lr "$APP" 2>/dev/null \
  | /usr/bin/grep 'com.apple.quarantine:' || true)"
if [[ -n "$QUARANTINE_ENTRIES" ]]; then
  print -u2 -- "Staged app still contains com.apple.quarantine:"
  print -u2 -- "$QUARANTINE_ENTRIES"
  exit 2
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "com.platon.iagent-panel"' \
    "$APP"
else
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --requirements '=designated => identifier "com.platon.iagent-panel"' \
    "$APP"
  "$ROOT/Scripts/verify-macos-cloudkit-signing.sh" "$APP"
fi

print "$APP"
