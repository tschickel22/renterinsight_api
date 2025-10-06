#!/usr/bin/env bash
set -euo pipefail
cd ~/src/renterinsight_api

TAG_FILE=app/models/tag.rb
BACKUP="app/models/tag.rb.bak.$(date +%Y%m%d%H%M%S)"

if [ -f "$TAG_FILE" ]; then
  echo "Backup -> $BACKUP"
  cp -v "$TAG_FILE" "$BACKUP"
fi

cat > "$TAG_FILE" <<'RUBY'
# frozen_string_literal: true
class Tag < ApplicationRecord
  # Controllers use: name, description, color, category, tag_type (array/json), is_system, is_active
  scope :active, -> { where(is_active: [true, nil]) } # treat nil as active for legacy rows
end
RUBY

echo
echo "== tag.rb (first 20 lines) =="
nl -ba "$TAG_FILE" | sed -n '1,20p'

echo
echo "== Reflection check =="
bin/rails runner - <<'RUBY'
puts "Tag responds to .active? -> #{Tag.respond_to?(:active)}"
RUBY
