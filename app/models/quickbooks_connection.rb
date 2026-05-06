# frozen_string_literal: true

class QuickbooksConnection < ApplicationRecord
  belongs_to :company

  STATUS_CONNECTED = 'connected'
  STATUS_DISCONNECTED = 'disconnected'
  STATUS_ERROR = 'error'

  SYNC_MODES = %w[create_only create_and_update].freeze

  validates :company_id, uniqueness: true

  def connected?
    status == STATUS_CONNECTED
  end

  def token_expired?
    token_expires_at.present? && token_expires_at < Time.current
  end

  def refresh_token_expired?
    refresh_token_expires_at.present? && refresh_token_expires_at < Time.current
  end

  def self.for_company(company_id)
    find_by(company_id: company_id)
  end
end
