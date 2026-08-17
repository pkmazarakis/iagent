#!/bin/zsh
set -euo pipefail

TARGET="${1:?usage: verify-ios-cloudkit-signing.sh /path/to/iAgent.app-or-ipa}"
EXPECTED_BUNDLE_ID="com.platon.iagent.mobile"
EXPECTED_CONTAINER="iCloud.com.platon.iagent"
EXPECTED_ENVIRONMENT="Production"
EXPECTED_TEAM_ID="625CGY297X"

TEMP_DIRECTORY="$(mktemp -d /private/tmp/iagent-ios-signing.XXXXXX)"
ENTITLEMENTS_PLIST="$TEMP_DIRECTORY/entitlements.plist"
PROFILE_PLIST="$TEMP_DIRECTORY/profile.plist"

cleanup() {
  rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT

fail() {
  print -u2 -- "iOS CloudKit signing verification failed: $1"
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

if [[ -d "$TARGET" && "$TARGET" == *.app ]]; then
  APP="$TARGET"
elif [[ -f "$TARGET" && "$TARGET" == *.ipa ]]; then
  /usr/bin/ditto -x -k "$TARGET" "$TEMP_DIRECTORY/unpacked"
  APP="$(find "$TEMP_DIRECTORY/unpacked/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
  [[ -n "$APP" ]] || fail "the IPA contains no application bundle"
else
  fail "expected an .app directory or .ipa file at $TARGET"
fi

PROFILE="$APP/embedded.mobileprovision"
[[ -f "$PROFILE" ]] || fail "embedded.mobileprovision is missing"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign -d --xml --entitlements "$ENTITLEMENTS_PLIST" "$APP" 2>/dev/null
if ! /usr/bin/security cms -D -i "$PROFILE" -o "$PROFILE_PLIST" 2>/dev/null; then
  /usr/bin/openssl smime -inform der -verify -noverify -in "$PROFILE" \
    -out "$PROFILE_PLIST" 2>/dev/null
fi

BUNDLE_ID="$(plist_value "$APP/Info.plist" CFBundleIdentifier || true)"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "bundle identifier is ${BUNDLE_ID:-missing}"

TEAM_ID="$(plist_value "$ENTITLEMENTS_PLIST" com.apple.developer.team-identifier || true)"
APPLICATION_ID="$(plist_value "$ENTITLEMENTS_PLIST" application-identifier || true)"
ENVIRONMENT="$(plist_value "$ENTITLEMENTS_PLIST" com.apple.developer.icloud-container-environment || true)"
PUSH_ENVIRONMENT="$(plist_value "$ENTITLEMENTS_PLIST" aps-environment || true)"
GET_TASK_ALLOW="$(plist_value "$ENTITLEMENTS_PLIST" get-task-allow || true)"

[[ "$TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || fail "team identifier is ${TEAM_ID:-missing}"
[[ "$APPLICATION_ID" == "$EXPECTED_TEAM_ID.$EXPECTED_BUNDLE_ID" ]] \
  || fail "application identifier is ${APPLICATION_ID:-missing}"
[[ "$ENVIRONMENT" == "$EXPECTED_ENVIRONMENT" ]] \
  || fail "CloudKit environment is ${ENVIRONMENT:-missing}"
[[ "$PUSH_ENVIRONMENT" == "production" ]] \
  || fail "push environment is ${PUSH_ENVIRONMENT:-missing}"
[[ "$GET_TASK_ALLOW" == "false" || "$GET_TASK_ALLOW" == "NO" || "$GET_TASK_ALLOW" == "0" ]] \
  || fail "get-task-allow must be disabled for TestFlight"
plist_contains "$ENTITLEMENTS_PLIST" com.apple.developer.icloud-services CloudKit \
  || fail "CloudKit service entitlement is missing"
plist_contains "$ENTITLEMENTS_PLIST" com.apple.developer.icloud-container-identifiers "$EXPECTED_CONTAINER" \
  || fail "app is not entitled for $EXPECTED_CONTAINER"

PROFILE_APP_ID="$(plist_value "$PROFILE_PLIST" Entitlements:application-identifier || true)"
PROFILE_PUSH_ENVIRONMENT="$(plist_value "$PROFILE_PLIST" Entitlements:aps-environment || true)"
[[ "$PROFILE_APP_ID" == "$EXPECTED_TEAM_ID.$EXPECTED_BUNDLE_ID" ]] \
  || fail "profile application identifier is ${PROFILE_APP_ID:-missing}"
[[ "$PROFILE_PUSH_ENVIRONMENT" == "production" ]] \
  || fail "profile push environment is ${PROFILE_PUSH_ENVIRONMENT:-missing}"
plist_contains "$PROFILE_PLIST" Entitlements:com.apple.developer.icloud-container-environment "$EXPECTED_ENVIRONMENT" \
  || fail "profile does not allow CloudKit Production"
plist_contains "$PROFILE_PLIST" Entitlements:com.apple.developer.icloud-container-identifiers "$EXPECTED_CONTAINER" \
  || fail "profile does not grant $EXPECTED_CONTAINER"

print -- "Verified TestFlight CloudKit and push signing for $EXPECTED_BUNDLE_ID ($EXPECTED_TEAM_ID)."
