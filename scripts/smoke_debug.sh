#!/usr/bin/env bash
# Usage:
#   LEAD_ID=18 BASE=http://127.0.0.1:3001 bash scripts/smoke_debug.sh
set -euo pipefail

BASE=${BASE:-http://127.0.0.1:3001}
LEAD_ID=${LEAD_ID:-1}

blue(){ printf "\033[36m%s\033[0m" "$1"; }
green(){ printf "\033[32m%s\033[0m" "$1"; }
red(){ printf "\033[31m%s\033[0m" "$1"; }
yellow(){ printf "\033[33m%s\033[0m" "$1"; }

strip_format() { sed -E 's/\(.\:format\)//g'; }
sub_ids()      { sed -E "s/:lead_id/${LEAD_ID}/g; s/:id/${1:-1}/g"; }
u()            { echo -n "$BASE$(echo "$1" | strip_format | sub_ids "${2:-1}")"; }

# Extract log chunk between 'Parameters: ... dbg"=>"TOKEN' and 'Completed ...'
log_chunk() {
  local token="$1"
  # Grab the last 1000 lines (adjust if needed)
  tail -n 1000 log/development.log \
  | awk -v t="\"dbg\"=>\"$token\"" '
      $0 ~ t && start==0 { start=1 }
      start==1 { print }
      start==1 && $0 ~ /^Completed / { exit }
    '
}

run_get() {
  local name="$1" path="$2" id="${3:-1}"
  local token="$(date +%s%N)"
  local url="$(u "$path" "$id")"
  # add dbg token as query param
  if [[ "$url" == *\?* ]]; then url="$url&dbg=$token"; else url="$url?dbg=$token"; fi

  printf "%s GET %s -> " "$(blue "$name")" "$url"
  local code
  code="$(curl -sS -o /tmp/_resp.json -w "%{http_code}" "$url" || true)"
  if [[ "$code" =~ ^200$ ]]; then
    echo "$(green "200")"
  else
    echo "$(red "$code")"
    echo "---- Response body (truncated) ----"
    sed -n '1,120p' /tmp/_resp.json || true
    echo "-----------------------------------"
    echo "---- Rails log snippet ----"
    log_chunk "$token" | sed -n '1,200p'
    echo "---------------------------"
  fi
}

echo "Branch: $(git rev-parse --abbrev-ref HEAD || true)"
echo "Lead ID: $LEAD_ID   Base: $BASE"
printf "%s " "$(blue "Preflight: API reachable?")"
if curl -sS -o /dev/null -w "%{http_code}" "$BASE/api/crm/leads" | grep -qE '^(200|204|4..)$'; then
  echo "$(green "OK")"
else
  echo "$(red "Cannot reach $BASE — is Rails running?")"
  exit 1
fi

echo
echo "== $(blue "Debug failing GET endpoints") =="

# From your smoke: these returned 500; we'll probe each with dbg token
run_get "AI Insights#index"         "/api/crm/leads/:lead_id/ai_insights(.:format)"
run_get "Reminders#index"           "/api/crm/leads/:lead_id/reminders(.:format)"
run_get "Tags#entity_tags (lead)"   "/api/crm/leads/:lead_id/tags(.:format)"
run_get "Tags#index (global)"       "/api/crm/tags(.:format)"
run_get "LeadScore#show"            "/api/crm/leads/:lead_id/score(.:format)"
run_get "Comms#index"               "/api/crm/leads/:lead_id/communications(.:format)"
run_get "Comms#history"             "/api/crm/leads/:lead_id/communications/history(.:format)"
# Settings was 200; skip it.

echo
echo "Done. If any 500s remain, the stacktrace should be in the snippet above."
