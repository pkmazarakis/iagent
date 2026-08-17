#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DEVELOPMENT_APP="$ROOT/.build/iAgentPanel.app"
PRODUCTION_APP="$ROOT/.build/iAgentPanel-Production.app"

if [[ "${1:-}" == "--development" ]]; then
  "$ROOT/Scripts/build-app.sh"
  open "$DEVELOPMENT_APP"
elif [[ -d "$PRODUCTION_APP" ]]; then
  "$ROOT/Scripts/verify-macos-cloudkit-signing.sh" "$PRODUCTION_APP"
  open "$PRODUCTION_APP"
else
  "$ROOT/Scripts/build-app.sh"
  print -u2 -- "No Production-signed companion is installed yet; opening the offline development build."
  open "$DEVELOPMENT_APP"
fi
