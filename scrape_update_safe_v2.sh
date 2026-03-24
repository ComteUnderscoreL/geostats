#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export LANG=C

# Usage:
#   export COOKIE_LINE='COLLE ICI TOUT CE QU IL Y A APRES "Cookie:"'
#   ./scrape_update_safe.sh
#   ./scrape_update_safe.sh "https://www.geoguessr.com/challenge/XXXX"
#   ./scrape_update_safe.sh "XXXX"
#   ./scrape_update_safe.sh "" data
#
# Default behavior:
#   - OUTDIR defaults to "data"
#   - if no challenge is provided, reads challenge_id from data/current.txt
#   - reads saison from data/current.txt
#   - if challenge already exists in totals.tsv, removes old rows and rewrites them
#   - avoids duplicates when re-scraping the same challenge

URL_OR_TOKEN="${1:-}"
OUTDIR="${2:-data}"

command -v jq >/dev/null 2>&1 || { echo "ERR jq"; exit 127; }
command -v curl >/dev/null 2>&1 || { echo "ERR curl"; exit 127; }
command -v awk >/dev/null 2>&1 || { echo "ERR awk"; exit 127; }
command -v mktemp >/dev/null 2>&1 || { echo "ERR mktemp"; exit 127; }

mkdir -p "$OUTDIR"

CURRENT_FILE="${OUTDIR}/current.txt"
TOTALS_TSV="${OUTDIR}/totals.tsv"
ROUNDS_TSV="${OUTDIR}/rounds.tsv"

# Read current season from current.txt
if [[ -f "$CURRENT_FILE" ]]; then
  SAISON="$(grep '^saison=' "$CURRENT_FILE" | cut -d= -f2- || true)"
  CURRENT_CHALLENGE_ID="$(grep '^challenge_id=' "$CURRENT_FILE" | cut -d= -f2- || true)"
else
  SAISON=""
  CURRENT_CHALLENGE_ID=""
fi

SAISON="${SAISON//[^0-9-]/}"
[[ -z "$SAISON" ]] && SAISON=0

# Resolve challenge token:
# priority = explicit arg > current.txt
TOKEN="$URL_OR_TOKEN"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$CURRENT_CHALLENGE_ID"
fi

if [[ -z "$TOKEN" ]]; then
  echo "ERR no challenge provided and no challenge_id found in ${CURRENT_FILE}" >&2
  exit 1
fi

if [[ "$TOKEN" =~ /challenge/ ]]; then
  TOKEN="$(echo "$TOKEN" | sed -E 's|.*/challenge/([^/?#]+).*|\1|')"
fi
CHALLENGE_ID="$TOKEN"

CURL_AUTH=()
if [[ -n "${COOKIE_LINE:-}" ]]; then
  CURL_AUTH=(-H "Cookie: ${COOKIE_LINE}")
fi
UA_HEADER=(-H "User-Agent: curl/8.5.0")

curl_to_file() {
  local url="$1"
  local outfile="$2"
  local http_code
  http_code="$(curl -sS "${UA_HEADER[@]}" "${CURL_AUTH[@]}" -o "$outfile" -w "%{http_code}" "$url")"
  echo "$http_code"
}

if [[ ! -s "$TOTALS_TSV" ]]; then
  echo -e "Numero\tsaison\tmap\tplayer_id\tplayer\ttotal_score\tposition\tchallenge_id" > "$TOTALS_TSV"
fi
if [[ ! -s "$ROUNDS_TSV" ]]; then
  echo -e "numero\tsaison\tplayer_id\tplayer\tround\tlat\tlng\tcountry_code\tguess_lat\tguess_lng\tdistance" > "$ROUNDS_TSV"
fi

OLD_INFO=""
if [[ -s "$TOTALS_TSV" ]]; then
  OLD_INFO="$(
    awk -F'\t' -v cid="$CHALLENGE_ID" '
      NR == 1 { next }
      $8 == cid { print $1 "\t" $2; exit }
    ' "$TOTALS_TSV"
  )"
fi

OLD_NUMERO=""
OLD_SAISON=""
if [[ -n "$OLD_INFO" ]]; then
  OLD_NUMERO="$(printf '%s' "$OLD_INFO" | cut -f1)"
  OLD_SAISON="$(printf '%s' "$OLD_INFO" | cut -f2)"
fi

# Keep same Numero if rescraping same challenge in same season
if [[ -n "$OLD_NUMERO" && -n "$OLD_SAISON" && "$OLD_SAISON" == "$SAISON" ]]; then
  NUMERO="$OLD_NUMERO"
else
  if [[ -s "$TOTALS_TSV" ]]; then
    LAST_NUM_IN_SEASON="$(
      awk -F'\t' -v s="$SAISON" '
        NR == 1 { next }
        $2 == s && ($1 + 0) > max { max = $1 + 0 }
        END { print max + 0 }
      ' "$TOTALS_TSV"
    )"
  else
    LAST_NUM_IN_SEASON=0
  fi
  NUMERO=$((LAST_NUM_IN_SEASON + 1))
fi

# Remove previous rows for this challenge, so re-scraping updates instead of duplicating
if [[ -n "$OLD_NUMERO" && -n "$OLD_SAISON" ]]; then
  tmp_totals="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v cid="$CHALLENGE_ID" '
    NR == 1 || $8 != cid { print }
  ' "$TOTALS_TSV" > "$tmp_totals"
  mv "$tmp_totals" "$TOTALS_TSV"

  tmp_rounds="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v n="$OLD_NUMERO" -v s="$OLD_SAISON" '
    NR == 1 || !($1 == n && $2 == s) { print }
  ' "$ROUNDS_TSV" > "$tmp_rounds"
  mv "$tmp_rounds" "$ROUNDS_TSV"
fi

DETAIL_URL="https://www.geoguessr.com/api/v3/challenges/${TOKEN}"
HC="$(curl_to_file "$DETAIL_URL" "${OUTDIR}/data.json")"
if [[ "$HC" != "200" ]]; then
  echo "ERR data $HC" >&2
  exit 2
fi

MAP_NAME="$(jq -r '.map.name? // .mapName? // .map?.name? // .map?.title? // "UNKNOWN_MAP"' "${OUTDIR}/data.json")"

: > "${OUTDIR}/scores.json"
PAGINATION_TOKEN=""
RANK_BASE=0

while :; do
  if [[ -n "$PAGINATION_TOKEN" ]]; then
    HS_URL="https://www.geoguessr.com/api/v3/results/highscores/${TOKEN}?friends=false&paginationToken=${PAGINATION_TOKEN}"
  else
    HS_URL="https://www.geoguessr.com/api/v3/results/highscores/${TOKEN}?friends=false"
  fi

  HC="$(curl_to_file "$HS_URL" "${OUTDIR}/scores.json")"
  if [[ "$HC" != "200" ]]; then
    echo "ERR scores $HC" >&2
    exit 3
  fi

  COUNT="$(jq -r '.items | length' "${OUTDIR}/scores.json" 2>/dev/null || echo 0)"
  [[ "$COUNT" -eq 0 ]] && break

  jq -r \
    --arg map "$MAP_NAME" \
    --arg numero "$NUMERO" \
    --arg saison "$SAISON" \
    --argjson base "$RANK_BASE" \
    --arg cid "$CHALLENGE_ID" '
    .items
    | to_entries[]
    | .key as $i
    | .value.game.player as $p
    | [
        $numero,
        $saison,
        $map,
        ($p.id // ""),
        ($p.nick // "UNKNOWN_PLAYER"),
        ($p.totalScore.amount // 0),
        ($base + $i + 1),
        $cid
      ]
    | @tsv
  ' "${OUTDIR}/scores.json" >> "$TOTALS_TSV"

  jq -r \
    --arg numero "$NUMERO" \
    --arg saison "$SAISON" '
    .items[]
    | .game as $g
    | .game.player as $p
    | ($g.rounds // []) as $rounds
    | ($p.guesses // []) as $guesses
    | [range(0; ([($rounds|length), ($guesses|length)] | min))] as $idxs
    | $idxs[]
    | . as $i
    | ($rounds[$i]) as $r
    | ($guesses[$i]) as $q
    | ($r.lat // empty) as $lat
    | ($r.lng // empty) as $lng
    | ($r.streakLocationCode // "") as $cc
    | ($q.lat // empty) as $glat
    | ($q.lng // empty) as $glng
    | [
        $numero,
        $saison,
        ($p.id // ""),
        ($p.nick // "UNKNOWN_PLAYER"),
        ($i + 1),
        $lat,
        $lng,
        $cc,
        $glat,
        $glng
      ]
    | @tsv
  ' "${OUTDIR}/scores.json" |
  awk -F'\t' -v OFS='\t' '
    function rad(x) { return x * 3.141592653589793 / 180 }
    function haversine(lat1, lon1, lat2, lon2,   dlat, dlon, a, c) {
      dlat = rad(lat2 - lat1)
      dlon = rad(lon2 - lon1)
      a = sin(dlat/2)^2 + cos(rad(lat1)) * cos(rad(lat2)) * sin(dlon/2)^2
      c = 2 * atan2(sqrt(a), sqrt(1-a))
      return 6371 * c
    }
    {
      if ($6=="" || $7=="" || $9=="" || $10=="") {
        print $0, ""
      } else {
        d = haversine($6+0, $7+0, $9+0, $10+0)
        printf "%s\t%.6f\n", $0, d
      }
    }
  ' >> "$ROUNDS_TSV"

  PAGINATION_TOKEN="$(jq -r '.paginationToken // empty' "${OUTDIR}/scores.json")"
  RANK_BASE=$((RANK_BASE + COUNT))
  [[ -z "$PAGINATION_TOKEN" ]] && break

  sleep 1
done

echo "OK season=${SAISON} numero=${NUMERO} challenge_id=${CHALLENGE_ID} outdir=${OUTDIR}"
