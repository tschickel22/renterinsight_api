#!/usr/bin/env bash
set -euo pipefail
cd ~/src/renterinsight_api

LEAD_FILE=app/models/lead.rb
BACKUP="app/models/lead.rb.bak.$(date +%Y%m%d%H%M%S)"

test -f "$LEAD_FILE" || { echo "Missing $LEAD_FILE"; exit 1; }

echo "Backing up to $BACKUP"
cp -v "$LEAD_FILE" "$BACKUP"

# Remove any previously appended CRM block (from marker to EOF)
if grep -q 'CRM associations (added by fix_crm_wiring)' "$LEAD_FILE"; then
  awk '
    BEGIN{drop=0}
    /CRM associations \(added by fix_crm_wiring\)/{drop=1}
    drop==0{print}
  ' "$LEAD_FILE" > "$LEAD_FILE.tmp.1"
else
  cp "$LEAD_FILE" "$LEAD_FILE.tmp.1"
fi

# Find the last standalone 'end' (the class closer) and insert before it
LAST_END_LINE=$(nl -ba "$LEAD_FILE.tmp.1" | awk '/^[[:space:]]*[0-9]+[[:space:]]+end[[:space:]]*$/{ln=$1} END{print ln+0}')
if [ "$LAST_END_LINE" -le 0 ]; then
  echo "Could not find a closing 'end' in $LEAD_FILE.tmp.1 — aborting."; exit 1
fi

read -r -d '' BLOCK <<'RUBY'
  # === CRM associations (added by fix_crm_wiring) ===
  has_many :activities,           dependent: :destroy
  has_many :reminders,            dependent: :destroy
  has_many :ai_insights,          dependent: :destroy
  has_many :communication_logs,   dependent: :destroy

  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments
RUBY

awk -v insert_line="$LAST_END_LINE" -v block="$BLOCK" '
  NR==insert_line { print block }
  { print }
' "$LEAD_FILE.tmp.1" > "$LEAD_FILE.tmp.2"

mv -v "$LEAD_FILE.tmp.2" "$LEAD_FILE"
rm -f "$LEAD_FILE.tmp.1"

echo
echo "== Snippet around insertion =="
nl -ba "$LEAD_FILE" | sed -n "$((LAST_END_LINE-20)), $((LAST_END_LINE+2))p"

echo
echo "== Quick reflection check =="
bin/rails runner - <<'RUBY'
puts "Lead associations:"
%i[activities reminders ai_insights communication_logs tag_assignments tags].each do |a|
  puts "  #{a} -> #{Lead.reflect_on_association(a)&.macro || 'nil'}"
end
RUBY

echo "Done."
