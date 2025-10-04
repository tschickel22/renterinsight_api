#!/usr/bin/env bash
set -euo pipefail
cd ~/src/renterinsight_api

echo "== Check current leads columns =="
bin/rails runner - <<'RUBY'
require "active_record"
cols = ActiveRecord::Base.connection.columns(:leads).map(&:name)
puts "leads columns: #{cols.inspect}"
puts "missing converted_account_id? -> #{!cols.include?('converted_account_id')}"
puts "missing status? -> #{!cols.include?('status')}"
RUBY

NEED_CONV=$(bin/rails runner - <<'RUBY'
require "active_record"; puts ActiveRecord::Base.connection.columns(:leads).none?{|c| c.name=="converted_account_id"} ? "yes" : "no"
RUBY
)
NEED_STATUS=$(bin/rails runner - <<'RUBY'
require "active_record"; puts ActiveRecord::Base.connection.columns(:leads).none?{|c| c.name=="status"} ? "yes" : "no"
RUBY
)

if [ "$NEED_CONV" = "yes" ] || [ "$NEED_STATUS" = "yes" ]; then
  TS=$(date +%Y%m%d%H%M%S)
  FILE="db/migrate/${TS}_add_convert_fields_to_leads.rb"
  echo "== Creating migration: $FILE =="
  cat > "$FILE" <<'RUBY'
class AddConvertFieldsToLeads < ActiveRecord::Migration[7.1]
  def change
    add_column :leads, :converted_account_id, :bigint unless column_exists?(:leads, :converted_account_id)
    add_column :leads, :status, :string unless column_exists?(:leads, :status)
    add_index  :leads, :converted_account_id unless index_exists?(:leads, :converted_account_id)
  end
end
RUBY

  echo "== Migrating =="
  bin/rails db:migrate
else
  echo "No migration needed."
fi

echo "== Ensure Lead association (optional) =="
LEAD_FILE=app/models/lead.rb
if ! grep -q "belongs_to :converted_account" "$LEAD_FILE" 2>/dev/null; then
  perl -0777 -pe 's/(class\s+Lead\s+<\s+ApplicationRecord\s*\n)/$1  belongs_to :converted_account, class_name: "Account", optional: true\n\n/s' -i "$LEAD_FILE"
  echo "Added belongs_to :converted_account to Lead."
else
  echo "Lead already has belongs_to :converted_account."
fi

echo "== Restart Puma =="
pkill -f "puma.*3001" 2>/dev/null || true
bin/rails s -p 3001 >/dev/null 2>&1 & sleep 2
ss -ltnp | grep 3001 || echo "Server not bound to :3001?"

echo "== Re-test convert =="
BASE=${BASE:-http://127.0.0.1:3001}
LEAD_ID=${LEAD_ID:-18}
TMP_H=$(mktemp); TMP_B=$(mktemp)
curl -sS -D "$TMP_H" -o "$TMP_B" -H "Content-Type: application/json" \
  -X POST "$BASE/api/crm/leads/$LEAD_ID/convert" -w "\nHTTP=%{http_code}\n"
echo "-- headers --"; sed -n '1,80p' "$TMP_H"
echo "-- body --"; cat "$TMP_B"; echo
