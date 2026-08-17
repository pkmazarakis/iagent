#!/bin/zsh
set -euo pipefail

APP="${1:?usage: verify-macos-cloudkit-signing.sh /path/to/iAgentPanel.app}"
EXPECTED_BUNDLE_ID="com.platon.iagent-panel"
EXPECTED_CONTAINER="iCloud.com.platon.iagent"
EXPECTED_ENVIRONMENT="Production"
EXPECTED_TEAM_ID="625CGY297X"
PROFILE="$APP/Contents/embedded.provisionprofile"
ENTITLEMENTS_PLIST="$(mktemp /private/tmp/iagent-entitlements.XXXXXX)"
PROFILE_PLIST="$(mktemp /private/tmp/iagent-profile.XXXXXX)"

cleanup() {
  rm -f "$ENTITLEMENTS_PLIST" "$PROFILE_PLIST"
}
trap cleanup EXIT

fail() {
  print -u2 -- "CloudKit signing verification failed: $1"
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

plist_contains() {
  local values
  values="$(plist_value "$1" "$2" || true)"
  [[ "$values" == *"$3"* ]]
}

[[ -d "$APP" ]] || fail "app bundle does not exist at $APP"
[[ -f "$PROFILE" ]] || fail "Contents/embedded.provisionprofile is missing"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign -d --xml --entitlements "$ENTITLEMENTS_PLIST" "$APP" 2>/dev/null
if ! /usr/bin/security cms -D -i "$PROFILE" -o "$PROFILE_PLIST" 2>/dev/null; then
  /usr/bin/openssl smime -inform der -verify -noverify -in "$PROFILE" \
    -out "$PROFILE_PLIST" 2>/dev/null
fi

BUNDLE_ID="$(plist_value "$APP/Contents/Info.plist" CFBundleIdentifier || true)"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "bundle identifier is $BUNDLE_ID"

SIGNATURE_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1)"
SIGNATURE_TEAM_ID="$(print -r -- "$SIGNATURE_DETAILS" | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
[[ "$SIGNATURE_TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || fail "signature TeamIdentifier is ${SIGNATURE_TEAM_ID:-missing}"

APP_TEAM_ID="$(plist_value "$ENTITLEMENTS_PLIST" com.apple.developer.team-identifier || true)"
APP_ENVIRONMENT="$(plist_value "$ENTITLEMENTS_PLIST" com.apple.developer.icloud-container-environment || true)"
APP_PUSH_ENVIRONMENT="$(plist_value "$ENTITLEMENTS_PLIST" com.apple.developer.aps-environment || true)"
[[ "$APP_TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || fail "app entitlement team is ${APP_TEAM_ID:-missing}"
[[ "$APP_ENVIRONMENT" == "$EXPECTED_ENVIRONMENT" ]] || fail "app CloudKit environment is ${APP_ENVIRONMENT:-missing}"
[[ "$APP_PUSH_ENVIRONMENT" == "production" ]] || fail "app push environment is ${APP_PUSH_ENVIRONMENT:-missing}"
plist_contains "$ENTITLEMENTS_PLIST" com.apple.developer.icloud-services CloudKit \
  || fail "app CloudKit service entitlement is missing"
plist_contains "$ENTITLEMENTS_PLIST" com.apple.developer.icloud-container-identifiers "$EXPECTED_CONTAINER" \
  || fail "app is not entitled for $EXPECTED_CONTAINER"
APP_ADDRESSBOOK="$(plist_value "$ENTITLEMENTS_PLIST" com.apple.security.personal-information.addressbook || true)"
[[ "$APP_ADDRESSBOOK" == "true" ]] || fail "Contacts entitlement is missing"
if [[ "${IAGENT_REQUIRE_APP_SANDBOX:-0}" == "1" ]]; then
  APP_SANDBOX="$(plist_value "$ENTITLEMENTS_PLIST" com.apple.security.app-sandbox || true)"
  APP_AUDIO_INPUT="$(plist_value "$ENTITLEMENTS_PLIST" com.apple.security.device.audio-input || true)"
  APP_USER_SELECTED_RW="$(plist_value "$ENTITLEMENTS_PLIST" com.apple.security.files.user-selected.read-write || true)"
  APP_BOOKMARKS="$(plist_value "$ENTITLEMENTS_PLIST" com.apple.security.files.bookmarks.app-scope || true)"
  [[ "$APP_SANDBOX" == "true" ]] || fail "App Sandbox entitlement is missing"
  [[ "$APP_AUDIO_INPUT" == "true" ]] || fail "Audio Input entitlement is missing"
  [[ "$APP_USER_SELECTED_RW" == "true" ]] || fail "user-selected read/write entitlement is missing"
  [[ "$APP_BOOKMARKS" == "true" ]] || fail "app-scoped bookmark entitlement is missing"
fi

for usage_key in NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription \
  NSScreenCaptureUsageDescription NSAudioCaptureUsageDescription NSContactsUsageDescription; do
  usage_value="$(plist_value "$APP/Contents/Info.plist" "$usage_key" || true)"
  [[ -n "$usage_value" ]] || fail "$usage_key is missing from the signed app"
done

PROFILE_TEAM_ID="$(plist_value "$PROFILE_PLIST" TeamIdentifier:0 || true)"
PROFILE_ENVIRONMENT="$(plist_value "$PROFILE_PLIST" Entitlements:com.apple.developer.icloud-container-environment || true)"
PROFILE_PUSH_ENVIRONMENT="$(plist_value "$PROFILE_PLIST" Entitlements:com.apple.developer.aps-environment || true)"
[[ "$PROFILE_TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || fail "profile team is ${PROFILE_TEAM_ID:-missing}"
[[ "$PROFILE_ENVIRONMENT" == *"$EXPECTED_ENVIRONMENT"* ]] \
  || fail "profile CloudKit environment is ${PROFILE_ENVIRONMENT:-missing}"
[[ "$PROFILE_PUSH_ENVIRONMENT" == "production" ]] || fail "profile push environment is ${PROFILE_PUSH_ENVIRONMENT:-missing}"
PROFILE_ICLOUD_SERVICES="$(plist_value "$PROFILE_PLIST" Entitlements:com.apple.developer.icloud-services || true)"
[[ "$PROFILE_ICLOUD_SERVICES" == *"CloudKit"* || "$PROFILE_ICLOUD_SERVICES" == "*" ]] \
  || fail "profile does not grant CloudKit"
plist_contains "$PROFILE_PLIST" Entitlements:com.apple.developer.icloud-container-identifiers "$EXPECTED_CONTAINER" \
  || fail "profile does not grant $EXPECTED_CONTAINER"

print -- "Verified Production CloudKit signing for $EXPECTED_BUNDLE_ID ($EXPECTED_TEAM_ID)."
