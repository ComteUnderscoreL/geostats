#!/usr/bin/env bash

CURRENT_FILE="data/current.txt"
LIST_FILE="liste.txt"

while true; do
  TODAY=$(date +%F)

  CURRENT_DATE=$(grep '^date=' "$CURRENT_FILE" | cut -d'=' -f2)
  CURRENT_ID=$(grep '^challenge_id=' "$CURRENT_FILE" | cut -d'=' -f2)

  if [[ "$CURRENT_DATE" != "$TODAY" ]]; then
    echo "[INFO] Nouvelle journée → update"

    NEXT_ID=$(awk -v id="$CURRENT_ID" '
      NR==1 { first=$0 }
      found { print; done=1; exit }
      $0 == id { found=1 }
      END {
        if (!done && found) print first
      }
    ' "$LIST_FILE")

    if [[ -z "$NEXT_ID" ]]; then
      echo "[ERROR] Next ID introuvable"
    else
      if [[ "$OSTYPE" == darwin* ]]; then
        sed -i '' "s/^date=.*/date=$TODAY/" "$CURRENT_FILE"
        sed -i '' "s/^challenge_id=.*/challenge_id=$NEXT_ID/" "$CURRENT_FILE"
      else
        sed -i "s/^date=.*/date=$TODAY/" "$CURRENT_FILE"
        sed -i "s/^challenge_id=.*/challenge_id=$NEXT_ID/" "$CURRENT_FILE"
      fi

      echo "[INFO] Update OK → $NEXT_ID"
    fi
  fi

  sleep 60
done
