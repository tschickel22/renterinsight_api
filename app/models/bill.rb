# frozen_string_literal: true

class Bill < ApplicationRecord
  # Confidential files: stored as references, served as expiring links (PrivateFiles).
  include PrivateFileColumns
  private_file_attachments :attachments, %w[url]

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
  # Set on open bills carried over by a QuickBooks switch. The switch's
  # opening entry already holds their payable, so they never post.
  belongs_to :accounting_import, optional: true
  # Job the bill is for (E68). A contractor's portal invoice sets it, with the
  # project cost line it pays for.
  belongs_to :project, optional: true
  has_many :project_cost_items, dependent: :nullify

  has_many :bill_line_items, dependent: :destroy
  has_many :bill_payments, dependent: :destroy
  accepts_nested_attributes_for :bill_line_items, allow_destroy: true

  STATUSES = %w[draft pending partially_paid paid void].freeze
  PAYMENT_TERMS = %w[due_on_receipt net_15 net_30 net_45 net_60 net_90].freeze

  validates :bill_date, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :total_amount, numericality: { greater_than_or_equal_to: 0 }
  validate :project_belongs_to_company, if: -> { project_id.present? && will_save_change_to_project_id? }

  before_validation :compute_totals
  before_create :assign_bill_number
  after_create :auto_post_bill_je, if: -> { status != 'draft' && status != 'void' }
  # A bill saved as a draft and approved later never posted, since posting
  # only ran on create.
  after_update :auto_post_bill_je, if: -> { saved_change_to_status? && status_before_last_save == 'draft' && !%w[draft void].include?(status) }

  after_update :sync_project_cost_items, if: -> { saved_change_to_status? || saved_change_to_total_amount? }
  # Declared after the posting callbacks, so the bill's entry exists by now.
  after_save :sync_project_job_cost
  after_update :sync_gl_project_tags, if: -> { journal_entry_id.present? && !saved_change_to_journal_entry_id? }

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

    old_status = status
    update_columns(
      status: new_status,
      amount_paid: paid,
      balance_due: total_amount - paid,
      updated_at: Time.current
    )
    # update_columns skips callbacks, so a payment reaches the cost line here.
    apply_cost_sync(status_changed: old_status != new_status, total_changed: false)
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
    return if accounting_import_id.present?
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
    deals = project_deal_ids
    bill_line_items.each do |line|
      project = line.effective_project_id
      lines_attrs << {
        chart_of_account_id: line.chart_of_account_id,
        debit_amount: line.amount.to_d + tax_shares.fetch(line.id, 0),
        credit_amount: 0,
        memo: line.description.presence || "Bill #{bill_number}",
        location_id: line.location_id || location_id,
        department: line.department,
        project_id: project,
        deal_id: project && deals[project]
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

  # The cost line follows its bill: approving it approves the cost, paying it
  # pays the cost, voiding it marks the cost disputed. A corrected total moves
  # the cost line too when the bill pays for that one line alone.
  COST_STATUS_FOR_BILL = { 'pending' => 'approved', 'partially_paid' => 'approved', 'paid' => 'paid', 'void' => 'disputed' }.freeze

  def sync_project_cost_items
    apply_cost_sync(status_changed: saved_change_to_status?, total_changed: saved_change_to_total_amount?)
  end

  def apply_cost_sync(status_changed:, total_changed:)
    items = project_cost_items.not_deleted.to_a
    return if items.empty?

    attrs = {}
    if status_changed && (cost_status = COST_STATUS_FOR_BILL[status])
      attrs[:status] = cost_status
      attrs[:paid_at] = Time.current if cost_status == 'paid'
    end
    items.each do |item|
      item_attrs = attrs.dup
      item_attrs[:amount] = total_amount if items.size == 1 && total_changed && total_amount.to_d.positive?
      item.update!(item_attrs) if item_attrs.any?
    end
  end

  # E68 step 3. The job a bill line is for, and that job's deal, go onto the
  # line's ledger debit. AP stays untagged: it is owed to the vendor, not spent
  # on the job.
  def project_deal_ids
    ids = bill_line_items.map(&:effective_project_id).compact.uniq
    ids.empty? ? {} : company.projects.where(id: ids).pluck(:id, :deal_id).to_h
  end

  # A posted bill retagged to another job moves its ledger lines with it. Only
  # the tags change, never amounts, and only while the entry still lines up
  # with the bill one debit per bill line; a locked (closed period) entry stays
  # as it was.
  def sync_gl_project_tags
    je = journal_entry
    return if je.nil? || je.is_void? || je.locked?

    debits = je.journal_entry_lines.where('debit_amount > 0').order(:id).to_a
    lines = bill_line_items.reload.sort_by(&:id)
    return unless debits.size == lines.size
    return unless debits.zip(lines).all? { |d, l| d.chart_of_account_id == l.chart_of_account_id }

    deals = project_deal_ids
    debits.zip(lines).each do |debit, line|
      project = line.effective_project_id
      tags = { project_id: project, deal_id: project && deals[project] }
      debit.update_columns(tags) if tags.any? { |k, v| debit[k] != v }
    end
  end

  # A bill for a job is part of that job's cost. Contractor invoices and the
  # drafts a cost line makes already have their cost line; any other posted
  # bill tagged to a project gets one per project here (amount including its
  # share of tax), kept in step when the bill is edited or retagged. Drafts
  # count nothing yet, and a void marks its cost lines disputed through
  # sync_project_cost_items.
  def sync_project_job_cost
    linked = project_cost_items.not_deleted.to_a
    return if linked.any? { |item| item.metadata.to_h['source'] != 'bill' }

    if is_deleted?
      linked.each { |item| item.update!(is_deleted: true) }
      return
    end
    return if %w[draft void].include?(status)

    bill_line_items.reload
    tax_shares = allocate_tax_to_lines
    wanted = Hash.new(0.to_d)
    bill_line_items.each do |line|
      project = line.effective_project_id
      wanted[project] += line.amount.to_d + tax_shares.fetch(line.id, 0) if project
    end

    linked.each do |item|
      if wanted.key?(item.project_id)
        amount = wanted.delete(item.project_id)
        item.update!(amount: amount, vendor_id: vendor_id) if item.amount.to_d != amount || item.vendor_id != vendor_id
      else
        item.update!(is_deleted: true)
      end
    end

    cost_status = COST_STATUS_FOR_BILL[status] || 'approved'
    wanted.each do |project_id, amount|
      next unless amount.positive?

      project_cost_items.create!(
        company_id: company_id,
        project_id: project_id,
        vendor_id: vendor_id,
        cost_type: vendor&.vendor_type == 'contractor' ? 'subcontractor' : (vendor&.vendor_type == 'supplier' ? 'materials' : 'other'),
        description: "Bill #{bill_number} from #{vendor_display_name}".truncate(250),
        invoice_number: reference_number,
        amount: amount,
        date: bill_date,
        status: cost_status,
        paid_at: cost_status == 'paid' ? Time.current : nil,
        metadata: { 'source' => 'bill' }
      )
    end
  end

  def project_belongs_to_company
    errors.add(:project_id, 'is not one of your projects') unless company.projects.where(id: project_id).exists?
  end

  def resolve_ap_account
    ap_account ||
      company.accounting_settings&.default_ap_account ||
      company.chart_of_accounts.find_by(sub_type: 'accounts_payable', is_active: true)
  end
end
