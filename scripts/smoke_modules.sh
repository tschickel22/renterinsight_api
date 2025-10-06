#!/usr/bin/env bash
# Usage:
#   LEAD_ID=18 BASE=http://127.0.0.1:3001 READ_ONLY=1 bash scripts/smoke_modules.sh
set -euo pipefail

BASE=${BASE:-http://127.0.0.1:3001}
LEAD_ID=${LEAD_ID:-1}
READ_ONLY=${READ_ONLY:-0}

# ---------- helpers ----------
color() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
green(){ color 32 "$1"; }
red()  { color 31 "$1"; }
yellow(){ color 33 "$1"; }
blue(){ color 36 "$1"; }

pass=0; fail=0
ok()   { echo "$(green "PASS ($1)")"; pass=$((pass+1)); }
bad()  { echo "$(red   "FAIL ($1)")"; fail=$((fail+1)); }

strip_format() { sed -E 's/\(.\:format\)//g'; }
sub_ids()      { sed -E "s/:lead_id/${LEAD_ID}/g; s/:id/${1:-1}/g"; }

url()   { echo -n "$BASE$(echo "$1" | strip_format | sub_ids "${2:-1}")"; }
get()   { curl -sS -o /tmp/_out.json -w "%{http_code}" "$(url "$1" "${2:-1}")"; }
post()  { curl -sS -H "Content-Type: application/json" -o /tmp/_out.json -w "%{http_code}" -X POST "$(url "$1" "${3:-1}")" -d "$2"; }
patch() { curl -sS -H "Content-Type: application/json" -o /tmp/_out.json -w "%{http_code}" -X PATCH "$(url "$1" "${3:-1}")" -d "$2"; }
delete(){ curl -sS -o /tmp/_out.json -w "%{http_code}" -X DELETE "$(url "$1" "${2:-1}")"; }

show_fail() { echo "---- Response ----"; sed -n '1,200p' /tmp/_out.json || true; echo "------------------"; }

check_get() {
  local name="$1" path="$2" code_ok="${3:-^200$}" id="${4:-1}"
  printf "%s GET  %s -> " "$(blue "$name")" "$(url "$path" "$id")"
  local code; code="$(get "$path" "$id" || true)"
  if [[ -z "$code" ]]; then bad "no response"; show_fail; return; fi
  [[ "$code" =~ $code_ok ]] && ok "$code" || { bad "$code"; show_fail; }
}
check_post() {
  local name="$1" path="$2" json="$3" code_ok="${4:-^(200|201|202|204)$}" id="${5:-1}"
  printf "%s POST %s -> " "$(blue "$name")" "$(url "$path" "$id")"
  if [[ "$READ_ONLY" == "1" ]]; then echo "$(yellow "[SKIPPED]")"; return; fi
  local code; code="$(post "$path" "$json" "$id" || true)"
  if [[ -z "$code" ]]; then bad "no response"; show_fail; return; fi
  [[ "$code" =~ $code_ok ]] && ok "$code" || { bad "$code"; show_fail; }
}
check_patch() {
  local name="$1" path="$2" json="$3" code_ok="${4:-^(200|204)$}" id="$5"
  printf "%s PATCH %s -> " "$(blue "$name")" "$(url "$path" "$id")"
  if [[ "$READ_ONLY" == "1" ]]; then echo "$(yellow "[SKIPPED]")"; return; fi
  local code; code="$(patch "$path" "$json" "$id" || true)"
  if [[ -z "$code" ]]; then bad "no response"; show_fail; return; fi
  [[ "$code" =~ $code_ok ]] && ok "$code" || { bad "$code"; show_fail; }
}
check_delete() {
  local name="$1" path="$2" code_ok="${3:-^(200|204)$}" id="$4"
  printf "%s DEL  %s -> " "$(blue "$name")" "$(url "$path" "$id")"
  if [[ "$READ_ONLY" == "1" ]]; then echo "$(yellow "[SKIPPED]")"; return; fi
  local code; code="$(delete "$path" "$id" || true)"
  if [[ -z "$code" ]]; then bad "no response"; show_fail; return; fi
  [[ "$code" =~ $code_ok ]] && ok "$code" || { bad "$code"; show_fail; }
}

header(){ echo; echo "== $(blue "$1") =="; }

echo "Branch: $(git rev-parse --abbrev-ref HEAD || true)"
echo "Lead ID: $LEAD_ID   Base: $BASE   READ_ONLY: $READ_ONLY"

# ---------- preflight ----------
printf "%s " "$(blue "Preflight: API reachable?")"
if curl -sS -o /dev/null -w "%{http_code}" "$BASE/api/crm/leads" | grep -qE '^(200|204|4..)$'; then
  echo "$(green "OK")"
else
  echo "$(red "Cannot reach $BASE — is Rails running on port 3001?")"
  exit 1
fi

# ---------- 1) Activities ----------
header "1) Activities"
check_get  "Activities#index" "/api/crm/leads/:lead_id/activities(.:format)"
check_post "Activities#create (nested)" "/api/crm/leads/:lead_id/activities(.:format)" \
  "{\"activity\":{\"type\":\"call\",\"description\":\"Smoke: activities nested\"}}"
check_post "Activities#create (root)" "/api/crm/leads/:lead_id/activities(.:format)" \
  "{\"type\":\"note\",\"description\":\"Smoke: activities root\"}"

# ---------- 2) AI Insights ----------
header "2) AI Insights"
check_get  "AI#index" "/api/crm/leads/:lead_id/ai_insights(.:format)"
check_post "AI#generate" "/api/crm/leads/:lead_id/ai_insights/generate(.:format)" \
  "{\"prompt\":\"Summarize latest lead context\"}"
if [[ "$READ_ONLY" != "1" ]]; then
  INS_ID="$(jq -r '.[0].id // empty' /tmp/_out.json 2>/dev/null || true)"
  if [[ -n "${INS_ID:-}" ]]; then
    check_patch "AI#mark_read" "/api/crm/ai_insights/:id/mark_read(.:format)" "{}" "^(200|204)$" "$INS_ID"
  else
    echo "$(yellow "No AI insight id available to mark_read; skipping")"
  fi
fi

# ---------- 3) Reminders ----------
header "3) Reminders"
check_get "Reminders#index" "/api/crm/leads/:lead_id/reminders(.:format)"
if [[ "$READ_ONLY" != "1" ]]; then
  FUTURE="$(date -u -d '+2 days' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -v+2d -u +"%Y-%m-%dT%H:%M:%SZ")"
  check_post "Reminders#create" "/api/crm/leads/:lead_id/reminders(.:format)" \
    "{\"title\":\"Smoke reminder\",\"due_at\":\"$FUTURE\",\"notes\":\"Check FE→BE\"}"
  R_ID="$(jq -r '.id // empty' /tmp/_out.json 2>/dev/null || true)"
  if [[ -n "${R_ID:-}" ]]; then
    check_patch  "Reminders#complete" "/api/crm/reminders/:id/complete(.:format)" "{}" "^(200|204)$" "$R_ID"
    check_delete "Reminders#destroy"  "/api/crm/reminders/:id(.:format)" "^(200|204)$" "$R_ID"
  else
    echo "$(yellow "Could not parse reminder id; skipping complete/destroy")"
  fi
fi

# ---------- 4) Convert Lead ----------
header "4) Convert Lead"
check_post "Leads#convert" "/api/crm/leads/:lead_id/convert(.:format)" \
  "{\"conversion\":{\"stage\":\"customer\",\"note\":\"Smoke conversion\"}}"

# ---------- 5) Tag System ----------
header "5) Tags"
check_get "Tags#entity_tags (lead)" "/api/crm/leads/:lead_id/tags(.:format)"
check_get "Tags#index (global)"      "/api/crm/tags(.:format)"
if [[ "$READ_ONLY" != "1" ]]; then
  check_post "Tags#create (global)" "/api/crm/tags(.:format)" "{\"name\":\"smoke-tag-$(date +%s)\"}"
  TAG_ID="$(jq -r '.id // empty' /tmp/_out.json 2>/dev/null || true)"
  if [[ -n "${TAG_ID:-}" ]]; then
    check_post "Tags#assign (lead)" "/api/crm/tags/assign(.:format)" \
      "{\"tag_id\":${TAG_ID},\"entity_type\":\"Lead\",\"entity_id\":${LEAD_ID}}" "^(200|201|204)$"
  else
    echo "$(yellow "No TAG_ID parsed; skipping assign")"
  fi
fi

# ---------- 6) Lead Scoring ----------
header "6) Lead Scoring"
check_get  "LeadScore#show"      "/api/crm/leads/:lead_id/score(.:format)"
check_post "LeadScore#calculate" "/api/crm/leads/:lead_id/score/calculate(.:format)" "{\"force\":true}" "^(200|201|202|204)$"

# ---------- 7) Communication Center ----------
header "7) Communication Center"
check_get  "Comms#index"     "/api/crm/leads/:lead_id/communications(.:format)"
check_get  "Comms#history"   "/api/crm/leads/:lead_id/communications/history(.:format)"
check_get  "Comms#settings"  "/api/crm/leads/:lead_id/communications/settings(.:format)"
check_post "Comms#send_email" "/api/crm/leads/:lead_id/communications/send_email(.:format)" \
  "{\"to\":\"demo@example.com\",\"subject\":\"Smoke\",\"body\":\"Hello from smoke test\"}"
check_post "Comms#send_sms"  "/api/crm/leads/:lead_id/communications/send_sms(.:format)" \
  "{\"to\":\"+15555550123\",\"body\":\"SMS smoke test\"}" "^(200|201|202|204)$"
check_post "Comms#log"       "/api/crm/leads/:lead_id/communications/log(.:format)" \
  "{\"channel\":\"email\",\"direction\":\"outbound\",\"subject\":\"Logged\",\"body\":\"Logged by smoke\"}" "^(200|201|204)$"

# ---------- summary ----------
echo
echo "================ Summary ================"
echo "PASS: $(green "$pass")   FAIL: $(red "$fail")"
echo "========================================="
if (( fail > 0 )); then exit 1; fi
