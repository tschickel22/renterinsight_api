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

  # Lowest per-field extraction rate this run, EXCLUDING any fields the source
  # marks as untracked (e.g. TRU / Clayton Epic pages don't publish descriptions,
  # so a 0.0 on `description` shouldn't drag the health score for those sources).
  # Kept in sync with Catalog::ExtractionStats.degraded?, which uses the same
  # exclusion when computing the `degraded` flag stored on this row.
  # Returns nil when no fields were tracked.
  def worst_field_rate
    tracked_rates.values.map(&:to_f).min
  end

  # Fields that fell below the source threshold, with their rates. Same
  # untracked-field exclusion as worst_field_rate so an "always empty" field
  # never shows up as a health regression.
  def degraded_fields(threshold)
    tracked_rates.select { |_, rate| rate.to_f < threshold.to_f }
  end

  private

  # field_extraction_rates minus the source's untracked_fields set.
  def tracked_rates
    skip = Array(catalog_source&.untracked_fields).map(&:to_s).to_set
    field_extraction_rates.reject { |field, _| skip.include?(field.to_s) }
  end
end
