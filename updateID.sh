#!/usr/bin/env bash

# === CONFIG (à adapter) ===
CURRENT_FILE="data/current.txt"
LIST_FILE="liste.txt"

while true; do
  TODAY=$(date +%F)

  CURRENT_DATE=$(grep '^date=' "$CURRENT_FILE" | cut -d'=' -f2)
  CURRENT_ID=$(grep '^challenge_id=' "$CURRENT_FILE" | cut -d'=' -f2)

  if [[ "$CURRENT_DATE" != "$TODAY" ]]; then
    echo "[INFO] Nouvelle journée → update"

    NEXT_ID=$(awk -v id="$CURRENT_ID" '
      BEGIN { first="" }
      {
        if (NR==1) first=$0
        if (found) { print; exit }
        if ($0 == id) found=1
      }
      END {
        if (found && !printed) print first
      }
    ' "$LIST_FILE")

    if [[ -z "$NEXT_ID" ]]; then
      echo "[ERROR] Next ID introuvable"
    else
      sed -i "s/^date=.*/date=$TODAY/" "$CURRENT_FILE"
      sed -i "s/^challenge_id=.*/challenge_id=$NEXT_ID/" "$CURRENT_FILE"
      echo "[INFO] Update OK → $NEXT_ID"
    fi
  fi

  sleep 60
done
