# frozen_string_literal: true

class Contractor < ApplicationRecord
  belongs_to :company
  has_many :contractor_assignments, dependent: :destroy

  validates :name, presence: true
  validates :status, inclusion: { in: %w[active inactive suspended] }
  validates :trade_type, inclusion: { in: %w[general electrical plumbing hvac foundation transport skirting roofing other] }

  scope :active, -> { where(status: 'active', is_deleted: [false, nil]) }
  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :by_trade, ->(trade) { where(trade_type: trade) }

  # Portal authentication
  def generate_portal_token!
    update!(
      portal_access_token: SecureRandom.urlsafe_base64(32),
      portal_token_expires_at: 30.minutes.from_now
    )
  end

  def portal_token_valid?(token)
    portal_access_token == token && portal_token_expires_at&.future?
  end
end
