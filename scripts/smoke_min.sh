#!/usr/bin/env bash
# usage: BASE=http://127.0.0.1:3001 LEAD_ID=18 bash scripts/smoke_min.sh
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:3001}"
LEAD_ID="${LEAD_ID:-18}"

PASS=0; FAIL=0
ok(){ echo "✅ PASS - $*"; PASS=$((PASS+1)); }
no(){ echo "❌ FAIL - $*"; FAIL=$((FAIL+1)); }

have_jq(){ command -v jq >/dev/null 2>&1; }

# Globals set by req: CODE, REQID, BODY
req(){
  local method="$1" url="$2" data="${3:-}"
  local TMP_H; TMP_H=$(mktemp)
  if [[ -n "$data" ]]; then
    BODY=$(curl -sS -D "$TMP_H" -H "Content-Type: application/json" -X "$method" "$url" -d "$data")
  else
    BODY=$(curl -sS -D "$TMP_H" -X "$method" "$url")
  fi
  CODE=$(head -1 "$TMP_H" | awk '{print $2}')
  REQID=$(awk -F': ' 'tolower($1)=="x-request-id"{print $2}' "$TMP_H" | tr -d '\r' | tail -1)
  rm -f "$TMP_H"
}

is_json(){
  [[ -n "${1:-}" ]] || return 1
  echo "$1" | jq -e . >/dev/null 2>&1
}

# Robust: works if response is an array OR wrapped under data/tags/results.
find_tag_id_by_name(){
  local name="$1" json="$2"
  jq -r --arg NAME "$name" '
    def arr:
      if type=="array" then .
      elif type=="object" then
        if (.data    | type)=="array" then .data
        elif (.tags   | type)=="array" then .tags
        elif (.results| type)=="array" then .results
        else [] end
      else [] end;
    arr
    | map(select((.name // .label // .title) == $NAME) | (.id // .uuid // .tag_id))
    | first // empty
  ' <<<"$json"
}

echo "=== Smoke (min) BASE=$BASE LEAD_ID=$LEAD_ID ==="

if ! have_jq; then
  no "jq not installed; please install jq"
  echo "======= Summary ======="; echo "PASS: $PASS   FAIL: $FAIL"; exit 1
fi

# 1) GET /tags
req GET "$BASE/api/crm/tags"
if ! is_json "$BODY"; then
  no "GET /tags returned non-JSON ($CODE $REQID)"
else
  ok "GET /tags ($CODE $REQID)"
fi

# Resolve or create the 'smoke-tag-ui' tag
TAG_ID="$(find_tag_id_by_name "smoke-tag-ui" "$BODY" || true)"

if [[ -z "${TAG_ID:-}" ]]; then
  echo "Tag not found; attempting to create…"

  # Try payload shape A: nested { tag: { name: ... } }
  req POST "$BASE/api/crm/tags" '{"tag":{"name":"smoke-tag-ui"}}'
  if is_json "$BODY"; then
    TAG_ID="$(echo "$BODY" | jq -r '(.id // .data.id // .tag.id // .uuid // .tag_id // empty)')"
  fi

  # Try payload shape B: flat { name: ... }
  if [[ -z "${TAG_ID:-}" ]]; then
    req POST "$BASE/api/crm/tags" '{"name":"smoke-tag-ui"}'
    if is_json "$BODY"; then
      TAG_ID="$(echo "$BODY" | jq -r '(.id // .data.id // .tag.id // .uuid // .tag_id // empty)')"
    fi
  fi

  # As a last resort, refetch list and search
  if [[ -z "${TAG_ID:-}" ]]; then
    req GET "$BASE/api/crm/tags"
    if is_json "$BODY"; then
      TAG_ID="$(find_tag_id_by_name "smoke-tag-ui" "$BODY" || true)"
    fi
  fi
fi

if [[ -n "${TAG_ID:-}" && "$TAG_ID" != "null" ]]; then
  ok "Resolved TAG_ID=$TAG_ID"
else
  no "Could not resolve TAG_ID for smoke-tag-ui"
fi

echo
echo "======= Summary ======="
echo "PASS: $PASS   FAIL: $FAIL"
echo "======================="
