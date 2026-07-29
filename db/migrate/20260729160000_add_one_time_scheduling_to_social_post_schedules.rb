# frozen_string_literal: true

# There was no way to schedule a single post for a future time. The scheduler
# only produced recurring cadences, and the composer could publish immediately
# or save a draft — nothing in between.
#
#   run_at     — when a one_time schedule fires. Recurring schedules keep
#                deriving their slots from preferred_times/preferred_days.
#   vehicle_id — the specific unit to feature. Only meaningful for one_time,
#                where the user knows exactly which home they mean; recurring
#                schedules keep drawing from inventory via the picker.
class AddOneTimeSchedulingToSocialPostSchedules < ActiveRecord::Migration[8.0]
  def change
    add_column :social_post_schedules, :run_at, :datetime
    add_column :social_post_schedules, :vehicle_id, :bigint
    add_index  :social_post_schedules, :vehicle_id
  end
end
