# frozen_string_literal: true

# Leads Tom adds to a wave by hand past a soft rule (on a nurture, recently
# active, not New...). The send-time check honors the override (backlog E105).
class AddOverrideToOutreachTargets < ActiveRecord::Migration[8.0]
  def change
    add_column :outreach_targets, :override_reason, :string
    add_column :outreach_targets, :overridden_by_user_id, :bigint
  end
end
