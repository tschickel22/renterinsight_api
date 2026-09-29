# frozen_string_literal: true

class Bill < ApplicationRecord
  include Reportable
  include GlPostTracking

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
  # A bill saved as a draft and approved later never posted, since posting
  # only ran on create.
  after_update :auto_post_bill_je, if: -> { saved_change_to_status? && status_before_last_save == 'draft' && !%w[draft void].include?(status) }

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
          posted_by: payment.created_by,
          journal_entry_lines_attributes: [
            {
              chart_of_account_id: ap.id,
              debit_amount: payment.amount,
              credit_amount: 0,
              memo: "Bill payment — #{vendor_display_name}",
              location_id: location_id
            },
            {
              chart_of_account_id: bank_gl_account.id,
              debit_amount: 0,
              credit_amount: payment.amount,
              memo: "Bill payment — #{bill_number}",
              location_id: location_id
            }
          ]
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

    paid = bill_payments.where(voided: [false, nil]).sum(:amount)
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

  alias_method :recalculate_balance!, :refresh_payment_status!

  def self.reportable_config
    {
      label: 'Bills',
      fields: [
        { key: 'id',             label: 'ID',             type: 'number',  filterable: true,  sortable: true },
        { key: 'bill_number',    label: 'Bill #',         type: 'string',  filterable: true,  sortable: true },
        { key: 'vendor_name',    label: 'Vendor',         type: 'string',  filterable: true,  sortable: true },
        { key: 'bill_date',      label: 'Bill Date',      type: 'date',    filterable: true,  sortable: true },
        { key: 'due_date',       label: 'Due Date',       type: 'date',    filterable: true,  sortable: true },
        { key: 'status',         label: 'Status',         type: 'enum',    filterable: true,  sortable: true },
        { key: 'subtotal',       label: 'Subtotal',       type: 'number',  filterable: true,  sortable: true },
        { key: 'tax_amount',     label: 'Tax',            type: 'number',  filterable: false, sortable: true },
        { key: 'total_amount',   label: 'Total',          type: 'number',  filterable: true,  sortable: true },
        { key: 'amount_paid',    label: 'Amount Paid',    type: 'number',  filterable: true,  sortable: true },
        { key: 'balance_due',    label: 'Balance Due',    type: 'number',  filterable: true,  sortable: true },
        { key: 'payment_terms',  label: 'Payment Terms',  type: 'enum',    filterable: true,  sortable: false },
        { key: 'created_at',     label: 'Created',        type: 'date',    filterable: true,  sortable: true },
      ]
    }
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
    return record_gl_post_failure!('No Accounts Payable account is set on the bill or in Accounting Settings') unless ap
    return if bill_line_items.empty?
    return if total_amount.to_d <= 0

    lines_attrs = []

    # Credit AP for the full amount
    lines_attrs << {
      chart_of_account_id: ap.id,
      debit_amount: 0,
      credit_amount: total_amount,
      memo: "AP — #{vendor_display_name}",
      location_id: location_id
    }

    # Debit each expense line item, with the bill's tax spread across them.
    # AP is credited the full total including tax, but the debits used to be
    # the line amounts alone, so a bill with tax never balanced and never
    # posted. Purchase tax is part of what the items cost.
    tax_shares = allocate_tax_to_lines
    bill_line_items.each do |line|
      lines_attrs << {
        chart_of_account_id: line.chart_of_account_id,
        debit_amount: line.amount.to_d + tax_shares.fetch(line.id, 0),
        credit_amount: 0,
        memo: line.description.presence || "Bill #{bill_number}",
        location_id: line.location_id || location_id,
        department: line.department
      }
    end

    je = company.journal_entries.create!(
      entry_date: bill_date,
      memo: "Bill #{bill_number} — #{vendor_display_name}",
      source_type: 'auto',
      source_entity: self,
      posted_by: created_by,
      journal_entry_lines_attributes: lines_attrs
    )

    update_column(:journal_entry_id, je.id)
    clear_gl_post_failure!
    je
  rescue => e
    record_gl_post_failure!(e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.join(', ') : e.message)
    nil
  end

  # { line_id => share of tax_amount }, proportional to line amounts, rounded
  # to cents with the remainder on the largest line so the shares sum exactly.
  def allocate_tax_to_lines
    tax = tax_amount.to_d.round(2)
    lines = bill_line_items.to_a
    base = lines.sum { |l| l.amount.to_d }
    return {} if tax.zero? || lines.empty? || base.zero?

    shares = lines.to_h { |l| [l.id, (tax * l.amount.to_d / base).round(2)] }
    largest = lines.max_by { |l| l.amount.to_d }
    shares[largest.id] += tax - shares.values.sum
    shares
  end

  def resolve_ap_account
    ap_account ||
      company.accounting_settings&.default_ap_account ||
      company.chart_of_accounts.find_by(sub_type: 'accounts_payable', is_active: true)
  end
end
