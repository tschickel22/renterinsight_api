# frozen_string_literal: true

# PaymentMethod Model
# 
# Represents a payment method (ACH, debit card, credit card, or cash) that can be used
# for processing payments. Supports encryption of sensitive data and integration with
# external payment gateways like Zego and Stripe.

class PaymentMethod < ApplicationRecord
  include LocationAware
  
  # Constants
  METHOD_TYPES = %w[ach debit_card credit_card cash].freeze
  CARD_BRANDS = %w[Visa MasterCard Amex Discover].freeze
  ACH_ACCOUNT_TYPES = %w[checking savings].freeze
  API_PARTNERS = {
    zego: 2,
    stripe: 3,
    manual: 1
  }.freeze
  
  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :owner, polymorphic: true # Contact, Lead, etc.
  has_many :payments, dependent: :restrict_with_error
  has_many :loans, foreign_key: :default_payment_method_id, dependent: :nullify
  
  # Validations
  validates :method_type, presence: true, inclusion: { in: METHOD_TYPES }
  validates :company_id, presence: true
  validates :owner_id, presence: true
  validates :owner_type, presence: true
  
  # ACH-specific validations
  with_options if: :ach? do
    validates :ach_account_type, presence: true, inclusion: { in: ACH_ACCOUNT_TYPES }
    validates :ach_routing_number_encrypted, presence: true
    validates :ach_account_number_encrypted, presence: true
    validates :ach_last_4, presence: true
  end
  
  # Card-specific validations
  with_options if: :card? do
    validates :credit_card_last_4, presence: true
    validates :credit_card_brand, presence: true, inclusion: { in: CARD_BRANDS }
    validates :credit_card_exp_month, presence: true, 
              numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 12 }
    validates :credit_card_exp_year, presence: true,
              numericality: { only_integer: true, greater_than_or_equal_to: -> { Date.current.year } }
  end
  
  # Billing address validations
  validates :billing_first_name, :billing_last_name, presence: true
  
  # Scopes
  scope :active, -> { where(is_active: true, is_deleted: false) }
  scope :verified, -> { where(is_verified: true) }
  scope :for_owner, ->(owner) { where(owner: owner) }
  scope :by_type, ->(type) { where(method_type: type) }
  scope :default_methods, -> { where(is_default: true) }
  scope :ach_methods, -> { where(method_type: 'ach') }
  scope :card_methods, -> { where(method_type: %w[debit_card credit_card]) }
  scope :cash_methods, -> { where(method_type: 'cash') }
  
  # Callbacks
  before_validation :ensure_single_default, if: :is_default?
  before_validation :normalize_method_type
  after_initialize :set_defaults, if: :new_record?
  
  # Instance methods
  def ach?
    method_type == 'ach'
  end
  
  def card?
    %w[debit_card credit_card].include?(method_type)
  end
  
  def debit_card?
    method_type == 'debit_card'
  end
  
  def credit_card?
    method_type == 'credit_card'
  end
  
  def cash?
    method_type == 'cash'
  end
  
  # Alias for method_type (for compatibility with Zego API)
  def payment_type
    method_type
  end
  
  def display_name
    return nickname if nickname.present?
    
    case method_type
    when 'ach'
      "#{ach_account_type&.titleize} •••• #{ach_last_4}"
    when 'debit_card', 'credit_card'
      "#{credit_card_brand} •••• #{credit_card_last_4}"
    when 'cash'
      "Cash Payment"
    else
      "Payment Method"
    end
  end
  
  def display_type
    case method_type
    when 'ach' then 'Bank Account (ACH)'
    when 'debit_card' then 'Debit Card'
    when 'credit_card' then 'Credit Card'
    when 'cash' then 'Cash'
    else method_type.titleize
    end
  end
  
  def expired?
    return false unless card?
    return false unless credit_card_exp_month && credit_card_exp_year
    
    exp_date = Date.new(credit_card_exp_year, credit_card_exp_month, -1)
    exp_date < Date.current
  end
  
  def expiring_soon?(months = 2)
    return false unless card?
    return false unless credit_card_exp_month && credit_card_exp_year
    
    exp_date = Date.new(credit_card_exp_year, credit_card_exp_month, -1)
    exp_date < months.months.from_now && exp_date >= Date.current
  end
  
  def full_billing_address
    [
      billing_street,
      billing_city,
      [billing_state, billing_zip].compact.join(' ')
    ].compact.join(', ')
  end
  
  # Generate unique reference ID for payment gateway
  def generate_reference_id
    "#{owner_type.underscore}_#{owner_id}_#{id || SecureRandom.hex(4)}"
  end
  
  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current, is_active: false)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil, is_active: true)
  end
  
  # Mark as verified (after successful test transaction or verification)
  def verify!
    update!(is_verified: true, verified_at: Time.current)
  end
  
  # Returns masked account/card number for display
  def masked_account_number
    case method_type
    when 'ach'
      "•••• #{ach_last_4}"
    when 'debit_card', 'credit_card'
      "•••• #{credit_card_last_4}"
    when 'cash'
      cash_card_number.present? ? "•••• #{cash_card_number[-4..-1]}" : "N/A"
    else
      "N/A"
    end
  end
  
  # Returns expiration date for credit cards
  def credit_card_expires_on
    return nil unless card? && credit_card_exp_month && credit_card_exp_year
    Date.new(credit_card_exp_year, credit_card_exp_month, -1) # Last day of expiration month
  end
  
  # Alias for expired? to match JSON method name
  def is_expired
    expired?
  end
  
  # Check if payment method is verified
  def is_verified?
    is_verified == true
  end
  
  # Virtual accessor methods for sensitive data
  # These decrypt the encrypted fields for use in API calls
  # TODO: Implement actual encryption/decryption once Rails encrypted attributes are set up
  
  def ach_routing_number
    ach_routing_number_encrypted # Placeholder - will decrypt once encryption is implemented
  end
  
  def ach_routing_number=(value)
    self.ach_routing_number_encrypted = value # Placeholder - will encrypt once encryption is implemented
    self.ach_last_4 = value[-4..-1] if value.present?
  end
  
  def ach_account_number
    ach_account_number_encrypted # Placeholder - will decrypt once encryption is implemented
  end
  
  def ach_account_number=(value)
    self.ach_account_number_encrypted = value # Placeholder - will encrypt once encryption is implemented
    self.ach_last_4 ||= value[-4..-1] if value.present?
  end
  
  def credit_card_number
    credit_card_number_encrypted # Placeholder - will decrypt once encryption is implemented
  end
  
  def credit_card_number=(value)
    self.credit_card_number_encrypted = value # Placeholder - will encrypt once encryption is implemented
    if value.present?
      self.credit_card_last_4 = value[-4..-1]
      # Auto-detect card brand from card number
      self.credit_card_brand = detect_card_brand(value) if credit_card_brand.blank?
    end
  end
  
  def credit_card_cvv
    credit_card_cvv_encrypted # Placeholder - will decrypt once encryption is implemented
  end
  
  def credit_card_cvv=(value)
    self.credit_card_cvv_encrypted = value # Placeholder - will encrypt once encryption is implemented
  end
  
  private
  
  # Detect card brand from card number
  def detect_card_brand(number)
    return nil if number.blank?
    
    case number[0]
    when '4' then 'Visa'
    when '5', '2' then 'MasterCard'
    when '3' then 'Amex'
    when '6' then 'Discover'
    else 'Visa' # Default fallback
    end
  end
  
  def set_defaults
    self.billing_country ||= 'US'
    self.is_active = true if is_active.nil?
    self.is_deleted = false if is_deleted.nil?
  end
  
  def normalize_method_type
    self.method_type = method_type&.downcase&.strip
  end
  
  def ensure_single_default
    return unless is_default? && owner.present?
    
    PaymentMethod.where(owner: owner, is_default: true)
                  .where.not(id: id)
                  .update_all(is_default: false)
  end
end
