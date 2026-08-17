#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TEAM_ID="625CGY297X"
CONTAINER_ID="iCloud.com.platon.iagent"
SCHEMA="$ROOT/CloudKit/iAgentSchema.ckdb"
CKTOOL="$(xcrun --find cktool)"

usage() {
  print -u2 "Usage: $0 {authenticate|validate-development|import-development|export-development|export-production}"
  exit 64
}

command="${1:-}"
case "$command" in
  authenticate)
    exec "$CKTOOL" save-token --type management
    ;;
  validate-development)
    exec "$CKTOOL" validate-schema \
      --team-id "$TEAM_ID" \
      --container-id "$CONTAINER_ID" \
      --environment development \
      --file "$SCHEMA"
    ;;
  import-development)
    if [[ "${IAGENT_CONFIRM_SCHEMA_IMPORT:-}" != "YES" ]]; then
      print -u2 "Set IAGENT_CONFIRM_SCHEMA_IMPORT=YES after reviewing the exported Development schema."
      exit 65
    fi
    exec "$CKTOOL" import-schema \
      --team-id "$TEAM_ID" \
      --container-id "$CONTAINER_ID" \
      --environment development \
      --validate \
      --file "$SCHEMA"
    ;;
  export-development|export-production)
    environment="${command#export-}"
    destination="${2:-$ROOT/CloudKit/iAgentSchema-$environment.ckdb}"
    exec "$CKTOOL" export-schema \
      --team-id "$TEAM_ID" \
      --container-id "$CONTAINER_ID" \
      --environment "$environment" \
      --output-file "$destination"
    ;;
  *)
    usage
    ;;
esac
