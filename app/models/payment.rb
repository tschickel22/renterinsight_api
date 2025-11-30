# frozen_string_literal: true

# Payment Model
# 
# Represents a payment transaction, either standalone or associated with a loan.
# Integrates with external payment gateways (Zego, Stripe) and tracks processing fees.

class Payment < ApplicationRecord
  include LocationAware
  
  # Constants
  STATUSES = %w[pending processing completed failed refunded cancelled voided].freeze
  PAYMENT_TYPES = %w[loan_payment one_time deposit fee screening_fee application_fee].freeze
  FEE_RESPONSIBILITIES = %w[customer company].freeze
  FEE_TYPES = %w[percentage fixed percentage_plus_fixed].freeze
  GATEWAY_NAMES = %w[zego stripe manual].freeze
  
  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :loan, optional: true
  belongs_to :payment_method, optional: true
  belongs_to :payer, polymorphic: true, optional: true
  belongs_to :payable, polymorphic: true, optional: true
  
  # Validations
  validates :company_id, presence: true
  validates :payment_number, presence: true, uniqueness: { scope: :company_id }
  validates :payment_type, presence: true, inclusion: { in: PAYMENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_method_id, presence: true, unless: :manual_payment?
  validates :fee_responsibility, inclusion: { in: FEE_RESPONSIBILITIES }, allow_nil: true
  validates :fee_type, inclusion: { in: FEE_TYPES }, allow_nil: true
  validates :gateway_name, inclusion: { in: GATEWAY_NAMES }, allow_nil: true
  
  # Scopes
  scope :completed, -> { where(status: 'completed') }
  scope :pending, -> { where(status: 'pending') }
  scope :processing, -> { where(status: 'processing') }
  scope :failed, -> { where(status: 'failed') }
  scope :refunded, -> { where(status: 'refunded') }
  scope :for_loan, ->(loan) { where(loan: loan) }
  scope :for_payer, ->(payer) { where(payer: payer) }
  scope :by_type, ->(type) { where(payment_type: type) }
  scope :by_status, ->(status) { where(status: status) }
  scope :by_gateway, ->(gateway) { where(gateway_name: gateway) }
  scope :scheduled, -> { where(status: 'pending').where('scheduled_at IS NOT NULL') }
  scope :due_today, -> { scheduled.where('DATE(scheduled_at) = ?', Date.current) }
  scope :overdue, -> { scheduled.where('scheduled_at < ?', Time.current) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_date, ->(start_date, end_date) { where(payment_date: start_date..end_date) }
  
  # Callbacks
  before_validation :generate_payment_number, on: :create
  before_validation :calculate_total_charged
  before_validation :set_payment_date, if: -> { payment_date.nil? && status == 'completed' }
  after_initialize :set_defaults, if: :new_record?
  after_commit :update_loan_after_completion, if: -> { saved_change_to_status? && status == 'completed' }
  
  # Instance methods
  def display_name
    "Payment ##{payment_number}"
  end
  
  def payer_name
    return 'No Payer' if payer.nil?
    
    if payer.respond_to?(:full_name)
      payer.full_name
    elsif payer.respond_to?(:name)
      payer.name
    else
      "Payer ##{payer_id}"
    end
  end
  
  def completed?
    status == 'completed'
  end
  
  def pending?
    status == 'pending'
  end
  
  def failed?
    status == 'failed'
  end
  
  def refunded?
    status == 'refunded'
  end
  
  def processing?
    status == 'processing'
  end
  
  def can_refund?
    completed? && !refunded? && external_id.present?
  end
  
  def can_void?
    (pending? || processing?) && external_id.present?
  end
  
  def total_amount
    total_charged || amount
  end
  
  def customer_pays_fee?
    fee_responsibility == 'customer'
  end
  
  def company_pays_fee?
    fee_responsibility == 'company'
  end
  
  def has_processing_fee?
    processing_fee.to_f > 0
  end
  
  # Mark as completed
  def mark_completed!(external_id: nil, processed_time: Time.current)
    update!(
      status: 'completed',
      processed_at: processed_time,
      payment_date: processed_time.to_date,
      external_id: external_id || self.external_id
    )
  end
  
  # Mark as failed
  def mark_failed!(reason)
    update!(
      status: 'failed',
      failure_reason: reason,
      processed_at: Time.current
    )
  end
  
  # Process refund
  def process_refund!(amount: nil, reason: nil)
    return false unless can_refund?
    
    refund_amt = amount || self.amount
    
    transaction do
      update!(
        status: 'refunded',
        is_refunded: true,
        refund_amount: refund_amt,
        refunded_at: Time.current,
        refund_reason: reason
      )
      
      # If this was a loan payment, reverse the loan state
      if loan.present? && loan.active?
        loan.update!(
          total_paid: [loan.total_paid - principal_amount.to_f, 0].max,
          current_balance: loan.current_balance + principal_amount.to_f,
          payments_made: [loan.payments_made - 1, 0].max
        )
      end
    end
    
    true
  rescue => e
    Rails.logger.error("Error processing refund for payment #{id}: #{e.message}")
    false
  end
  
  # Void payment
  def void!
    return false unless can_void?
    
    update!(status: 'voided')
  end
  
  # Cancel scheduled payment
  def cancel!
    return false unless pending?
    
    update!(status: 'cancelled')
  end
  
  # Payment breakdown for display
  def breakdown
    {
      principal: principal_amount || 0,
      interest: interest_amount || 0,
      fees: fee_amount || 0,
      late_fees: late_fee_amount || 0,
      processing_fee: processing_fee || 0,
      total: total_charged || amount
    }
  end
  
  def fee_description
    return 'No fee' unless has_processing_fee?
    
    case fee_type
    when 'percentage'
      "#{fee_value}%"
    when 'fixed'
      "$#{fee_value}"
    when 'percentage_plus_fixed'
      "#{fee_value}% + fixed"
    else
      'Processing fee'
    end
  end
  
  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  def manual_payment?
    gateway_name == 'manual' || payment_method_id.nil?
  end
  
  private
  
  def set_defaults
    self.status ||= 'pending'
    self.payment_type ||= 'one_time'
    self.principal_amount ||= 0
    self.interest_amount ||= 0
    self.fee_amount ||= 0
    self.late_fee_amount ||= 0
    self.processing_fee ||= 0
    self.is_refunded = false if is_refunded.nil?
    self.is_deleted = false if is_deleted.nil?
    self.payment_date ||= Date.current if status == 'completed'
  end
  
  def generate_payment_number
    return if payment_number.present?
    
    timestamp = Time.current.strftime('%Y%m%d')
    random = SecureRandom.hex(3).upcase
    self.payment_number = "PAY-#{timestamp}-#{random}"
  end
  
  def calculate_total_charged
    return if amount.nil?
    
    if customer_pays_fee? && processing_fee.to_f > 0
      self.total_charged = amount + processing_fee
    else
      self.total_charged = amount
    end
  end
  
  def set_payment_date
    self.payment_date = Date.current
  end
  
  def update_loan_after_completion
    return unless loan.present?
    
    loan.process_payment!(self)
  end
end
