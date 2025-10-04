#!/usr/bin/env bash
set -euo pipefail
cd ~/src/renterinsight_api

LEAD_FILE=app/models/lead.rb
SOURCE_FILE=app/models/source.rb

test -f "$LEAD_FILE" || { echo "Missing $LEAD_FILE"; exit 1; }

# 1) Add belongs_to :source (optional) if not present
if ! grep -q "belongs_to :source" "$LEAD_FILE"; then
  echo "Adding belongs_to :source to Lead…"
  # Insert after class line
  awk '
    NR==1 && $0 ~ /^#/{print} 
    NR==1 && $0 !~ /^#/ { }
    {print}
  ' "$LEAD_FILE" > "$LEAD_FILE.tmp"  # noop but keeps structure
  # Insert belongs_to just after class declaration
  perl -0777 -pe 's/(class\s+Lead\s+<\s+ApplicationRecord\s*\n)/$1  belongs_to :source, class_name: "Source", optional: true\n\n/s' \
    -i "$LEAD_FILE"
fi

# 2) Ensure minimal Source model exists
if [ ! -f "$SOURCE_FILE" ]; then
  cat > "$SOURCE_FILE" <<'RUBY'
# frozen_string_literal: true
class Source < ApplicationRecord
  has_many :leads, dependent: :nullify
end
RUBY
  echo "Created $SOURCE_FILE"
fi

# 3) Show a quick reflection sanity check
echo "== Reflection check =="
bin/rails runner - <<'RUBY'
puts "Lead.belongs_to :source? -> #{Lead.reflect_on_association(:source)&.macro}"
puts "Source.has_many :leads? -> #{Source.reflect_on_association(:leads)&.macro}"
RUBY

echo "Done. Now restart the server."
