# frozen_string_literal: true

# Champion Lead Feed Config — per-company (or per-location) configuration
# for polling leads from the Champion Retailer API.
#
# Champion issues one non-expiring API key per retailer location via their
# DIGS portal, and a location that buys from more than one Champion factory
# gets one key per factory. So a location can have several configs; each lead
# remembers the config that brought it in (leads.champion_config_id). The key authenticates via X-API-Key header against either
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
  belongs_to :default_lead_owner, class_name: 'User', optional: true

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
  validate  :api_token_not_already_used
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

  private

  # The same key added twice would import every lead twice. Tokens are
  # encrypted, so compare them in Ruby; a company has only a handful.
  def api_token_not_already_used
    return if api_token.blank? || company.nil?
    return unless new_record? || will_save_change_to_api_token?
    others = company.champion_lead_feed_configs.where.not(id: id)
    return unless others.any? { |c| c.api_token == api_token }
    errors.add(:api_token, 'is already used by another Champion feed')
  end
end
