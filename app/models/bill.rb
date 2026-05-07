# frozen_string_literal: true

class Bill < ApplicationRecord
  belongs_to :company
  belongs_to :vendor, optional: true
  belongs_to :contact, optional: true
  belongs_to :location, optional: true
  belongs_to :ap_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :journal_entry, optional: true
  belongs_to :payment_journal_entry, class_name: 'JournalEntry', optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  has_many :bill_line_items, dependent: :destroy
  has_many :bill_payments, dependent: :destroy
  accepts_nested_attributes_for :bill_line_items, allow_destroy: true

  STATUSES = %w[draft pending partially_paid paid void].freeze
  PAYMENT_TERMS = %w[due_on_receipt net_15 net_30 net_45 net_60 net_90].freeze

  validates :bill_date, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :total_amount, numericality: { greater_than_or_equal_to: 0 }

  before_validation :compute_totals
  before_create :assign_bill_number
  after_create :auto_post_bill_je, if: -> { status != 'draft' && status != 'void' }

  scope :active, -> { where(is_deleted: false) }
  scope :unpaid, -> { where(status: %w[pending partially_paid]) }
  scope :for_current_location, -> { Current.location_filtered? ? where(location_id: Current.location_id) : all }

  def vendor_display_name
    vendor&.name.presence ||
      contact_display_name.presence ||
      vendor_name.presence ||
      'Unknown Vendor'
  end

  def record_payment!(attrs)
    payment = bill_payments.build(attrs.merge(company_id: company_id))

    ActiveRecord::Base.transaction do
      payment.save!

      bank_gl_account = payment.chart_of_account ||
                        payment.bank_account&.chart_of_account
      ap = resolve_ap_account

      if bank_gl_account && ap
        je = company.journal_entries.create!(
          entry_date: payment.payment_date,
          memo: "Payment for Bill #{bill_number} — #{vendor_display_name}",
          source_type: 'auto',
          source_entity: self,
          posted_by: payment.created_by
        )
        je.journal_entry_lines.create!(
          chart_of_account: ap,
          debit_amount: payment.amount,
          credit_amount: 0,
          memo: "Bill payment — #{vendor_display_name}",
          location_id: location_id
        )
        je.journal_entry_lines.create!(
          chart_of_account: bank_gl_account,
          debit_amount: 0,
          credit_amount: payment.amount,
          memo: "Bill payment — #{bill_number}",
          location_id: location_id
        )
        payment.update!(journal_entry: je)
      end

      refresh_payment_status!
    end

    payment
  end

  def void!
    return if status == 'void'

    ActiveRecord::Base.transaction do
      voider = created_by || company.users.first

      journal_entry&.void!(voider) if journal_entry && !journal_entry.is_void?

      bill_payments.each do |bp|
        bp.journal_entry&.void!(voider) if bp.journal_entry && !bp.journal_entry.is_void?
      end

      update!(status: 'void', balance_due: 0)
    end
  end

  def refresh_payment_status!
    return if status == 'void'

    paid = bill_payments.sum(:amount)
    new_status =
      if paid <= 0
        bill_line_items.any? ? 'pending' : 'draft'
      elsif paid >= total_amount
        'paid'
      else
        'partially_paid'
      end

    update_columns(
      status: new_status,
      amount_paid: paid,
      balance_due: total_amount - paid,
      updated_at: Time.current
    )
  end

  private

  def contact_display_name
    return nil unless contact
    name = [contact.try(:first_name), contact.try(:last_name)].compact.join(' ').strip
    return name if name.present?
    contact.try(:account)&.try(:name)
  end

  def compute_totals
    items = bill_line_items.reject(&:marked_for_destruction?)
    self.subtotal = items.sum { |i| i.amount.to_d }
    self.tax_amount ||= 0
    self.total_amount = subtotal + tax_amount.to_d
    self.amount_paid ||= 0
    self.balance_due = total_amount - amount_paid.to_d
  end

  def assign_bill_number
    return if bill_number.present?
    last = company.bills.where("bill_number ~ '^BILL-[0-9]+$'").maximum(:bill_number)
    next_seq = last ? last.split('-').last.to_i + 1 : 1
    self.bill_number = "BILL-#{next_seq.to_s.rjust(5, '0')}"
  end

  def auto_post_bill_je
    return if journal_entry_id.present?
    ap = resolve_ap_account
    return unless ap
    return if bill_line_items.empty?
    return if total_amount.to_d <= 0

    je = company.journal_entries.create!(
      entry_date: bill_date,
      memo: "Bill #{bill_number} — #{vendor_display_name}",
      source_type: 'auto',
      source_entity: self,
      posted_by: created_by
    )

    je.journal_entry_lines.create!(
      chart_of_account: ap,
      debit_amount: 0,
      credit_amount: total_amount,
      memo: "AP — #{vendor_display_name}",
      location_id: location_id
    )

    bill_line_items.each do |line|
      je.journal_entry_lines.create!(
        chart_of_account_id: line.chart_of_account_id,
        debit_amount: line.amount,
        credit_amount: 0,
        memo: line.description.presence || "Bill #{bill_number}",
        location_id: line.location_id || location_id,
        department: line.department
      )
    end

    update_column(:journal_entry_id, je.id)
  rescue => e
    Rails.logger.error("[Accounting] Bill #{id} auto-post failed: #{e.message}")
    nil
  end

  def resolve_ap_account
    ap_account ||
      company.accounting_settings&.default_ap_account ||
      company.chart_of_accounts.find_by(sub_type: 'accounts_payable', is_active: true)
  end
end
