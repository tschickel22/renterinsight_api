# frozen_string_literal: true

module QuickbooksIntegration
  extend ActiveSupport::Concern

  included do
    has_many :quickbooks_sync_mappings, dependent: :destroy
    has_many :quickbooks_sync_logs, dependent: :destroy
    has_many :quickbooks_field_mappings, dependent: :destroy
    has_many :quickbooks_webhooks, dependent: :destroy
    
    scope :with_quickbooks_enabled, -> { where(quickbooks_sync_enabled: true) }
    scope :with_expired_quickbooks_tokens, -> { 
      where('quickbooks_token_expires_at IS NOT NULL')
        .where('quickbooks_token_expires_at < ?', 30.minutes.from_now)
        .where(quickbooks_sync_enabled: true)
    }
  end

  def quickbooks_connected?
    quickbooks_realm_id.present? && 
      quickbooks_access_token_encrypted.present? &&
      quickbooks_connected_at.present?
  end

  def quickbooks_token_expired?
    return true unless quickbooks_token_expires_at
    quickbooks_token_expires_at < 5.minutes.from_now
  end

  def refresh_quickbooks_token!
    return { success: false, error: 'Not connected' } unless quickbooks_connected?

    service = QuickbooksOauthService.new(self)
    result = service.refresh_token!
    
    if result[:success]
      { success: true, expires_at: quickbooks_token_expires_at }
    else
      disconnect_quickbooks! if result[:error]&.include?('invalid_grant')
      result
    end
  end

  def disconnect_quickbooks!
    update!(
      quickbooks_realm_id: nil,
      quickbooks_connected_at: nil,
      quickbooks_access_token_encrypted: nil,
      quickbooks_refresh_token_encrypted: nil,
      quickbooks_token_expires_at: nil,
      quickbooks_sync_enabled: false
    )
    
    { success: true }
  end

  def resolved_quickbooks_settings
    settings = quickbooks_settings.presence || {}
    
    if is_a?(Location) && settings.blank?
      settings = company.quickbooks_settings.presence || {}
    end
    
    settings.blank? ? default_quickbooks_settings : settings.deep_symbolize_keys
  end

  def update_quickbooks_settings!(new_settings)
    current = integration_settings || {}
    current['quickbooks'] = new_settings
    update!(integration_settings: current)
  end

  def quickbooks_settings
    integration_settings&.dig('quickbooks')
  end

  def default_quickbooks_settings
    {
      enabled: false,
      auto_sync: false,
      sync_frequency_minutes: 15,
      entities: {
        inventory: {
          enabled: false, sync_direction: 'bidirectional', map_as: 'Item',
          track_quantity: true, default_account: nil
        },
        customers: {
          enabled: false, sync_direction: 'to_qb', map_as: 'Customer',
          include_contacts: true, include_leads: false
        },
        invoices: {
          enabled: false, sync_direction: 'to_qb', map_as: 'Invoice',
          auto_create: true, default_terms: 'Net 30'
        },
        payments: {
          enabled: false, sync_direction: 'to_qb', map_as: 'Payment',
          deposit_to_account: nil
        },
        vendors: {
          enabled: false, sync_direction: 'to_qb', map_as: 'Vendor'
        },
        purchases: {
          enabled: false, sync_direction: 'to_qb', map_as: 'Purchase'
        }
      },
      notifications: {
        sync_errors: true, sync_success: false, email_recipients: []
      }
    }
  end

  def quickbooks_sync_stats(time_period = 24.hours)
    logs = quickbooks_sync_logs.where('created_at >= ?', time_period.ago)
    
    {
      total: logs.count,
      successful: logs.where(status: 'success').count,
      failed: logs.where(status: 'error').count,
      success_rate: logs.count > 0 ? (logs.where(status: 'success').count.to_f / logs.count * 100).round(2) : 0,
      avg_duration_ms: logs.where.not(duration_ms: nil).average(:duration_ms)&.round(2),
      last_sync: quickbooks_last_sync_at
    }
  end

  def pending_quickbooks_syncs
    quickbooks_sync_mappings.where(sync_status: ['pending', 'error']).count
  end

  def active_quickbooks_mappings
    quickbooks_sync_mappings.where(sync_status: 'active')
  end
end
