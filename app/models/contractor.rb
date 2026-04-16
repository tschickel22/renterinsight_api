# frozen_string_literal: true

class Contractor < ApplicationRecord
  has_secure_password validations: false

  belongs_to :company
  has_many :contractor_assignments, dependent: :destroy

  validates :name, presence: true
  validates :status, inclusion: { in: %w[active inactive suspended] }
  validates :trade_type, inclusion: { in: %w[general electrical plumbing hvac foundation transport skirting roofing materials_supplier freight_company equipment_rental lumber concrete appliances other] }

  scope :active, -> { where(status: 'active', is_deleted: [false, nil]) }
  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :by_trade, ->(trade) { where(trade_type: trade) }
  scope :vendors, -> { where(is_vendor: true) }
  scope :contractors_only, -> { where(is_vendor: [false, nil]) }

  # Portal authentication
  def generate_portal_token!
    update!(
      portal_access_token: SecureRandom.random_number(100000..999999).to_s,
      portal_token_expires_at: 30.minutes.from_now
    )
  end

  def portal_token_valid?(token)
    portal_access_token == token && portal_token_expires_at&.future?
  end

  def can_login_with_password?
    password_login_enabled? && password_digest.present?
  end
end
