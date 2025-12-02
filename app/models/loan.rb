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
  
  # Generate amortization schedule with actual payment data
  # Returns hash with :schedule array and :summary object
  def generate_amortization_schedule_with_actuals
    return { schedule: [], summary: {} } unless valid_for_amortization?
    
    # Get completed payments ordered by payment date
    completed_payments = payments.where(status: 'completed').order(:payment_date, :id)
    
    # Basic loan parameters
    principal = BigDecimal(principal_amount.to_s)
    monthly_rate = BigDecimal((interest_rate / 100.0 / 12.0).to_s)
    monthly_payment = BigDecimal(regular_payment_amount.to_s)
    
    # Initialize tracking variables
    schedule = []
    current_balance = principal
    current_date = first_payment_date || origination_date
    total_actual_paid = BigDecimal('0')
    total_principal_paid = BigDecimal('0')
    total_interest_paid = BigDecimal('0')
    total_unpaid_interest = BigDecimal('0')
    
    # Track payments by period
    payment_index = 0
    
    # Generate schedule for each payment period
    (1..term_months).each do |payment_number|
      # Calculate scheduled interest and principal
      scheduled_interest = current_balance * monthly_rate
      scheduled_principal = monthly_payment - scheduled_interest
      scheduled_principal = current_balance if scheduled_principal > current_balance
      
      # Collect actual payments for this period
      period_payments = []
      while payment_index < completed_payments.length
        payment = completed_payments[payment_index]
        # Check if payment belongs to this period (within 15 days of due date)
        if payment.payment_date.present?
          payment_date = payment.payment_date.to_date
          period_start = current_date.to_date - 15.days
          period_end = current_date.to_date + 15.days
          
          if payment_date >= period_start && payment_date <= period_end
            period_payments << payment
            payment_index += 1
          else
            break
          end
        else
          payment_index += 1
        end
      end
      
      # Calculate actual payment total for this period
      actual_payment_total = period_payments.sum { |p| BigDecimal(p.amount.to_s) }
      
      # Calculate interest due on current balance
      interest_due = current_balance * monthly_rate
      
      # Apply actual payments: interest first, then principal
      if actual_payment_total >= interest_due
        # Payment covers all interest
        actual_interest = interest_due
        actual_principal = actual_payment_total - interest_due
        unpaid_interest_this_period = BigDecimal('0')
        
        # Don't reduce balance below zero
        actual_principal = current_balance if actual_principal > current_balance
        
        # Reduce balance by actual principal paid
        current_balance -= actual_principal
      else
        # Partial payment - doesn't cover full interest
        actual_interest = actual_payment_total
        actual_principal = BigDecimal('0')
        unpaid_interest_this_period = interest_due - actual_payment_total
        # Balance stays the same
      end
      
      # Determine status
      status = if period_payments.any?
        'Paid'
      elsif payment_number == payments_made + 1
        'Current'
      else
        'Upcoming'
      end
      
      # Add to schedule
      schedule << {
        payment_number: payment_number,
        due_date: current_date.to_date,
        scheduled_payment: monthly_payment.to_f.round(2),
        actual_payment: actual_payment_total.to_f.round(2),
        scheduled_principal: scheduled_principal.to_f.round(2),
        scheduled_interest: scheduled_interest.to_f.round(2),
        actual_principal: actual_principal.to_f.round(2),
        actual_interest: actual_interest.to_f.round(2),
        unpaid_interest_this_period: unpaid_interest_this_period.to_f.round(2),
        balance: current_balance.to_f.round(2),
        status: status,
        payment_ids: period_payments.map(&:id)
      }
      
      # Update totals
      total_actual_paid += actual_payment_total
      total_principal_paid += actual_principal
      total_interest_paid += actual_interest
      total_unpaid_interest += unpaid_interest_this_period
      
      # Move to next month
      current_date = current_date + 1.month
      
      # Stop if loan is paid off
      break if current_balance <= BigDecimal('0.01')
    end
    
    # Calculate summary
    summary = {
      original_principal: principal.to_f.round(2),
      interest_rate: interest_rate.to_f,
      term_months: term_months,
      monthly_payment: monthly_payment.to_f.round(2),
      total_scheduled_interest: (schedule.sum { |s| s[:scheduled_interest] }).round(2),
      total_actual_paid: total_actual_paid.to_f.round(2),
      total_principal_paid: total_principal_paid.to_f.round(2),
      total_interest_paid: total_interest_paid.to_f.round(2),
      total_unpaid_interest: total_unpaid_interest.to_f.round(2),
      remaining_balance: current_balance.to_f.round(2),
      scheduled_maturity: maturity_date&.to_date,
      projected_maturity: calculate_projected_maturity(current_balance, monthly_rate, monthly_payment),
      payments_made: completed_payments.count,
      payments_remaining: [term_months - completed_payments.count, 0].max
    }
    
    {
      schedule: schedule,
      summary: summary
    }
  end
  
  # Calculate new maturity date when extra principal is paid
  def recalculate_maturity_with_extra_principal(extra_principal_amount = 0)
    return maturity_date unless extra_principal_amount > 0
    
    # Calculate remaining balance after extra payment
    new_balance = [current_balance - extra_principal_amount, 0].max
    return nil if new_balance <= 0 # Loan would be paid off
    
    monthly_rate = interest_rate / 100.0 / 12.0
    monthly_payment = regular_payment_amount.to_f
    
    # Handle zero interest case
    if monthly_rate == 0
      months_remaining = (new_balance / monthly_payment).ceil
      return next_payment_date + (months_remaining - 1).months
    end
    
    # Check if payment even covers interest
    monthly_interest = new_balance * monthly_rate
    return maturity_date if monthly_payment <= monthly_interest # Payment doesn't cover interest
    
    # Calculate months remaining using amortization formula
    # n = -ln(1 - (r * P / PMT)) / ln(1 + r)
    # Where: n = months, r = monthly rate, P = remaining balance, PMT = payment
    numerator = -Math.log(1 - (monthly_rate * new_balance / monthly_payment))
    denominator = Math.log(1 + monthly_rate)
    months_remaining = (numerator / denominator).ceil
    
    # Calculate new maturity date from next payment date
    next_payment_date + (months_remaining - 1).months
  end
  
  private
  
  def valid_for_amortization?
    principal_amount.present? &&
      principal_amount > 0 &&
      term_months.present? &&
      term_months > 0 &&
      regular_payment_amount.present? &&
      regular_payment_amount > 0 &&
      interest_rate.present? &&
      (first_payment_date.present? || origination_date.present?)
  end
  
  def calculate_projected_maturity(remaining_balance, monthly_rate, monthly_payment)
    return maturity_date if remaining_balance <= 0
    return maturity_date if monthly_rate == 0
    
    monthly_interest = remaining_balance * monthly_rate.to_f
    return maturity_date if monthly_payment.to_f <= monthly_interest
    
    numerator = -Math.log(1 - (monthly_rate.to_f * remaining_balance.to_f / monthly_payment.to_f))
    denominator = Math.log(1 + monthly_rate.to_f)
    months_remaining = (numerator / denominator).ceil
    
    base_date = next_payment_date || Date.current
    (base_date + (months_remaining - 1).months).to_date
  rescue => e
    Rails.logger.error "Error calculating projected maturity: #{e.message}"
    maturity_date
  end
  
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
