#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "$APP_DIR/.." && pwd)"
PAGES_DIR="$WORKSPACE_DIR/.github-pages/spatial-canvas-mobile"
REPOSITORY="https://github.com/platon-oai/spatial-canvas-mobile.git"
DEPLOY_BRANCH="gh-pages"
if [[ "${1:-}" == "--" ]]; then
  shift
fi
COMMIT_MESSAGE="${1:-Update Spatial preview}"

pnpm --dir "$APP_DIR" build

if [[ ! -d "$PAGES_DIR/.git" ]]; then
  mkdir -p "$(dirname "$PAGES_DIR")"
  git clone "$REPOSITORY" "$PAGES_DIR"
fi

git -C "$PAGES_DIR" fetch origin "$DEPLOY_BRANCH"
if git -C "$PAGES_DIR" show-ref --verify --quiet "refs/heads/$DEPLOY_BRANCH"; then
  git -C "$PAGES_DIR" checkout "$DEPLOY_BRANCH"
else
  git -C "$PAGES_DIR" checkout -b "$DEPLOY_BRANCH" "origin/$DEPLOY_BRANCH"
fi

rsync -a --delete \
  --exclude .git \
  --exclude .nojekyll \
  "$APP_DIR/dist/" "$PAGES_DIR/"

touch "$PAGES_DIR/.nojekyll"
git -C "$PAGES_DIR" add --all

if git -C "$PAGES_DIR" diff --cached --quiet; then
  echo "Spatial Pages is already up to date."
  exit 0
fi

git -C "$PAGES_DIR" commit -m "$COMMIT_MESSAGE"
git -C "$PAGES_DIR" push origin "$DEPLOY_BRANCH"

echo "Published: https://platon-oai.github.io/spatial-canvas-mobile/"
