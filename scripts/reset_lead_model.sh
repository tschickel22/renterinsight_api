#!/usr/bin/env bash
set -euo pipefail
cd ~/src/renterinsight_api

LEAD_FILE=app/models/lead.rb
BACKUP="app/models/lead.rb.bak.$(date +%Y%m%d%H%M%S)"

test -f "$LEAD_FILE" || { echo "Missing $LEAD_FILE"; exit 1; }

echo "Backup -> $BACKUP"
cp -v "$LEAD_FILE" "$BACKUP"

cat > "$LEAD_FILE" <<'RUBY'
# frozen_string_literal: true

class Lead < ApplicationRecord
  # Core CRM associations
  has_many :activities,           dependent: :destroy
  has_many :reminders,            dependent: :destroy
  has_many :ai_insights,          dependent: :destroy
  has_many :communication_logs,   dependent: :destroy

  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments
end
RUBY

echo
echo "== lead.rb (first 40 lines) =="
nl -ba "$LEAD_FILE" | sed -n '1,40p'
