# frozen_string_literal: true

# Loan Model
# 
# Represents a loan or financing agreement with a borrower. Tracks payment schedules,
# current balances, and integrates with the payment system for automated collections.

class Loan < ApplicationRecord
  include LocationAware
  
  # Constants
  STATUSES = %w[pending active paid_off defaulted cancelled].freeze
  LOAN_TYPES = %w[conventional personal financing lease_to_own].freeze
  PAYMENT_FREQUENCIES = %w[weekly bi_weekly monthly].freeze
  
  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :borrower, polymorphic: true
  belongs_to :financed_entity, polymorphic: true, optional: true
  belongs_to :default_payment_method, class_name: 'PaymentMethod', optional: true
  has_many :payments, dependent: :restrict_with_error
  has_many :documents, as: :owner, class_name: 'PortalDocument', dependent: :destroy
  
  # Validations
  validates :company_id, presence: true
  validates :loan_number, presence: true, uniqueness: { scope: :company_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :principal_amount, presence: true, numericality: { greater_than: 0 }
  validates :origination_date, presence: true
  validates :payment_frequency, inclusion: { in: PAYMENT_FREQUENCIES }, allow_nil: true
  validates :interest_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :term_months, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  
  # Scopes
  scope :active, -> { where(status: 'active', is_deleted: false) }
  scope :pending, -> { where(status: 'pending') }
  scope :paid_off, -> { where(status: 'paid_off') }
  scope :defaulted, -> { where(status: 'defaulted') }
  scope :past_due, -> { active.where('days_past_due > 0') }
  scope :auto_pay, -> { where(auto_pay_enabled: true) }
  scope :for_borrower, ->(borrower) { where(borrower: borrower) }
  scope :by_status, ->(status) { where(status: status) }
  scope :payments_due, -> { active.where('next_payment_date <= ?', Date.current) }
  scope :expiring_soon, ->(days = 30) { active.where('maturity_date <= ?', days.days.from_now) }
  
  # Search scope - searches loan_number and borrower name
  scope :search, ->(query) {
    return all if query.blank?
    
    query = query.to_s.downcase.strip
    
    # Search by loan_number directly
    loan_number_match = where('LOWER(loan_number) LIKE ?', "%#{query}%")
    
    # Find matching Contact IDs by name
    contact_ids = Contact.where(
      'LOWER(first_name) LIKE ? OR LOWER(last_name) LIKE ?',
      "%#{query}%", "%#{query}%"
    ).pluck(:id)
    
    # Find matching Account IDs by name
    account_ids = Account.where('LOWER(name) LIKE ?', "%#{query}%").pluck(:id)
    
    # Build conditions for borrower matches
    if contact_ids.any? || account_ids.any?
      conditions = ['LOWER(loan_number) LIKE ?']
      values = ["%#{query}%"]
      
      if contact_ids.any?
        conditions << "(borrower_type = 'Contact' AND borrower_id IN (?))"
        values << contact_ids
      end
      
      if account_ids.any?
        conditions << "(borrower_type = 'Account' AND borrower_id IN (?))"
        values << account_ids
      end
      
      where(conditions.join(' OR '), *values)
    else
      loan_number_match
    end
  }
  
  # Callbacks
  before_validation :generate_loan_number, on: :create
  before_validation :calculate_maturity_date, if: :term_months_changed?
  before_validation :calculate_first_payment_date, if: :new_record?
  before_validation :set_initial_balance, if: :new_record?
  after_initialize :set_defaults, if: :new_record?
  
  # Instance methods
  def display_name
    "Loan ##{loan_number}"
  end
  
  def borrower_name
    if borrower.respond_to?(:full_name)
      borrower.full_name
    elsif borrower.respond_to?(:name)
      borrower.name
    else
      "Borrower ##{borrower_id}"
    end
  end
  
  def active?
    status == 'active' && !is_deleted?
  end
  
  def past_due?
    active? && days_past_due.to_i > 0
  end
  
  def current?
    active? && days_past_due.to_i == 0
  end
  
  def paid_off?
    status == 'paid_off' || current_balance.to_f <= 0
  end
  
  def payment_progress_percentage
    return 100 if paid_off?
    return 0 if principal_amount.to_f == 0
    
    ((total_paid.to_f / principal_amount.to_f) * 100).round(2)
  end
  
  def remaining_balance
    current_balance.to_f
  end
  
  def total_amount_due
    principal_amount.to_f + calculate_total_interest
  end
  
  # Calculate monthly payment using standard amortization formula
  # PMT = P * [r(1 + r)^n] / [(1 + r)^n - 1]
  def calculate_monthly_payment
    return 0 if principal_amount.to_f == 0 || term_months.to_i == 0
    
    if interest_rate.to_f == 0
      # No interest - simple division
      principal_amount.to_f / term_months.to_f
    else
      # Monthly interest rate
      r = (interest_rate.to_f / 100) / 12
      n = term_months.to_i
      
      # Amortization formula
      (principal_amount.to_f * (r * (1 + r)**n)) / ((1 + r)**n - 1)
    end
  end
  
  def calculate_total_interest
    return 0 if regular_payment_amount.to_f == 0 || term_months.to_i == 0
    
    (regular_payment_amount.to_f * term_months.to_i) - principal_amount.to_f
  end
  
  def days_until_next_payment
    return nil unless next_payment_date
    (next_payment_date - Date.current).to_i
  end
  
  def update_days_past_due!
    return unless active? && next_payment_date
    
    if next_payment_date < Date.current
      days_past = (Date.current - next_payment_date).to_i
      update!(days_past_due: days_past)
    else
      update!(days_past_due: 0)
    end
  end
  
  # Process a payment and update loan state
  def process_payment!(payment)
    return false unless payment.status == 'completed'
    
    transaction do
      # Update totals
      increment!(:payments_made)
      self.total_paid = (total_paid || 0) + payment.principal_amount.to_f
      self.total_interest_paid = (total_interest_paid || 0) + payment.interest_amount.to_f
      self.current_balance = principal_amount.to_f - total_paid.to_f
      self.last_payment_date = payment.payment_date
      
      # Calculate next payment date
      self.next_payment_date = calculate_next_payment_date
      
      # Update remaining payments
      self.payments_remaining = term_months.to_i - payments_made if term_months.present?
      
      # Reset days past due if payment brings us current
      self.days_past_due = 0 if current_balance > 0 && next_payment_date > Date.current
      
      # Mark as paid off if balance is zero or negative
      if current_balance <= 0
        self.status = 'paid_off'
        self.next_payment_date = nil
        self.payments_remaining = 0
        self.current_balance = 0
      end
      
      save!
    end
    
    true
  rescue => e
    Rails.logger.error("Error processing payment for loan #{id}: #{e.message}")
    false
  end
  
  def calculate_next_payment_date
    return nil unless last_payment_date && payment_frequency
    
    case payment_frequency
    when 'weekly'
      last_payment_date + 1.week
    when 'bi_weekly'
      last_payment_date + 2.weeks
    when 'monthly'
      last_payment_date + 1.month
    else
      last_payment_date + 1.month
    end
  end
  
  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current, status: 'cancelled')
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil, status: 'active')
  end
  
  # Activate loan
  def activate!
    update!(status: 'active')
  end
  
  def mark_defaulted!
    update!(status: 'defaulted')
  end
  
  private
  
  def set_defaults
    self.status ||= 'pending'
    self.payment_frequency ||= 'monthly'
    self.current_balance ||= 0
    self.total_paid ||= 0
    self.total_interest_paid ||= 0
    self.payments_made ||= 0
    self.days_past_due ||= 0
    self.late_fees_assessed ||= 0
    self.is_deleted = false if is_deleted.nil?
  end
  
  def generate_loan_number
    return if loan_number.present?
    
    timestamp = Time.current.strftime('%Y%m%d')
    random = SecureRandom.hex(3).upcase
    self.loan_number = "LN-#{timestamp}-#{random}"
  end
  
  def calculate_maturity_date
    return unless origination_date && term_months
    
    self.maturity_date = origination_date + term_months.months
  end
  
  def calculate_first_payment_date
    return if first_payment_date.present?
    return unless origination_date
    
    case payment_frequency
    when 'weekly'
      self.first_payment_date = origination_date + 1.week
    when 'bi_weekly'
      self.first_payment_date = origination_date + 2.weeks
    else # monthly
      self.first_payment_date = origination_date + 1.month
    end
    
    self.next_payment_date ||= first_payment_date
  end
  
  def set_initial_balance
    self.current_balance = principal_amount if current_balance.nil? || current_balance == 0
    self.payments_remaining = term_months if term_months.present?
  end
end
