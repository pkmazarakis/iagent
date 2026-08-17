#!/bin/zsh
set -euo pipefail

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  print -u2 "OPENAI_API_KEY is not set in this terminal."
  print -u2 "Export it here, then run this command again. Do not put the key in Xcode or the app."
  exit 1
fi

script_directory="${0:A:h}"
exec /usr/bin/env node "$script_directory/ask-iagent-openai-relay.mjs"
