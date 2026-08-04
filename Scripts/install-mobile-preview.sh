#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/Mobile/iAgentMobile.xcodeproj"
DERIVED_DATA="${IAGENT_MOBILE_DERIVED_DATA:-/tmp/iagent-mobile-device-derived}"
DEVICE_ID="${1:-${IAGENT_DEVICE_ID:-}}"
TEAM_ID="${IAGENT_TEAM_ID:-}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/iAgent.app"
BUNDLE_ID="com.platon.iagent.mobile"

if [[ -z "$DEVICE_ID" ]]; then
  echo "Pass an iPhone device identifier or set IAGENT_DEVICE_ID."
  echo "Connected devices:"
  xcrun devicectl list devices
  exit 2
fi

if [[ -z "$TEAM_ID" ]]; then
  echo "Set IAGENT_TEAM_ID to the Apple Developer Team selected in Xcode."
  exit 2
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme iAgentMobile \
  -configuration Debug \
  -sdk iphoneos \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  build

xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

launch_arguments=()
if [[ "${IAGENT_LIVE_SYNC:-0}" == "1" ]]; then
  launch_arguments+=("--live-sync")
fi

xcrun devicectl device process launch \
  --terminate-existing \
  --device "$DEVICE_ID" \
  "$BUNDLE_ID" \
  "${launch_arguments[@]}"

