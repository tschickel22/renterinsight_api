# frozen_string_literal: true

# Per-intent idea text for scheduled social posts. Keyed by intent (e.g.
# { "feature_spotlight" => "Highlight the new analytics dashboard" }). Optional and
# additive: a blank/absent note keeps today's context-only behavior; a filled note is
# passed as topic_details for that slot. intent_rotation remains the source of order.
class AddIntentNotesToSocialPostSchedules < ActiveRecord::Migration[8.0]
  def change
    add_column :social_post_schedules, :intent_notes, :jsonb, default: {}, null: false
  end
end
