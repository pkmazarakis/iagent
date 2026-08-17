#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_IDENTITY="${IAGENT_MAC_APP_DISTRIBUTION_IDENTITY:-}"
INSTALLER_IDENTITY="${IAGENT_MAC_INSTALLER_IDENTITY:-}"
PROFILE="${IAGENT_MAC_APP_STORE_PROFILE:-}"
ENTITLEMENTS="$ROOT/Sources/iAgentPanel/iAgentPanelTestFlight.entitlements"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DESTINATION="$ROOT/.build/TestFlight/$STAMP"
STAGING_APP="$DESTINATION/staging/iAgentPanel.app"
ARCHIVE="$DESTINATION/iAgentPanel.xcarchive"
ARCHIVED_APP="$ARCHIVE/Products/Applications/iAgentPanel.app"
PKG="$DESTINATION/iAgentPanel.pkg"
SWIFTPM_SCRATCH="$(mktemp -d /private/tmp/iagent-testflight-swiftpm.XXXXXX)"
EMBEDDED_INFO_PLIST="$(mktemp /private/tmp/iagent-embedded-info.XXXXXX)"

fail() { print -u2 -- "macOS TestFlight archive failed: $1"; exit 1 }

[[ -n "$APP_IDENTITY" ]] || fail "set IAGENT_MAC_APP_DISTRIBUTION_IDENTITY"
[[ -n "$INSTALLER_IDENTITY" ]] || fail "set IAGENT_MAC_INSTALLER_IDENTITY"
[[ -f "$PROFILE" ]] || fail "set IAGENT_MAC_APP_STORE_PROFILE to a macOS App Store profile"
/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "$APP_IDENTITY" >/dev/null \
  || fail "application distribution identity is not installed"
/usr/bin/security find-certificate -a -c "$INSTALLER_IDENTITY" >/dev/null \
  || fail "installer distribution identity is not installed"

PROFILE_PLIST="$(mktemp /private/tmp/iagent-macos-profile.XXXXXX)"
PACKAGE_CHECK_ROOT="$(mktemp -d /private/tmp/iagent-package-quarantine.XXXXXX)"

cleanup() {
  rm -f "$PROFILE_PLIST"
  rm -f "$EMBEDDED_INFO_PLIST"
  /bin/rm -rf -- "$PACKAGE_CHECK_ROOT"
  /bin/rm -rf -- "$SWIFTPM_SCRATCH"
}
trap cleanup EXIT

assert_no_quarantine() {
  local target="$1"
  local label="$2"
  local quarantine_entries
  quarantine_entries="$(/usr/bin/xattr -lr "$target" 2>/dev/null \
    | /usr/bin/grep 'com.apple.quarantine:' || true)"
  [[ -z "$quarantine_entries" ]] || fail "$label contains com.apple.quarantine: $quarantine_entries"
}

if ! /usr/bin/security cms -D -i "$PROFILE" -o "$PROFILE_PLIST" 2>/dev/null; then
  /usr/bin/openssl smime -inform der -verify -noverify -in "$PROFILE" -out "$PROFILE_PLIST" 2>/dev/null \
    || fail "could not decode provisioning profile"
fi
PROFILE_TEXT="$(plutil -p "$PROFILE_PLIST")"
[[ "$PROFILE_TEXT" == *'"OSX"'* ]] || fail "provisioning profile is not for macOS"
[[ "$PROFILE_TEXT" == *'625CGY297X.com.platon.iagent-panel'* ]] \
  || fail "provisioning profile does not grant com.platon.iagent-panel"
[[ "$PROFILE_TEXT" == *'iCloud.com.platon.iagent'* ]] \
  || fail "provisioning profile does not grant the production CloudKit container"

mkdir -p "$ARCHIVE/Products/Applications"
IAGENT_CODESIGN_IDENTITY="$APP_IDENTITY" \
IAGENT_PROVISIONING_PROFILE="$PROFILE" \
IAGENT_CODESIGN_ENTITLEMENTS="$ENTITLEMENTS" \
IAGENT_BUILD_CONFIGURATION=release \
IAGENT_APP_OUTPUT_PATH="$STAGING_APP" \
IAGENT_SWIFTPM_SCRATCH_PATH="$SWIFTPM_SCRATCH" \
IAGENT_REQUIRE_FRESH_APP=1 \
  "$ROOT/Scripts/build-app.sh"
/usr/bin/ditto --noqtn "$STAGING_APP" "$ARCHIVED_APP"
assert_no_quarantine "$ARCHIVED_APP" "archived app"

ARCHIVED_EXECUTABLE="$ARCHIVED_APP/Contents/MacOS/iAgentPanel"
ARCHIVED_INFO_PLIST="$ARCHIVED_APP/Contents/Info.plist"
/usr/bin/xcrun llvm-objdump \
  --macho \
  --section='__TEXT,__info_plist' \
  --full-contents \
  "$ARCHIVED_EXECUTABLE" \
  | /usr/bin/sed -n '/^<?xml/,$p' > "$EMBEDDED_INFO_PLIST"
[[ -s "$EMBEDDED_INFO_PLIST" ]] || fail "could not extract the executable's embedded Info.plist"
/usr/bin/plutil -lint "$EMBEDDED_INFO_PLIST" >/dev/null \
  || fail "the executable's embedded Info.plist is invalid"
for metadata_key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
  expected_value="$(/usr/libexec/PlistBuddy -c "Print :$metadata_key" "$ROOT/Sources/iAgentPanel/Info.plist")"
  external_value="$(/usr/libexec/PlistBuddy -c "Print :$metadata_key" "$ARCHIVED_INFO_PLIST")"
  embedded_value="$(/usr/libexec/PlistBuddy -c "Print :$metadata_key" "$EMBEDDED_INFO_PLIST")"
  [[ "$external_value" == "$expected_value" ]] \
    || fail "$metadata_key in the archived app does not match the release source"
  [[ "$embedded_value" == "$expected_value" ]] \
    || fail "$metadata_key in the executable does not match the release source"
done
for compiled_marker in HomeMessageMoreIcon NotesListView MessageInboxView PanelPageHeader PanelTooltipPresenter; do
  /usr/bin/strings "$ARCHIVED_EXECUTABLE" | /usr/bin/grep -Fx "$compiled_marker" >/dev/null \
    || fail "compiled desktop marker is missing: $compiled_marker"
done
/usr/bin/strings "$ARCHIVED_EXECUTABLE" \
  | /usr/bin/grep -F 'Expected the collapsed panel to match the menu bar height.' >/dev/null \
  || fail "compiled physical-top compact-panel assertion is missing"

/usr/libexec/PlistBuddy -c 'Clear dict' "$ARCHIVE/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :ArchiveVersion integer 2' "$ARCHIVE/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :Name string iAgentPanel' "$ARCHIVE/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SchemeName string iAgentPanel' "$ARCHIVE/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :ApplicationProperties dict' "$ARCHIVE/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :ApplicationProperties:ApplicationPath string Applications/iAgentPanel.app' "$ARCHIVE/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :ApplicationProperties:CFBundleIdentifier string com.platon.iagent-panel' "$ARCHIVE/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :ApplicationProperties:SigningIdentity string Apple Distribution' "$ARCHIVE/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :ApplicationProperties:Team string 625CGY297X' "$ARCHIVE/Info.plist"

IAGENT_REQUIRE_APP_SANDBOX=1 \
  "$ROOT/Scripts/verify-macos-cloudkit-signing.sh" "$ARCHIVED_APP"
/usr/bin/productbuild \
  --component "$ARCHIVED_APP" /Applications \
  --sign "$INSTALLER_IDENTITY" \
  --timestamp \
  "$PKG"
/usr/sbin/pkgutil --expand-full "$PKG" "$PACKAGE_CHECK_ROOT/expanded"
assert_no_quarantine "$PACKAGE_CHECK_ROOT/expanded" "package payload"
/usr/sbin/pkgutil --check-signature "$PKG"
print -- "$ARCHIVE"
print -- "$PKG"
