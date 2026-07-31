# frozen_string_literal: true

# Auto-generated drafts accumulated indefinitely — prod had 29 of them going
# back seven weeks against 6 posts that actually published. They also inflated
# the "Total Posts" tile, which counted every row regardless of status.
#
# Drafts a human never acted on now expire. Applied retroactively (default 7
# rather than 0) so the existing backlog clears on the first run; the expiry is
# a soft delete, so anything caught by mistake is recoverable.
# 0 disables expiry for a schedule.
class AddDraftRetentionToSocialPostSchedules < ActiveRecord::Migration[8.0]
  def change
    add_column :social_post_schedules, :draft_retention_days, :integer, default: 7, null: false
  end
end
