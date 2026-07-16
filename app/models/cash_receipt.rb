# frozen_string_literal: true

class CashReceipt < ApplicationRecord
  PAYMENT_METHODS = %w[check ach wire cash credit_card other].freeze
  STATUS_POSTED = 'posted'
  STATUS_VOIDED = 'voided'

  belongs_to :company
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :bank_account, optional: true
  belongs_to :journal_entry, optional: true
  belongs_to :location, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  has_many :cash_receipt_applications, dependent: :destroy
  has_many :invoices, through: :cash_receipt_applications

  validates :receipt_date, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :receipt_number, uniqueness: { scope: :company_id }, allow_blank: true

  scope :posted, -> { where(status: STATUS_POSTED) }
  scope :voided, -> { where(status: STATUS_VOIDED) }
  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :for_current_location, -> {
    Current.location_filtered? ? where(location_id: Current.location_id) : all
  }

  before_create :generate_receipt_number
  after_create :post_journal_entry
  after_create :apply_to_invoices_and_update

  def apply_to_invoices_and_update
    recalculate_applied_amounts!
    update_invoice_balances!
  end

  def recalculate_applied_amounts!
    applied = cash_receipt_applications.sum(:amount_applied)
    update_columns(
      amount_applied: applied,
      amount_unapplied: amount - applied
    )
  end

  def update_invoice_balances!
    cash_receipt_applications.includes(:invoice).each do |app|
      invoice = app.invoice
      next unless invoice

      # Sum applied amounts (not payment totals) so a payment split across
      # multiple invoices only credits each invoice with its own share.
      total_paid_from_payments = invoice.payment_applications
        .joins(:payment)
        .where.not(payments: { status: 'voided' })
        .sum(:amount) rescue 0
      total_paid_from_receipts = CashReceiptApplication
        .joins(:cash_receipt)
        .where(invoice_id: invoice.id)
        .where(cash_receipts: { status: STATUS_POSTED, is_deleted: [false, nil] })
        .sum(:amount_applied)

      total_paid = total_paid_from_payments.to_d + total_paid_from_receipts.to_d
      balance = [invoice.total.to_d - total_paid, 0].max

      new_status = if balance <= 0
        'paid'
      elsif total_paid > 0
        'partial'
      else
        invoice.status == 'paid' || invoice.status == 'partial' ? 'sent' : invoice.status
      end

      invoice.update_columns(
        amount_paid: total_paid,
        amount_due: balance,
        status: new_status,
        paid_at: balance <= 0 ? (invoice.paid_at || Time.current) : invoice.paid_at
      )
    end
  end

  def void!
    transaction do
      update!(status: STATUS_VOIDED, voided_at: Time.current)

      if journal_entry.present? && !journal_entry.is_void?
        journal_entry.void!(Current.user)
      end

      update_invoice_balances!
    end
  end

  def display_customer
    account&.name || contact&.full_name || customer_name || 'Unknown'
  end

  private

  def generate_receipt_number
    return if receipt_number.present?
    max_num = company.cash_receipts.maximum(:receipt_number)
    num = max_num.present? ? max_num.scan(/\d+/).last.to_i + 1 : 1
    self.receipt_number = "CR-#{num.to_s.rjust(5, '0')}"
  end

  def post_journal_entry
    bank_gl = bank_account&.chart_of_account
    ar_account = resolve_ar_account
    return unless bank_gl && ar_account

    lines_attrs = []

    lines_attrs << {
      chart_of_account_id: bank_gl.id,
      debit_amount: amount,
      credit_amount: 0,
      memo: "Cash receipt #{receipt_number} — #{display_customer}",
      location_id: location_id
    }

    if amount_applied.to_d > 0
      lines_attrs << {
        chart_of_account_id: ar_account.id,
        debit_amount: 0,
        credit_amount: amount_applied,
        memo: "Applied to invoices — #{display_customer}",
        location_id: location_id
      }
    end

    if amount_unapplied.to_d > 0
      unapplied_account = resolve_unapplied_deposits_account || ar_account
      lines_attrs << {
        chart_of_account_id: unapplied_account.id,
        debit_amount: 0,
        credit_amount: amount_unapplied,
        memo: "Unapplied deposit — #{display_customer}",
        location_id: location_id
      }
    end

    if lines_attrs.size == 1
      lines_attrs << {
        chart_of_account_id: ar_account.id,
        debit_amount: 0,
        credit_amount: amount,
        memo: "Cash receipt — #{display_customer}",
        location_id: location_id
      }
    end

    je = company.journal_entries.create!(
      entry_date: receipt_date,
      memo: "Cash Receipt #{receipt_number} — #{display_customer}",
      source_type: 'auto',
      source_entity: self,
      posted_by_id: created_by_id,
      journal_entry_lines_attributes: lines_attrs
    )

    update_column(:journal_entry_id, je.id)
  rescue => e
    Rails.logger.error("[CashReceipt] JE post failed for #{id}: #{e.message}")
    nil
  end

  def resolve_ar_account
    settings = company.accounting_settings
    settings&.default_ar_account || company.chart_of_accounts.find_by(sub_type: 'accounts_receivable')
  end

  def resolve_unapplied_deposits_account
    company.chart_of_accounts.find_by(sub_type: 'other_current_liability', name: 'Customer Deposits')
  end
end
