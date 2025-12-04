# frozen_string_literal: true

# == Schema Information
#
# Table name: manufacturer_ar_payments
#
#  id                               :bigint           not null, primary key
#  company_id                       :bigint           not null
#  manufacturer_ar_transaction_id   :bigint           not null
#  payment_number                   :string           not null
#  amount                           :decimal(12, 2)   not null
#  payment_date                     :date             not null
#  payment_method                   :string
#  reference_number                 :string
#  notes                            :text
#  recorded_by                      :string
#  created_at                       :datetime         not null
#  updated_at                       :datetime         not null
#

class ManufacturerArPayment < ApplicationRecord
  PAYMENT_METHODS = %w[check wire ach credit_card other].freeze
  
  # Associations
  belongs_to :company
  belongs_to :manufacturer_ar_transaction
  
  # Active Storage for attachments (check images, remittance advice)
  has_many_attached :attachments
  
  # Validations
  validates :payment_number, presence: true, uniqueness: { scope: :company_id }
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_date, presence: true
  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_blank: true
  
  # Scopes
  scope :recent, -> { order(payment_date: :desc, created_at: :desc) }
  scope :by_method, ->(method) { where(payment_method: method) }
  scope :by_date_range, ->(start_date, end_date) { where(payment_date: start_date..end_date) }
  scope :for_manufacturer, ->(manufacturer_id) do
    joins(:manufacturer_ar_transaction).where(manufacturer_ar_transactions: { manufacturer_id: manufacturer_id })
  end
  
  # Callbacks
  before_validation :generate_payment_number, on: :create
  
  # Instance Methods
  def manufacturer
    manufacturer_ar_transaction.manufacturer
  end
  
  def warranty_claim
    manufacturer_ar_transaction.warranty_claim
  end
  
  # Serialization
  def as_json(options = {})
    {
      id: id,
      companyId: company_id,
      manufacturerArTransactionId: manufacturer_ar_transaction_id,
      paymentNumber: payment_number,
      amount: amount,
      paymentDate: payment_date,
      paymentMethod: payment_method,
      referenceNumber: reference_number,
      notes: notes,
      recordedBy: recorded_by,
      createdAt: created_at,
      updatedAt: updated_at,
      
      # Related data
      transaction: manufacturer_ar_transaction ? {
        id: manufacturer_ar_transaction.id,
        transactionNumber: manufacturer_ar_transaction.transaction_number,
        originalClaimAmount: manufacturer_ar_transaction.original_claim_amount
      } : nil,
      
      # Attachment count
      attachmentsCount: attachments.count
    }
  end
  
  private
  
  def generate_payment_number
    self.payment_number ||= loop do
      number = "MARP-#{Time.current.year}-#{SecureRandom.hex(4).upcase}"
      break number unless self.class.exists?(company_id: company_id, payment_number: number)
    end
  end
end
