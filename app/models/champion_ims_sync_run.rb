# frozen_string_literal: true

# A single execution of Scrapers::ChampionImsSyncService for one retailer.
# Created at the start of every sync, updated to terminal status when done.
#
# Children: champion_ims_sync_events (one per home processed).
#
# Trigger values:
#   - 'manual'    => user clicked Sync Now or it was kicked off via Rails console
#   - 'scheduled' => weekly cron via ChampionImsWeeklySyncJob
class ChampionImsSyncRun < ApplicationRecord
  belongs_to :company
  belongs_to :champion_ims_retailer
  has_many :events,
           class_name: 'ChampionImsSyncEvent',
           dependent:  :destroy

  STATUSES = %w[running success failed].freeze
  TRIGGERS = %w[manual scheduled].freeze

  validates :status,  inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }

  scope :recent, -> { order(started_at: :desc) }

  def succeeded?
    status == 'success'
  end

  def failed?
    status == 'failed'
  end

  def running?
    status == 'running'
  end

  # Has this run produced any meaningful change for the dealer?
  # "No-op" runs (everything unchanged, nothing added/updated/tombstoned/skipped)
  # collapse in the history view so the timeline stays readable.
  def no_op?
    catalog_added.zero? &&
      catalog_updated.zero? &&
      catalog_tombstoned.zero? &&
      vehicles_skipped.zero?
  end
end
