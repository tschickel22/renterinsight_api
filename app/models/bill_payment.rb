# frozen_string_literal: true

class BillPayment < ApplicationRecord
  belongs_to :bill
  belongs_to :company
  belongs_to :bank_account, optional: true
  belongs_to :chart_of_account, optional: true
  belongs_to :journal_entry, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  has_many :printed_checks, dependent: :nullify

  PAYMENT_METHOD_CHECK = 'check'
  PAYMENT_METHOD_PRINT_CHECK = 'print_check'
  PAYMENT_METHODS = %w[check print_check ach credit_card cash other].freeze

  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :payment_date, presence: true
  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_blank: true
  validate  :check_printing_must_be_enabled_for_print_check

  after_create :create_queued_check, if: :should_queue_check?

  scope :active, -> { where(voided: [false, nil]) }

  def voided?
    voided == true
  end

  # Creates the queued PrintedCheck that the print-batch flow later prints.
  # Idempotent — won't create a second check if one already exists for this payment.
  def create_queued_check
    return unless payment_method == PAYMENT_METHOD_PRINT_CHECK
    return unless bank_account&.check_printing_enabled
    return if PrintedCheck.exists?(bill_payment_id: id)

    vendor = bill&.vendor

    PrintedCheck.create!(
      company_id: company_id,
      bank_account_id: bank_account_id,
      paid_to: vendor&.name.presence || bill&.vendor_name.presence || 'Unknown',
      amount: amount,
      memo: bill&.bill_number.present? ? "Bill ##{bill.bill_number}" : nil,
      description: bill&.notes,
      status: PrintedCheck::STATUS_QUEUED,
      vendor_id: vendor&.id,
      bill_id: bill&.id,
      bill_payment_id: id,
      contact_id: nil
    )
  end

  private

  def should_queue_check?
    payment_method == PAYMENT_METHOD_PRINT_CHECK && bank_account&.check_printing_enabled
  end

  def check_printing_must_be_enabled_for_print_check
    return unless payment_method == PAYMENT_METHOD_PRINT_CHECK
    return if bank_account&.check_printing_enabled

    errors.add(:bank_account, 'must have check printing enabled for print_check payments')
  end
end
