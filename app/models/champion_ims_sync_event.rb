# frozen_string_literal: true

# A single per-home action recorded during a sync run.
#
# Event types:
#   - 'added'      => new catalog row created from feed
#   - 'updated'    => existing catalog row changed (see `field_changes` for diff)
#   - 'unchanged'  => existing catalog row touched but no fields changed (champion_last_seen_at refresh only)
#   - 'tombstoned' => catalog row no longer in feed and had no dealer activity, soft-deleted
#   - 'protected'  => catalog row no longer in feed but had dealer activity (clones/deals/quotes), kept
#   - 'skipped'    => feed entry could not be saved (validation error or missing data)
#
# `field_changes` shape for 'updated' events:
#   { "make" => { "from" => "Champion", "to" => "Champion Homes" },
#     "bedrooms" => { "from" => 3, "to" => 4 } }
#
# IMPORTANT: This column was originally named `changes` but renamed because
# `changes` collides with ActiveModel::Dirty#changes — Rails was silently
# dropping the value on .create() and breaking the count helper.
class ChampionImsSyncEvent < ApplicationRecord
  belongs_to :champion_ims_sync_run
  belongs_to :vehicle, optional: true # nil for skipped events (no vehicle was created)

  EVENT_TYPES = %w[added updated unchanged tombstoned protected skipped].freeze

  validates :event_type, inclusion: { in: EVENT_TYPES }

  scope :substantive, -> { where.not(event_type: 'unchanged') }
  scope :by_type, ->(type) { where(event_type: type) }

  # Number of fields that changed (0 for non-update events)
  def change_count
    return 0 unless event_type == 'updated'
    return 0 unless field_changes.is_a?(Hash)
    field_changes.size
  end
end
