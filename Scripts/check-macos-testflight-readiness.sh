#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
INFO="$ROOT/Sources/iAgentPanel/Info.plist"
ENTITLEMENTS="$ROOT/Sources/iAgentPanel/iAgentPanelTestFlight.entitlements"
EXPECTED_BUNDLE_ID="com.platon.iagent-panel"
EXPECTED_CONTAINER="iCloud.com.platon.iagent"
EXPECTED_CATEGORY="public.app-category.developer-tools"
EXPECTED_ICON="iAgentPanel.icns"
ICON_SOURCE="$ROOT/Sources/iAgentPanel/Resources/$EXPECTED_ICON"
SANDBOX_ACCESS_SOURCE="$ROOT/Sources/iAgentPanel/SandboxAccessManager.swift"
APP_SOURCE="$ROOT/Sources/iAgentPanel/iAgentPanelApp.swift"
ICON_CHECK_ROOT="$(mktemp -d /private/tmp/iagent-icon-readiness.XXXXXX)"

cleanup() {
  /bin/rm -rf -- "$ICON_CHECK_ROOT"
}
trap cleanup EXIT

fail() {
  print -u2 -- "macOS TestFlight readiness check failed: $1"
  exit 1
}

plist_nonempty() {
  local key="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO" 2>/dev/null || true)"
  [[ -n "$value" ]] || fail "$key is missing or empty"
}

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "$EXPECTED_BUNDLE_ID" ]] \
  || fail "unexpected bundle identifier"
plist_nonempty CFBundleShortVersionString
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
[[ "$BUILD_NUMBER" == <-> && "$BUILD_NUMBER" -gt 13 ]] \
  || fail "CFBundleVersion must be an integer greater than uploaded build 13"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$INFO")" == "$EXPECTED_CATEGORY" ]] \
  || fail "LSApplicationCategoryType must be $EXPECTED_CATEGORY"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO")" == "$EXPECTED_ICON" ]] \
  || fail "CFBundleIconFile must be $EXPECTED_ICON"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$INFO")" == "false" ]] \
  || fail "ITSAppUsesNonExemptEncryption must be false"
plist_nonempty NSMicrophoneUsageDescription
plist_nonempty NSSpeechRecognitionUsageDescription
plist_nonempty NSScreenCaptureUsageDescription
plist_nonempty NSAudioCaptureUsageDescription
plist_nonempty NSCalendarsFullAccessUsageDescription
plist_nonempty NSContactsUsageDescription

[[ -f "$ICON_SOURCE" ]] || fail "$EXPECTED_ICON is missing"
/usr/bin/iconutil -c iconset -o "$ICON_CHECK_ROOT/iAgentPanel.iconset" "$ICON_SOURCE" \
  || fail "$EXPECTED_ICON is not a valid ICNS file"
ICON_2X="$ICON_CHECK_ROOT/iAgentPanel.iconset/icon_512x512@2x.png"
[[ -f "$ICON_2X" ]] || fail "$EXPECTED_ICON lacks a 512pt @2x representation"
[[ "$(/usr/bin/sips -g pixelWidth "$ICON_2X" 2>/dev/null | /usr/bin/awk '/pixelWidth/ { print $2 }')" == "1024" ]] \
  || fail "$EXPECTED_ICON 512pt @2x representation is not 1024 pixels wide"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS")" == "true" ]] \
  || fail "App Sandbox is required"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS")" == "true" ]] \
  || fail "App Sandbox Audio Input access is required"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.personal-information.calendars' "$ENTITLEMENTS")" == "true" ]] \
  || fail "App Sandbox Calendar access is required"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.personal-information.addressbook' "$ENTITLEMENTS")" == "true" ]] \
  || fail "Contacts access is required for message participant names"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$ENTITLEMENTS")" == "true" ]] \
  || fail "user-selected read/write access is required for the local library"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.bookmarks.app-scope' "$ENTITLEMENTS")" == "true" ]] \
  || fail "app-scoped security bookmarks are required for persistent folder access"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$ENTITLEMENTS")" == "true" ]] \
  || fail "outbound network access is required for CloudKit"
ENTITLEMENT_TEXT="$(plutil -p "$ENTITLEMENTS")"
[[ "$ENTITLEMENT_TEXT" == *"$EXPECTED_CONTAINER"* ]] || fail "CloudKit container is missing"
[[ "$ENTITLEMENT_TEXT" == *'"Production"'* ]] || fail "CloudKit Production is missing"

[[ -f "$SANDBOX_ACCESS_SOURCE" ]] || fail "SandboxAccessManager is missing"
/usr/bin/grep -F 'SandboxAccessManager.shared.prepareForLaunch()' "$APP_SOURCE" >/dev/null \
  || fail "sandbox bookmark restoration must run before PanelController initialization"

if ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
  | /usr/bin/grep -Eq 'Apple Distribution|3rd Party Mac Developer Application'; then
  fail "no Mac App Store distribution signing identity is installed"
fi
if ! /usr/bin/security find-certificate -a -c '3rd Party Mac Developer Installer' >/dev/null 2>&1 \
  && ! /usr/bin/security find-certificate -a -c 'Mac Installer Distribution' >/dev/null 2>&1; then
  fail "no Mac App Store installer signing identity is installed"
fi

print -- "Static macOS TestFlight metadata, privacy keys, and entitlements are ready for build $BUILD_NUMBER."
