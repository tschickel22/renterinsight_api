# frozen_string_literal: true

# == Schema Information
#
# Table name: manufacturer_ar_transactions
#
#  id                     :bigint           not null, primary key
#  company_id             :bigint           not null
#  location_id            :bigint
#  warranty_claim_id      :bigint           not null
#  manufacturer_id        :bigint           not null
#  transaction_number     :string           not null
#  original_claim_amount  :decimal(12, 2)   not null
#  amount_paid_to_date    :decimal(12, 2)   default(0.0)
#  amount_outstanding     :decimal(12, 2)   not null
#  status                 :string           default("open"), not null
#  claim_date             :date
#  expected_payment_date  :date
#  paid_in_full_date      :date
#  notes                  :text
#  write_off_reason       :text
#  is_deleted             :boolean          default(FALSE), not null
#  deleted_at             :datetime
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#

class ManufacturerArTransaction < ApplicationRecord
  include LocationAware
  
  STATUSES = %w[open partial paid short_paid written_off].freeze
  
  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :warranty_claim
  belongs_to :manufacturer
  has_many :manufacturer_ar_payments, dependent: :destroy
  
  # Validations
  validates :transaction_number, presence: true, uniqueness: { scope: :company_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :original_claim_amount, presence: true, numericality: { greater_than: 0 }
  validates :amount_paid_to_date, numericality: { greater_than_or_equal_to: 0 }
  validates :amount_outstanding, numericality: { greater_than_or_equal_to: 0 }
  
  # Scopes
  scope :active, -> { where(is_deleted: false) }
  scope :by_status, ->(status) { where(status: status) }
  scope :open, -> { where(status: 'open') }
  scope :partial, -> { where(status: 'partial') }
  scope :paid, -> { where(status: 'paid') }
  scope :outstanding, -> { where(status: ['open', 'partial']) }
  scope :by_manufacturer, ->(manufacturer_id) { where(manufacturer_id: manufacturer_id) }
  scope :overdue, -> { where('expected_payment_date < ? AND status IN (?)', Date.current, ['open', 'partial']) }
  scope :recent, -> { order(created_at: :desc) }
  
  # Callbacks
  before_validation :generate_transaction_number, on: :create
  before_validation :calculate_outstanding
  after_save :update_warranty_claim_status
  
  # Status Checks
  def open?
    status == 'open'
  end
  
  def partial?
    status == 'partial'
  end
  
  def paid?
    status == 'paid'
  end
  
  def short_paid?
    status == 'short_paid'
  end
  
  def written_off?
    status == 'written_off'
  end
  
  def overdue?
    expected_payment_date.present? && expected_payment_date < Date.current && outstanding?
  end
  
  def outstanding?
    ['open', 'partial'].include?(status)
  end
  
  def days_outstanding
    return 0 unless claim_date.present?
    (Date.current - claim_date).to_i
  end
  
  # Record Payment
  def record_payment!(amount:, payment_date:, payment_method:, reference_number: nil, notes: nil, recorded_by:)
    raise ArgumentError, 'Payment amount must be greater than 0' if amount <= 0
    raise ArgumentError, 'Cannot record payment on paid/written-off transaction' if paid? || written_off?
    
    # Create payment record
    payment = manufacturer_ar_payments.create!(
      company_id: company_id,
      amount: amount,
      payment_date: payment_date,
      payment_method: payment_method,
      reference_number: reference_number,
      notes: notes,
      recorded_by: recorded_by
    )
    
    # Update amounts
    self.amount_paid_to_date = manufacturer_ar_payments.sum(:amount)
    self.amount_outstanding = original_claim_amount - amount_paid_to_date
    
    # Update status
    if amount_outstanding <= 0
      self.status = 'paid'
      self.paid_in_full_date = payment_date
    elsif amount_paid_to_date > 0
      self.status = 'partial'
    end
    
    save!
    
    payment
  end
  
  # Short Pay (manufacturer pays less than approved amount)
  def mark_short_paid!(final_amount:, reason:, recorded_by:)
    raise ArgumentError, 'Cannot short-pay a paid/written-off transaction' if paid? || written_off?
    
    update!(
      status: 'short_paid',
      amount_paid_to_date: final_amount,
      amount_outstanding: 0,
      notes: [notes, "Short paid: #{reason}"].compact.join("\n\n"),
      paid_in_full_date: Date.current
    )
    
    # Update warranty claim
    warranty_claim.update!(
      approved_amount: final_amount,
      manufacturer_response: [warranty_claim.manufacturer_response, "Short paid: #{reason}"].compact.join("\n\n")
    )
  end
  
  # Write Off (manufacturer refuses to pay or bankrupt)
  def write_off!(reason:, written_off_by:)
    raise ArgumentError, 'Cannot write off a paid transaction' if paid?
    
    update!(
      status: 'written_off',
      write_off_reason: reason,
      amount_outstanding: 0,
      notes: [notes, "Written off by #{written_off_by}: #{reason}"].compact.join("\n\n")
    )
  end
  
  # Soft Delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Serialization
  def as_json(options = {})
    {
      id: id,
      companyId: company_id,
      locationId: location_id,
      warrantyClaimId: warranty_claim_id,
      manufacturerId: manufacturer_id,
      transactionNumber: transaction_number,
      originalClaimAmount: original_claim_amount,
      amountPaidToDate: amount_paid_to_date,
      amountOutstanding: amount_outstanding,
      status: status,
      claimDate: claim_date,
      expectedPaymentDate: expected_payment_date,
      paidInFullDate: paid_in_full_date,
      notes: notes,
      writeOffReason: write_off_reason,
      createdAt: created_at,
      updatedAt: updated_at,
      
      # Related data
      manufacturer: manufacturer ? {
        id: manufacturer.id,
        name: manufacturer.name
      } : nil,
      
      warrantyClaim: warranty_claim ? {
        id: warranty_claim.id,
        claimNumber: warranty_claim.claim_number,
        status: warranty_claim.status
      } : nil,
      
      # Calculated values
      daysOutstanding: days_outstanding,
      overdue: overdue?,
      paymentsCount: manufacturer_ar_payments.count,
      payments: options[:include_payments] ? manufacturer_ar_payments.map(&:as_json) : nil
    }
  end
  
  private
  
  def generate_transaction_number
    self.transaction_number ||= loop do
      number = "MAR-#{Time.current.year}-#{SecureRandom.hex(4).upcase}"
      break number unless self.class.exists?(company_id: company_id, transaction_number: number)
    end
  end
  
  def calculate_outstanding
    self.amount_outstanding = original_claim_amount - amount_paid_to_date if original_claim_amount.present?
  end
  
  def update_warranty_claim_status
    return unless warranty_claim.present?
    
    if paid? && warranty_claim.approved?
      warranty_claim.close!(nil)
    end
  end
end
