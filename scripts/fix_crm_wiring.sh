#!/usr/bin/env bash
# scripts/fix_crm_wiring.sh
set -euo pipefail
cd ~/src/renterinsight_api

echo "== Detecting current state (tables) =="
bin/rails runner - <<'RUBY'
require "active_record"
def has_table?(t) = ActiveRecord::Base.connection.data_source_exists?(t)
puts "tables:"
%w[activities reminders tags taggings tag_assignments communications communication_logs ai_insights lead_scores].each do |t|
  puts "  #{t.ljust(20)} -> #{has_table?(t)}"
end
RUBY

echo "== Creating/overwriting minimal models (idempotent) =="

# Reminder
cat > app/models/reminder.rb <<'RUBY'
# frozen_string_literal: true
class Reminder < ApplicationRecord
  self.table_name = 'reminders'
  belongs_to :lead

  validates :title, presence: true
  validates :reminder_type, inclusion: { in: %w[call email task follow_up other], allow_nil: true }

  scope :upcoming, -> { where(is_completed: [false, nil]).order(due_date: :asc) }

  def complete!
    update!(is_completed: true)
  end
end
RUBY

# AiInsight
cat > app/models/ai_insight.rb <<'RUBY'
# frozen_string_literal: true
class AiInsight < ApplicationRecord
  self.table_name = 'ai_insights'
  belongs_to :lead

  scope :recent, -> { order(Arel.sql("COALESCE(generated_at, created_at) DESC")) }

  def mark_as_read!
    update!(is_read: true)
  end
end
RUBY

# LeadScore
cat > app/models/lead_score.rb <<'RUBY'
# frozen_string_literal: true
class LeadScore < ApplicationRecord
  self.table_name = 'lead_scores'
  belongs_to :lead
end
RUBY

# CommunicationLog (controller references this, not Communication)
cat > app/models/communication_log.rb <<'RUBY'
# frozen_string_literal: true
class CommunicationLog < ApplicationRecord
  self.table_name = 'communication_logs'
  belongs_to :lead

  validates :comm_type, inclusion: { in: %w[email sms call note], allow_nil: true }

  scope :for_lead, ->(lead_id) { where(lead_id: lead_id) }
  scope :recent,   -> { order(Arel.sql("COALESCE(sent_at, created_at) DESC")) }
end
RUBY

# TagAssignment (controller references this, not Tagging)
cat > app/models/tag_assignment.rb <<'RUBY'
# frozen_string_literal: true
class TagAssignment < ApplicationRecord
  self.table_name = 'tag_assignments'
  belongs_to :tag
  belongs_to :entity, polymorphic: true
  scope :for_entity, ->(etype, eid) { where(entity_type: etype, entity_id: eid) }
end
RUBY

echo "== Ensuring Lead associations =="
if ! grep -q "has_many :reminders" app/models/lead.rb 2>/dev/null; then
  cat >> app/models/lead.rb <<'RUBY'

  # === CRM associations (added by fix_crm_wiring) ===
  has_many :reminders, dependent: :destroy
  has_many :ai_insights, dependent: :destroy
  has_many :communication_logs, dependent: :destroy

  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments
RUBY
fi

echo "== Patching TagsController#entity_tags to infer lead route (backup -> .bak) =="
CTRL="app/controllers/api/crm/tags_controller.rb"
if [ -f "$CTRL" ]; then
  cp -n "$CTRL" "${CTRL}.bak" || true
  # only patch if not already inferring lead_id
  if ! grep -q 'params\[:lead_id\]' "$CTRL"; then
    perl -0777 -pe '
      s/def\s+entity_tags.*?render json:.*?\n\s*end/def entity_tags\n  entity_type = params[:entity_type]\n  entity_id   = params[:entity_id]\n  if entity_type.blank? && params[:lead_id].present?\n    entity_type = "Lead"\n    entity_id   = params[:lead_id]\n  end\n  assignments = TagAssignment.includes(:tag).for_entity(entity_type, entity_id)\n  tags = assignments.map(&:tag)\n  render json: tags.map { |t| tag_json(t) }\nend/sm' \
      -i "$CTRL"
  fi
fi

echo "== Checking which migrations are needed =="
CL_STATE=$(bin/rails runner - <<'RUBY'
require "active_record"
puts ActiveRecord::Base.connection.data_source_exists?('communication_logs') ? "present" : "missing"
RUBY
)
TA_STATE=$(bin/rails runner - <<'RUBY'
require "active_record"
puts ActiveRecord::Base.connection.data_source_exists?('tag_assignments') ? "present" : "missing"
RUBY
)

TS=$(date +%Y%m%d%H%M%S)

if [ "$CL_STATE" = "missing" ]; then
  F="db/migrate/${TS}_create_communication_logs.rb"
  cat > "$F" <<'RUBY'
class CreateCommunicationLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :communication_logs do |t|
      t.references :lead, null: false, foreign_key: true
      t.string   :comm_type
      t.string   :direction
      t.string   :subject
      t.text     :content
      t.string   :status
      t.datetime :sent_at
      t.jsonb    :metadata, default: {}
      t.timestamps
    end
    add_index :communication_logs, [:lead_id, :comm_type]
    add_index :communication_logs, :sent_at
  end
end
RUBY
  echo "Created migration: $F"
  sleep 1
else
  echo "communication_logs table already present"
fi

if [ "$TA_STATE" = "missing" ]; then
  F="db/migrate/$(date +%Y%m%d%H%M%S)_create_tag_assignments.rb"
  cat > "$F" <<'RUBY'
class CreateTagAssignments < ActiveRecord::Migration[7.1]
  def change
    create_table :tag_assignments do |t|
      t.references :tag, null: false, foreign_key: true
      t.string  :entity_type, null: false
      t.bigint  :entity_id,   null: false
      t.string  :assigned_by
      t.datetime :assigned_at
      t.timestamps
    end
    add_index :tag_assignments, [:entity_type, :entity_id]
  end
end
RUBY
  echo "Created migration: $F"
else
  echo "tag_assignments table already present"
fi

echo "== Running migrations =="
bin/rails db:migrate

echo "== Re-running read-only smoke for the GETs =="
READ_ONLY=1 LEAD_ID=${LEAD_ID:-18} BASE=${BASE:-http://127.0.0.1:3001} bash scripts/smoke_modules.sh || true

echo "Done."
