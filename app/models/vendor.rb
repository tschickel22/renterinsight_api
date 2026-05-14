# frozen_string_literal: true

class Vendor < ApplicationRecord
  # Storage column on vendors is `custom_field_values`; the Customizable
  # concern is written against `custom_fields`. Alias bridges the two.
  alias_attribute :custom_fields, :custom_field_values

  include Customizable

  has_secure_password validations: false

  # ----- Associations -----
  belongs_to :company
  belongs_to :default_expense_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true

  # Contractor surface
  has_many :contractor_assignments, dependent: :destroy

  # Supplier surface — supplier_parts.supplier_id holds vendor IDs after migration
  has_many :supplier_parts, foreign_key: :supplier_id, dependent: :destroy
  has_many :parts, through: :supplier_parts

  # Polymorphic agreement surface (signable_type/attachable_type rewritten to 'Vendor')
  has_many :agreement_signers,     as: :signable,   dependent: :nullify
  has_many :agreement_attachments, as: :attachable, dependent: :destroy

  # Accounting surface — these tables have a `vendor_id` column after the migration.
  has_many :bills,             dependent: :nullify
  has_many :purchase_orders,   dependent: :nullify
  has_many :recurring_bills,   dependent: :nullify

  # ----- Constants -----
  VENDOR_TYPES = %w[contractor supplier service_provider utility other].freeze
  TRADE_TYPES  = %w[
    general electrical plumbing hvac foundation transport skirting roofing
    materials_supplier freight_company equipment_rental lumber concrete appliances other
  ].freeze
  STATUSES = %w[active inactive suspended].freeze

  # ----- Validations -----
  validates :name, presence: true, length: { maximum: 255 }
  validates :vendor_type, inclusion: { in: VENDOR_TYPES }, allow_blank: true
  validates :status,      inclusion: { in: STATUSES },     allow_blank: true
  validates :trade_type,  inclusion: { in: TRADE_TYPES },  allow_blank: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :phone, length: { maximum: 20 }, allow_blank: true
  validates :code, uniqueness: {
    scope: :company_id,
    conditions: -> { where(is_deleted: [false, nil]) },
    allow_nil: true
  }, allow_blank: true

  # ----- Scopes -----
  scope :active,           -> { where(status: 'active', is_deleted: [false, nil]) }
  scope :not_deleted,      -> { where(is_deleted: [false, nil]) }
  scope :by_trade,         ->(trade) { where(trade_type: trade) }
  scope :only_contractors, -> { where(vendor_type: 'contractor') }
  scope :only_suppliers,   -> { where(vendor_type: 'supplier') }
  scope :eligible_1099,    -> { where(is_1099_eligible: true) }
  scope :for_company,      ->(company_id) { where(company_id: company_id, is_deleted: [false, nil]) }
  scope :by_name,          -> { order(:name) }

  before_validation :normalize_fields

  # ----- Portal authentication (was on Contractor) -----
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

  # ----- Soft delete (was on Supplier) -----
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current, active: false, status: 'inactive')
  end

  def restore!
    update!(is_deleted: false, deleted_at: nil, active: true, status: 'active')
  end

  # ----- Display -----
  def display_name
    code.present? ? "#{name} (#{code})" : name
  end

  def full_address
    parts = [address_line1, address_line2, city, state, zip_code, country].compact.reject(&:blank?)
    parts.any? ? parts.join(', ') : nil
  end

  def contractor?
    vendor_type == 'contractor'
  end

  def supplier?
    vendor_type == 'supplier'
  end

  private

  def normalize_fields
    self.name = name&.strip
    self.code = code&.strip&.upcase if code.present?
    self.email = email&.strip&.downcase if email.present?
    self.phone = phone&.strip if phone.present?
    self.city = city&.strip&.titleize if city.present?
    self.state = state&.strip&.upcase if state.present?
    self.zip_code = zip_code&.strip if zip_code.present?
    self.country = country&.strip&.upcase if country.present?
  end
end
