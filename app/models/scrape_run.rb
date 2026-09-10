# frozen_string_literal: true

# One execution of Catalog::RunService for a single CatalogSource.
# Created at the start of every run, finalized to a terminal status when done.
# Powers the platform-admin health view.
class ScrapeRun < ApplicationRecord
  belongs_to :catalog_source

  STATUSES = %w[running success partial failed].freeze
  # 'subscription' distinguishes the run a dealer opting in triggers from the
  # nightly crawl. Both used to record 'scheduled', so run history could not
  # explain why a source suddenly started crawling in the middle of the day.
  TRIGGERS = %w[manual scheduled subscription].freeze

  # A run still "running" after this long is presumed dead: the in-Puma worker
  # can be killed mid-crawl by a deploy or restart, which leaves the row (and
  # the source's last_run_status) claiming "running" forever.
  #
  # Lives here rather than in the admin controller because reaping used to
  # happen ONLY when someone pressed Run Now — so a source killed by a deploy
  # reported a phantom in-progress run to every other reader until somebody
  # happened to click that button.
  # A run is dead when it stops making progress, not when it gets old.
  #
  # This used to be measured from started_at alone at 30 minutes, which is both
  # too slow and the wrong question: the worker runs inside Puma here, so every
  # deploy kills whatever was crawling, and the admin then watches a "running"
  # badge for half an hour on a run no process is executing. Every phase of a
  # run touches its row (see Catalog::RunService), so a row that has not moved
  # in ten minutes has nobody behind it.
  #
  # There is deliberately no outer bound on total duration. The old 30 minute
  # one would reap a HEALTHY crawl: a large catalog with image archiving runs
  # well past that, and killing it at the half hour mark loses the whole run.
  # A run that never wrote anything is still caught, because its row has not
  # been touched since it was created.
  PROGRESS_STALE_AFTER = 10.minutes

  validates :status,  inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }

  scope :recent,      -> { order(created_at: :desc) }
  scope :in_progress, -> { where(status: 'running') }
  scope :stale, -> { in_progress.where(updated_at: ..PROGRESS_STALE_AFTER.ago) }

  # Mark abandoned runs failed and un-stick the sources pointing at them.
  # Safe on any read path: it only touches rows that have stopped moving, and
  # does nothing when there are none.
  def self.reap_stale!(scope = all)
    stale_runs = scope.stale.to_a
    return 0 if stale_runs.empty?

    stale_runs.each do |run|
      run.update_columns(
        status: 'failed', finished_at: Time.current,
        error_log: [{ 'message' => 'Run did not finish (worker stopped, most likely a deploy) — marked stale' }]
      )
    end

    CatalogSource.where(id: stale_runs.map(&:catalog_source_id).uniq, last_run_status: 'running')
                 .update_all(last_run_status: 'failed')
    stale_runs.size
  end

  # True while this run is genuinely in flight — a row abandoned by a dead
  # worker is not, however much its status column insists otherwise.
  def actually_running?
    status == 'running' && started_at.present? && updated_at > PROGRESS_STALE_AFTER.ago
  end

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
