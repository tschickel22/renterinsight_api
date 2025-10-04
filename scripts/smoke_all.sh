#!/usr/bin/env bash
# usage: BASE=http://127.0.0.1:3001 LEAD_ID=18 bash scripts/smoke_all.sh
set -o pipefail

BASE="${BASE:-http://127.0.0.1:3001}"
LEAD_ID="${LEAD_ID:-18}"

PASS=0; FAIL=0
ok(){ echo "✅ PASS - $*"; PASS=$((PASS+1)); }
no(){ echo "❌ FAIL - $*"; FAIL=$((FAIL+1)); }

have_jq(){ command -v jq >/dev/null 2>&1; }

curl_cap () {
  local TMP_H TMP_B
  TMP_H=$(mktemp); TMP_B=$(mktemp)
  curl -sS -D "$TMP_H" -o "$TMP_B" "$@" -w "\nHTTP=%{http_code}\n"
  local CODE REQ_ID
  CODE=$(tail -n1 "$TMP_B" | sed -n 's/^HTTP=\([0-9]*\)$/\1/p')
  REQ_ID=$(awk -F': ' '/x-request-id/ {print $2}' "$TMP_H" | tr -d '\r')
  echo "X-Request-Id: ${REQ_ID:-<none>}" 1>&2
  sed -n '$!p' "$TMP_B"   # body to stdout
  echo "$CODE"           # status as final line
}

expect_status () {
  local WANT="$1"; shift
  local OUT; OUT="$("$@")" || true
  local CODE BODY
  CODE="$(echo "$OUT" | tail -n1)"
  BODY="$(echo "$OUT" | sed '$d')"
  if [[ "$CODE" == "$WANT" ]]; then
    ok "$* -> $CODE"
    echo "$BODY"
    return 0
  else
    no "$* -> got $CODE (want $WANT)"
    echo "$BODY" 1>&2
    return 1
  fi
}

accept_status () {
  local WANTS="$1"; shift
  local OUT; OUT="$("$@")" || true
  local CODE BODY
  CODE="$(echo "$OUT" | tail -n1)"
  BODY="$(echo "$OUT" | sed '$d')"
  if echo " $WANTS " | grep -q " $CODE "; then
    ok "$* -> $CODE"
    echo "$BODY"
    return 0
  else
    no "$* -> got $CODE (want one of: $WANTS)"
    echo "$BODY" 1>&2
    return 1
  fi
}

json_get () { have_jq && echo "$1" | jq -r "$2" 2>/dev/null || echo ""; }

echo "=== Smoke test against BASE=$BASE (LEAD_ID=$LEAD_ID) ==="

# 1) Activities
accept_status "200" curl_cap -H "Accept: application/json" \
  "$BASE/api/crm/leads/$LEAD_ID/activities" > /dev/null

accept_status "201 200" curl_cap -H "Content-Type: application/json" -X POST \
  "$BASE/api/crm/leads/$LEAD_ID/activities" \
  -d '{"activity":{"activity_type":"note","description":"smoke note"}}' > /dev/null

# 2) AI Insights
accept_status "200" curl_cap -H "Accept: application/json" \
  "$BASE/api/crm/leads/$LEAD_ID/ai_insights" > /dev/null

accept_status "200" curl_cap -H "Content-Type: application/json" -X POST \
  "$BASE/api/crm/leads/$LEAD_ID/ai_insights/generate" \
  -d '{"force":true}' > /dev/null

# 3) Reminders (create)
REM_BODY=$(expect_status "201" curl_cap -H "Content-Type: application/json" -X POST \
  "$BASE/api/crm/leads/$LEAD_ID/reminders" \
  -d '{"reminder":{"title":"Follow up","description":"call Monday","due_date":"2025-10-05T17:00:00Z","type":"follow_up"}}') || true
REM_ID=$(json_get "$REM_BODY" '.id')

# Optional: mark complete / delete if routes exist
if [[ -n "${REM_ID:-}" ]]; then
  accept_status "200 204" curl_cap -H "Accept: application/json" \
    "$BASE/api/crm/reminders/$REM_ID/complete" >/dev/null || true
  accept_status "200 204" curl_cap -X DELETE \
    "$BASE/api/crm/reminders/$REM_ID" >/dev/null || true
fi

# 4) Convert Lead (idempotent)
accept_status "201 200" curl_cap -H "Content-Type: application/json" -X POST \
  "$BASE/api/crm/leads/$LEAD_ID/convert" > /dev/null

# 5) Tags (create/find, assign, verify)
accept_status "200" curl_cap -H "Accept: application/json" \
  "$BASE/api/crm/tags" > /dev/null

TAG_NAME="smoke-tag-ui"
T_CREATE=$(accept_status "201 422" curl_cap -H "Content-Type: application/json" -X POST \
  "$BASE/api/crm/tags" -d "{\"tag\":{\"name\":\"$TAG_NAME\",\"is_active\":true}}") || true
TAG_ID=$(json_get "$T_CREATE" '.id')
if [[ -z "${TAG_ID:-}" ]]; then
  T_IDX=$(curl -sS "$BASE/api/crm/tags")
  TAG_ID=$(json_get "$T_IDX" ".[] | select(.name==\"$TAG_NAME\") | .id" | head -1)
fi

if [[ -n "${TAG_ID:-}" ]]; then
  accept_status "201 200" curl_cap -H "Content-Type: application/json" -X POST \
    "$BASE/api/crm/tags/assign" \
    -d "{\"tag_id\":$TAG_ID,\"entity_type\":\"Lead\",\"entity_id\":$LEAD_ID}" > /dev/null

  LT=$(accept_status "200" curl_cap "$BASE/api/crm/leads/$LEAD_ID/tags") || true
  if echo "$LT" | grep -q "\"id\": $TAG_ID"; then
    ok "Lead $LEAD_ID tagged with $TAG_NAME (#$TAG_ID)"
  else
    no "Lead $LEAD_ID tags missing $TAG_NAME (#$TAG_ID)"
  fi
else
  no "Could not resolve TAG_ID for $TAG_NAME"
fi

# 6) Lead Scoring
accept_status "200" curl_cap "$BASE/api/crm/leads/$LEAD_ID/score" > /dev/null
accept_status "200" curl_cap -H "Content-Type: application/json" -X POST \
  "$BASE/api/crm/leads/$LEAD_ID/score/calculate" -d '{}' > /dev/null

# 7) Communications
accept_status "200" curl_cap "$BASE/api/crm/leads/$LEAD_ID/communications" > /dev/null
accept_status "200" curl_cap "$BASE/api/crm/leads/$LEAD_ID/communications/history" > /dev/null
accept_status "200" curl_cap "$BASE/api/crm/leads/$LEAD_ID/communications/settings" > /dev/null

accept_status "201 200" curl_cap -H "Content-Type: application/json" -X POST \
  "$BASE/api/crm/leads/$LEAD_ID/communications/send_email" \
  -d '{"to":"testlead@example.com","subject":"Hello","body":"Smoke email"}' > /dev/null

accept_status "201 200" curl_cap -H "Content-Type: application/json" -X POST \
  "$BASE/api/crm/leads/$LEAD_ID/communications/send_sms" \
  -d '{"to":"+15550000","body":"Smoke sms"}' > /dev/null

accept_status "201 200" curl_cap -H "Content-Type: application/json" -X POST \
  "$BASE/api/crm/leads/$LEAD_ID/communications/log" \
  -d '{"communication":{"channel":"email","direction":"outbound","subject":"Logged","body":"Logged by smoke"}}' > /dev/null

echo
echo "============= Summary ============="
echo "PASS: $PASS    FAIL: $FAIL"
echo "==================================="
if [[ "$FAIL" -eq 0 ]]; then exit 0; else exit 1; fi
