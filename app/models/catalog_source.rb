# frozen_string_literal: true

# Platform-admin–managed registry of manufacturer catalog sources.
#
# A CatalogSource is platform-level config (NOT tenant-scoped — there is no
# company_id). Each row names one manufacturer on one platform and binds it to
# an adapter type. Adding a new manufacturer on an already-supported platform is
# a row insert, not a code change.
#
# Dealer opt-in (Surface A) is a separate join — see DealerCatalogSubscription.
class CatalogSource < ApplicationRecord
  ADAPTER_TYPES   = %w[champion_feed manufacturedhomes_platform timber_creek_dealer
                       avada_sitemap tru_model_line clayton_epic_region
                       clayton_retail_home_center trove_catalog cavco_retailer
                       adventure_homes].freeze
  RUN_STATUSES    = %w[never_run success partial failed].freeze
  SCHEDULES       = %w[daily weekly manual].freeze

  has_many :scrape_runs, dependent: :destroy
  has_many :dealer_catalog_subscriptions, dependent: :destroy

  before_validation :normalize_schedule

  validates :name, presence: true
  validates :adapter_type, presence: true, inclusion: { in: ADAPTER_TYPES }
  validates :schedule, inclusion: { in: SCHEDULES }
  validates :extraction_threshold,
            numericality: { greater_than: 0, less_than_or_equal_to: 1 }

  scope :active,  -> { where(is_deleted: [false, nil]) }
  scope :enabled, -> { active.where(enabled: true) }

  # Is this enabled source due for an automatic run, given its cadence? The
  # nightly dispatcher wakes at 1am and runs only sources that return true here.
  # Thresholds carry slack so a daily check never skips a cycle on timing jitter.
  #   daily  -> last run > 20h ago
  #   weekly -> last run > 6 days ago
  #   manual -> never (Run Now only)
  def due?(now = Time.current)
    return false unless enabled && !is_deleted

    case schedule
    when 'manual' then false
    when 'weekly' then last_run_at.nil? || last_run_at < now - 6.days
    else               last_run_at.nil? || last_run_at < now - 20.hours
    end
  end

  # Resolve the adapter instance for this source (nil if adapter_type unknown).
  def adapter
    Catalog::AdapterRegistry.for(self)
  end

  def latest_run
    scrape_runs.order(created_at: :desc).first
  end

  # Latest run dropped a tracked field below threshold.
  def degraded?
    latest_run&.degraded == true
  end

  # Fields the health monitor should ignore for THIS source. The site may
  # genuinely not publish some fields (e.g. Tru has no on-page description),
  # so an admin can list them here and the source can still reach a clean
  # "success" run — dealer subscription requires that.
  def untracked_fields
    Array(config.is_a?(Hash) ? config['untracked_fields'] : nil).map(&:to_s)
  end

  # A source has passed validation when its latest run succeeded cleanly.
  def passed_clean_run?
    !is_deleted && last_run_status == 'success' && !degraded?
  end

  # A passing dry-run Test (discovered > 0, not degraded) is recorded here so it
  # can satisfy the ENABLE gate without forcing a full run first.
  def test_passed?
    config.is_a?(Hash) && config['test_passed_at'].present?
  end

  # Gate for ENABLING: a clean full run OR a passing Test proves extraction works.
  # (Dealer-selectability is stricter — see selectable_for_dealers?.)
  def enableable?
    !is_deleted && (passed_clean_run? || test_passed?)
  end

  def record_test_pass!
    update_column(:config, (config || {}).merge('test_passed_at' => Time.current.utc.iso8601))
  end

  # Dealers may only subscribe to a source that is BOTH enabled and validated.
  # "never_run" sources are not selectable — they must pass a run first.
  def selectable_for_dealers?
    enabled && passed_clean_run?
  end

  # worst per-field extraction rate from the latest run (nil if no run yet)
  def worst_field_rate
    latest_run&.worst_field_rate
  end

  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end

  private

  # Accept legacy / free-text values and coerce to the enum: blank or unknown
  # defaults to weekly; the old "nightly" maps to daily.
  def normalize_schedule
    value = schedule.to_s.strip.downcase
    value = 'daily' if value == 'nightly'
    self.schedule = SCHEDULES.include?(value) ? value : 'weekly'
  end
end
