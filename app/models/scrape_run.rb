# frozen_string_literal: true

# One execution of Catalog::RunService for a single CatalogSource.
# Created at the start of every run, finalized to a terminal status when done.
# Powers the platform-admin health view.
class ScrapeRun < ApplicationRecord
  belongs_to :catalog_source

  STATUSES = %w[running success partial failed].freeze
  TRIGGERS = %w[manual scheduled].freeze

  validates :status,  inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }

  scope :recent, -> { order(created_at: :desc) }

  def duration_seconds
    return nil unless started_at && finished_at

    (finished_at - started_at).round
  end

  # Lowest per-field extraction rate this run (nil when no fields were tracked).
  def worst_field_rate
    rates = field_extraction_rates.values.map(&:to_f)
    rates.min
  end

  # Fields that fell below the source threshold, with their rates.
  def degraded_fields(threshold)
    field_extraction_rates.select { |_, rate| rate.to_f < threshold.to_f }
  end
end
