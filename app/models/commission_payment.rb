# frozen_string_literal: true

class CommissionPayment < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :deal
  belongs_to :payee_user, class_name: 'User'
  belongs_to :commission_plan, optional: true
  belongs_to :approved_by_user, class_name: 'User', optional: true
  belongs_to :paid_by_user, class_name: 'User', optional: true
  belongs_to :reversed_by_user, class_name: 'User', optional: true
  
  has_many :commission_payment_line_items, dependent: :destroy
  
  # Status values
  STATUSES = %w[
    pending
    approved
    paid
    partially_paid
    reversed
    cancelled
  ].freeze
  
  # Payment methods
  PAYMENT_METHODS = %w[
    check
    ach
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
  validate :validate_payment_fields, if: -> { status.in?(%w[paid partially_paid]) }
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
  scope :partially_paid, -> { where(status: 'partially_paid') }
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
  
  # Mark as paid (full or partial)
  def mark_paid!(paid_by:, payment_method:, payment_reference: nil, amount_paid: nil, paid_date: nil)
    return false unless status == 'approved'
    
    # Default to full payment if amount not specified
    actual_amount_paid = amount_paid || self.amount
    remaining = self.amount - actual_amount_paid
    
    # Determine status based on whether it's a full or partial payment
    new_status = remaining > 0.01 ? 'partially_paid' : 'paid'  # Use 0.01 for floating point comparison
    
    update!(
      status: new_status,
      amount_paid: actual_amount_paid,
      remaining_balance: remaining,
      paid_by_user: paid_by,
      paid_at: Time.current,
      paid_date: paid_date || Date.today,
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
  
  # Undo reversal - restore payment to previous state
  def undo_reversal!
    return false unless can_undo_reversal?
    
    # Restore to paid/partially_paid status based on amount_paid
    restored_status = if amount_paid.present?
      remaining = amount - amount_paid
      remaining > 0.01 ? 'partially_paid' : 'paid'
    else
      'approved'
    end
    
    update!(
      is_reversed: false,
      reversed_by_user_id: nil,
      reversed_at: nil,
      reversal_reason: nil,
      status: restored_status
    )
  end
  
  # Cancel the payment (only if pending)
  def cancel!
    return false unless status == 'pending'
    
    update!(status: 'cancelled')
  end
  
  # Can this payment be reversed?
  def can_reverse?
    status.in?(%w[approved paid partially_paid]) && !is_reversed?
  end
  
  # Can this payment be approved?
  def can_approve?
    status == 'pending' && !is_reversed?
  end
  
  # Can this payment be marked as paid?
  def can_mark_paid?
    status == 'approved' && !is_reversed?
  end
  
  # Can this reversal be undone?
  def can_undo_reversal?
    is_reversed?
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
      'approved' => %w[paid partially_paid reversed],
      'paid' => %w[reversed],
      'partially_paid' => %w[paid reversed],  # Can go from partial to full paid or reversed
      'reversed' => %w[approved paid partially_paid],  # Undo reversal - restore to previous state
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
    errors.add(:amount_paid, 'is required when marking as paid') if amount_paid.nil?
    errors.add(:paid_date, 'is required when marking as paid') if paid_date.nil?
  end
  
  # Validate reversal fields
  def validate_reversal_fields
    if reversed_by_user_id.nil? || reversed_at.nil? || reversal_reason.blank?
      errors.add(:base, 'Reversal requires user, timestamp, and reason')
    end
  end
end
