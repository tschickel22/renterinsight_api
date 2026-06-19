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
  ADAPTER_TYPES   = %w[champion_feed manufacturedhomes_platform avada_sitemap].freeze
  RUN_STATUSES    = %w[never_run success partial failed].freeze

  has_many :scrape_runs, dependent: :destroy
  has_many :dealer_catalog_subscriptions, dependent: :destroy

  validates :name, presence: true
  validates :adapter_type, presence: true, inclusion: { in: ADAPTER_TYPES }
  validates :extraction_threshold,
            numericality: { greater_than: 0, less_than_or_equal_to: 1 }

  scope :active,  -> { where(is_deleted: [false, nil]) }
  scope :enabled, -> { active.where(enabled: true) }

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

  # A source has passed validation when its latest run succeeded cleanly. This
  # gates ENABLING (you can't enable until you've proven extraction works).
  def passed_clean_run?
    !is_deleted && last_run_status == 'success' && !degraded?
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
end
