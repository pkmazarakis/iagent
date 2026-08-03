#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$($ROOT/Scripts/build-app.sh)"

open "$APP"
