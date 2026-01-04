# frozen_string_literal: true

class CommissionPayment < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :deal
  belongs_to :payee_user, class_name: 'User'
  belongs_to :approved_by_user, class_name: 'User', optional: true
  belongs_to :paid_by_user, class_name: 'User', optional: true
  belongs_to :reversed_by_user, class_name: 'User', optional: true
  
  # Status values
  STATUSES = %w[
    pending
    approved
    paid
    reversed
    cancelled
  ].freeze
  
  # Payment methods
  PAYMENT_METHODS = %w[
    check
    direct_deposit
    cash
    wire_transfer
    payroll
  ].freeze
  
  # ============================================================================
  # VALIDATIONS
  # ============================================================================
  
  validates :payment_number, presence: true, uniqueness: { scope: :company_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_nil: true
  
  # Status transition validations
  validate :validate_status_transition, on: :update, if: -> { status_changed? }
  validate :validate_approval_fields, if: -> { status == 'approved' }
  validate :validate_payment_fields, if: -> { status == 'paid' }
  validate :validate_reversal_fields, if: -> { is_reversed? }
  
  # ============================================================================
  # CALLBACKS
  # ============================================================================
  
  before_validation :generate_payment_number, on: :create
  before_validation :set_location_from_deal, on: :create
  
  # ============================================================================
  # SCOPES
  # ============================================================================
  
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :pending, -> { where(status: 'pending') }
  scope :approved, -> { where(status: 'approved') }
  scope :paid, -> { where(status: 'paid') }
  scope :reversed, -> { where(is_reversed: true) }
  scope :not_reversed, -> { where(is_reversed: [false, nil]) }
  scope :for_payee, ->(user_id) { where(payee_user_id: user_id) }
  scope :for_location, ->(location_id) { where('location_id IS NULL OR location_id = ?', location_id) }
  scope :for_current_location, -> { Current.location_filtered? ? where(location_id: Current.location_id) : all }
  scope :ordered, -> { order(created_at: :desc) }
  
  # Date range scopes
  scope :approved_between, ->(start_date, end_date) {
    where('approved_at >= ? AND approved_at <= ?', start_date, end_date)
  }
  scope :paid_between, ->(start_date, end_date) {
    where('paid_at >= ? AND paid_at <= ?', start_date, end_date)
  }
  
  # ============================================================================
  # INSTANCE METHODS
  # ============================================================================
  
  # Approve the payment
  def approve!(approved_by:)
    return false if status != 'pending'
    
    update!(
      status: 'approved',
      approved_by_user: approved_by,
      approved_at: Time.current
    )
  end
  
  # Mark as paid
  def mark_paid!(paid_by:, payment_method:, payment_reference: nil)
    return false unless status == 'approved'
    
    update!(
      status: 'paid',
      paid_by_user: paid_by,
      paid_at: Time.current,
      payment_method: payment_method,
      payment_reference: payment_reference
    )
  end
  
  # Reverse the payment
  def reverse!(reversed_by:, reason:)
    return false unless can_reverse?
    
    update!(
      is_reversed: true,
      reversed_by_user: reversed_by,
      reversed_at: Time.current,
      reversal_reason: reason,
      status: 'reversed'
    )
  end
  
  # Cancel the payment (only if pending)
  def cancel!
    return false unless status == 'pending'
    
    update!(status: 'cancelled')
  end
  
  # Can this payment be reversed?
  def can_reverse?
    status.in?(%w[approved paid]) && !is_reversed?
  end
  
  # Can this payment be approved?
  def can_approve?
    status == 'pending' && !is_reversed?
  end
  
  # Can this payment be marked as paid?
  def can_mark_paid?
    status == 'approved' && !is_reversed?
  end
  
  # Display status with reversal indicator
  def display_status
    is_reversed? ? "#{status} (reversed)" : status
  end
  
  # Get calculation breakdown from details
  def line_items
    calculation_details['line_items'] || []
  end
  
  # Get deal economics from details
  def deal_economics
    calculation_details['deal_economics'] || {}
  end
  
  private
  
  # Generate unique payment number
  def generate_payment_number
    return if payment_number.present?
    
    # Format: CP-YYYYMM-XXXX (e.g., CP-202601-0001)
    prefix = "CP-#{Date.today.strftime('%Y%m')}"
    
    last_payment = company.commission_payments
      .where('payment_number LIKE ?', "#{prefix}-%")
      .order(payment_number: :desc)
      .first
    
    if last_payment && last_payment.payment_number =~ /#{prefix}-(\d+)/
      sequence = $1.to_i + 1
    else
      sequence = 1
    end
    
    self.payment_number = "#{prefix}-#{sequence.to_s.rjust(4, '0')}"
  end
  
  # Set location from deal
  def set_location_from_deal
    self.location_id ||= deal&.location_id
  end
  
  # Validate status transitions
  def validate_status_transition
    return if status_was.nil?  # New record
    
    valid_transitions = {
      'pending' => %w[approved cancelled],
      'approved' => %w[paid reversed],
      'paid' => %w[reversed],
      'reversed' => [],
      'cancelled' => []
    }
    
    allowed = valid_transitions[status_was] || []
    
    unless allowed.include?(status)
      errors.add(:status, "cannot transition from #{status_was} to #{status}")
    end
  end
  
  # Validate approval fields are present
  def validate_approval_fields
    if approved_by_user_id.nil? || approved_at.nil?
      errors.add(:base, 'Approved by and approved at must be set when approving')
    end
  end
  
  # Validate payment fields are present
  def validate_payment_fields
    errors.add(:payment_method, 'is required when marking as paid') if payment_method.nil?
    errors.add(:paid_by_user_id, 'is required when marking as paid') if paid_by_user_id.nil?
    errors.add(:paid_at, 'is required when marking as paid') if paid_at.nil?
  end
  
  # Validate reversal fields
  def validate_reversal_fields
    if reversed_by_user_id.nil? || reversed_at.nil? || reversal_reason.blank?
      errors.add(:base, 'Reversal requires user, timestamp, and reason')
    end
  end
end
