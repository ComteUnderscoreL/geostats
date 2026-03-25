#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

while true; do
  echo "[INFO] $(date) - start update"

  cd "$REPO_DIR"

  ./scrape.sh

  git add data/current.txt data/rounds.tsv data/totals.tsv

  # commit only if changes
  if git diff --cached --quiet; then
    echo "[INFO] No changes"
  else
    git commit -m "auto update $(date '+%Y-%m-%d %H:%M')"
    git pull --rebase --autostash origin main
    git push origin main
    echo "[INFO] pushed"
  fi

  sleep 59
done
