# frozen_string_literal: true

# Champion IMS Retailer - per-company configuration for syncing homes from
# the Champion Homes Inventory Management System (IMS) feed.
#
# Each record represents one Retailer Navision ID (e.g., "0551KS" = Heartland
# Homes in Kansas) that a dealer wants to pull into their shared FloorPlan
# catalog. Multiple retailers can be configured per company.
#
# Sync behavior:
#   - Default frequency: weekly (Sundays at 2am UTC via ChampionImsWeeklySyncJob)
#   - Manual frequency: only runs when admin clicks "Sync Now"
#   - Each sync upserts into floor_plans keyed on [manufacturer_id, model_code]
#   - No Vehicle records are created here - that's a separate bulk-import step
class ChampionImsRetailer < ApplicationRecord
  # ------------------------------------------------------------------
  # Associations
  # ------------------------------------------------------------------
  belongs_to :company
  belongs_to :location, optional: true

  # ------------------------------------------------------------------
  # Validations
  # ------------------------------------------------------------------
  # Navision ID format: 4 digits + 2 uppercase letters (e.g., "0551KS")
  NAVISION_ID_FORMAT = /\A\d{4}[A-Z]{2}\z/.freeze

  validates :retailer_navision_id,
            presence: true,
            format: {
              with: NAVISION_ID_FORMAT,
              message: 'must be 4 digits followed by 2 uppercase letters (e.g., 0551KS)'
            }
  validates :retailer_navision_id, uniqueness: { scope: :company_id }

  validates :sync_frequency, inclusion: { in: %w[weekly manual] }
  validates :last_sync_status, inclusion: { in: %w[pending running success failed] }

  # ------------------------------------------------------------------
  # Callbacks
  # ------------------------------------------------------------------
  before_validation :normalize_navision_id

  # ------------------------------------------------------------------
  # Scopes
  # ------------------------------------------------------------------
  scope :active,  -> { where(active: true) }
  scope :weekly,  -> { where(sync_frequency: 'weekly') }
  scope :manual,  -> { where(sync_frequency: 'manual') }

  # Retailers that should be processed by the weekly cron:
  #   - active
  #   - sync_frequency == 'weekly'
  #   - either never synced OR next_scheduled_sync_at has passed
  scope :due_for_sync, -> {
    active
      .weekly
      .where('next_scheduled_sync_at IS NULL OR next_scheduled_sync_at <= ?', Time.current)
  }

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------
  # Human-friendly label for logs and UI.
  def display_label
    [retailer_navision_id, retailer_name].compact.reject(&:blank?).join(' - ')
  end

  def sync_running?
    last_sync_status == 'running'
  end

  def sync_successful?
    last_sync_status == 'success'
  end

  def sync_failed?
    last_sync_status == 'failed'
  end

  private

  def normalize_navision_id
    return if retailer_navision_id.blank?

    self.retailer_navision_id = retailer_navision_id.to_s.strip.upcase
  end
end
