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
  # The deal (and its project) the money was taken for. A deposit taken before
  # the deal has an invoice stays unapplied, in the deposits account, until
  # the deal's invoice is made and it is applied (apply_deposit_to!).
  belongs_to :deal, optional: true
  belongs_to :project, optional: true

  has_many :cash_receipt_applications, dependent: :destroy
  has_many :invoices, through: :cash_receipt_applications

  validates :receipt_date, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :receipt_number, uniqueness: { scope: :company_id }, allow_blank: true
  validate :deal_and_project_belong_to_company

  before_validation :project_from_deal

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

  # Invoice#update_status_based_on_payments is the one place an invoice's
  # paid/due/status is worked out (payments, credit memos and receipts).
  def update_invoice_balances!
    cash_receipt_applications.includes(:invoice).each do |app|
      next unless app.invoice

      app.invoice.update_status_based_on_payments
      DealInvoiceService.refresh_draws!(app.invoice)
    end
  end

  # Applies held (unapplied) money to an invoice: a deposit taken before the
  # deal had one. The deposit sat in a liability account, so applying it moves
  # that amount to receivables (Dr deposits, Cr AR). A receipt whose remainder
  # was credited to AR itself needs no entry.
  def apply_deposit_to!(invoice, amount, user: nil, entry_date: Date.current)
    amount = [amount.to_d, amount_unapplied.to_d, invoice.amount_due.to_d].min.round(2)
    return nil unless amount.positive?

    transaction do
      application = cash_receipt_applications.create!(invoice: invoice, amount_applied: amount)
      held_in = held_deposit_account_id
      ar_account = resolve_ar_account
      if held_in && ar_account && held_in != ar_account.id
        je = company.journal_entries.create!(
          entry_date: entry_date,
          memo: "Deposit #{receipt_number} applied to #{invoice.invoice_number}: #{display_customer}",
          source_type: 'auto',
          source_entity: self,
          posted_by_id: user&.id || created_by_id,
          journal_entry_lines_attributes: [
            { chart_of_account_id: held_in, debit_amount: amount, credit_amount: 0, location_id: location_id,
              memo: "Deposit applied: #{display_customer}", deal_id: deal_id, project_id: project_id, contact_id: contact_id },
            { chart_of_account_id: ar_account.id, debit_amount: 0, credit_amount: amount, location_id: location_id,
              memo: "Deposit applied to #{invoice.invoice_number}: #{display_customer}", contact_id: contact_id }
          ]
        )
        application.update_column(:journal_entry_id, je.id)
      end
      recalculate_applied_amounts!
      invoice.update_status_based_on_payments
      DealInvoiceService.refresh_draws!(invoice)
      application
    end
  end

  def void!
    transaction do
      update!(status: STATUS_VOIDED, voided_at: Time.current)

      if journal_entry.present? && !journal_entry.is_void?
        journal_entry.void!(Current.user)
      end
      cash_receipt_applications.where.not(journal_entry_id: nil).each do |app|
        je = company.journal_entries.find_by(id: app.journal_entry_id)
        je.void!(Current.user) if je && !je.is_void?
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
        memo: "#{deal_id ? 'Deposit' : 'Unapplied deposit'}: #{display_customer}",
        location_id: location_id,
        # Only the deposits line names the deal: AR lines never do (deal
        # receivables are read from the deal's invoice, Reports::DealFunding).
        deal_id: unapplied_account.id == ar_account.id ? nil : deal_id,
        project_id: unapplied_account.id == ar_account.id ? nil : project_id,
        contact_id: contact_id
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

  # It looked for a 'Customer Deposits' account of a sub type no chart uses, so
  # every unapplied remainder was credited to AR.
  def resolve_unapplied_deposits_account
    AccountingSettings.for_company(company).deposits_account
  end

  # The account this receipt's unapplied remainder was credited to when it
  # posted (nil when it never posted).
  def held_deposit_account_id
    return nil unless journal_entry

    bank_id = bank_account&.chart_of_account_id
    journal_entry.journal_entry_lines.where('credit_amount > 0').where.not(chart_of_account_id: bank_id)
                 .order(:id).last&.chart_of_account_id
  end

  def project_from_deal
    return unless deal_id_changed? && deal

    self.project_id ||= company.projects.not_deleted.where(deal_id: deal_id).pick(:id)
  end

  def deal_and_project_belong_to_company
    errors.add(:deal_id, 'must be one of your deals') if deal_id.present? && company.deals.where(id: deal_id).none?
    errors.add(:project_id, 'must be one of your projects') if project_id.present? && company.projects.where(id: project_id).none?
  end
end
