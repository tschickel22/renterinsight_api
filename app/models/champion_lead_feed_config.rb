# frozen_string_literal: true

# Champion Lead Feed Config — per-company (or per-location) configuration
# for polling leads from the Champion Retailer API.
#
# Champion issues one non-expiring API key per retailer location via their
# DIGS portal. The key authenticates via X-API-Key header against either
# the Stage or Production API server.
#
# Stage:      https://digs-api-stage.championhomes.com
# Production: https://digs-api-prod.championhomes.com
# Swagger:    https://digs-api-prod.championhomes.com/swagger/index.html
class ChampionLeadFeedConfig < ApplicationRecord
  # ------------------------------------------------------------------
  # Associations
  # ------------------------------------------------------------------
  belongs_to :company
  belongs_to :location, optional: true # nil = company-wide token

  # ------------------------------------------------------------------
  # Encryption
  # ------------------------------------------------------------------
  encrypts :api_token

  # Virtual attribute — the encrypted column is api_token_ciphertext,
  # but Rails `encrypts` provides a transparent api_token accessor.
  # When writing the model you call `config.api_token = "the-key"`.

  # ------------------------------------------------------------------
  # Validations
  # ------------------------------------------------------------------
  validates :api_token, presence: true
  validates :environment, presence: true,
            inclusion: { in: %w[stage production], message: 'must be stage or production' }
  validates :company_id, uniqueness: { scope: :location_id,
            message: 'already has a Champion lead config for this location' }
  validates :sync_interval_minutes, numericality: { greater_than_or_equal_to: 5, less_than_or_equal_to: 1440 }

  # ------------------------------------------------------------------
  # Scopes
  # ------------------------------------------------------------------
  scope :active, -> { where(active: true) }

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------
  def api_base_url
    case environment
    when 'stage'
      'https://digs-api-stage.championhomes.com'
    else
      'https://digs-api-prod.championhomes.com'
    end
  end

  def display_label
    parts = [retailer_name, champion_account_number].compact.reject(&:blank?)
    parts.any? ? parts.join(' — ') : "Config ##{id}"
  end

  # Record a successful sync
  def record_sync_success!(stats = {})
    update!(
      last_synced_at: Time.current,
      last_sync_error: nil,
      last_sync_error_at: nil,
      last_sync_stats: stats,
      total_leads_synced: total_leads_synced + (stats[:created] || 0)
    )
  end

  # Record a failed sync
  def record_sync_failure!(error_message)
    update!(
      last_sync_error_at: Time.current,
      last_sync_error: error_message.truncate(2000)
    )
  end
end
