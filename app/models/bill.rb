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
  validate :total_covers_payments, if: -> { will_save_change_to_total_amount? && persisted? }

  before_validation :compute_totals
  before_create :assign_bill_number
  after_create :auto_post_bill_je, if: -> { status != 'draft' && status != 'void' }
  # A bill saved as a draft and approved later never posted, since posting
  # only ran on create.
  after_update :auto_post_bill_je, if: -> { saved_change_to_status? && status_before_last_save == 'draft' && !%w[draft void].include?(status) }

  after_update :sync_project_cost_items, if: -> { saved_change_to_status? || saved_change_to_total_amount? }
  # Declared after the posting callbacks, so the bill's entry exists by now.
  after_save :sync_project_job_cost
  after_update :refresh_posted_je, if: -> { journal_entry_id.present? && !saved_change_to_journal_entry_id? && status != 'void' }

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

    je = company.journal_entries.create!(
      entry_date: bill_date,
      memo: bill_je_memo,
      source_type: 'auto',
      source_entity: self,
      posted_by: created_by,
      journal_entry_lines_attributes: bill_je_lines(ap)
    )

    update_column(:journal_entry_id, je.id)
    clear_gl_post_failure!
    je
  rescue => e
    record_gl_post_failure!(e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.join(', ') : e.message)
    nil
  end

  def bill_je_memo
    "Bill #{bill_number} — #{vendor_display_name}"
  end

  # AP credited the full total; each line debited with its share of the
  # bill's tax. AP used to be credited the total while the debits were the
  # line amounts alone, so a bill with tax never balanced and never posted.
  # Purchase tax is part of what the items cost.
  def bill_je_lines(ap)
    lines = [{
      chart_of_account_id: ap.id,
      debit_amount: 0,
      credit_amount: total_amount.to_d,
      memo: "AP — #{vendor_display_name}",
      location_id: location_id,
      department: nil,
      project_id: nil,
      deal_id: nil
    }]

    tax_shares = allocate_tax_to_lines
    deals = project_deal_ids
    bill_line_items.sort_by { |l| l.id || 0 }.each do |line|
      project = line.effective_project_id
      lines << {
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
    lines
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

  JE_LINE_FIELDS = %i[chart_of_account_id debit_amount credit_amount memo location_id department project_id deal_id].freeze
  JE_MONEY_FIELDS = %i[chart_of_account_id debit_amount credit_amount].freeze

  # A posted bill that is edited (amounts, accounts, tax, lines, date, job)
  # rewrites its ledger entry to match. It used to keep the amounts it was
  # posted with, so the books and the job cost drifted apart. Lines are
  # updated in place where they pair up, so their ids survive. A closed
  # period's entry cannot change: a money change there is refused, and a
  # change of tags alone leaves the entry as it was.
  def refresh_posted_je
    je = journal_entry
    return if je.nil? || je.is_void? || accounting_import_id.present?

    ap = je.journal_entry_lines.where('credit_amount > 0').order(:id).first&.chart_of_account || resolve_ap_account
    return unless ap

    bill_line_items.reload
    wanted = bill_je_lines(ap)
    current = je.journal_entry_lines.order(:id).to_a
    row = ->(attrs, fields) { fields.map { |f| v = attrs[f]; v.is_a?(Numeric) ? v.to_d : v.presence } }
    same = ->(fields) { current.size == wanted.size && current.zip(wanted).all? { |c, w| row.(c, fields) == row.(w, fields) } }

    date_same = je.entry_date == bill_date
    return if same.(JE_LINE_FIELDS) && date_same && je.memo == bill_je_memo

    if je.locked?
      return if same.(JE_MONEY_FIELDS) && date_same

      errors.add(:base, "Bill #{bill_number} is posted in a closed period. Reopen the period, or void the bill and enter it again.")
      raise ActiveRecord::RecordInvalid, self
    end

    attrs = current.zip(wanted).filter_map { |c, w| c && w ? w.merge(id: c.id) : nil }
    attrs += current.drop(wanted.size).map { |c| { id: c.id, _destroy: true } }
    attrs += wanted.drop(current.size)
    je.update!(entry_date: bill_date, memo: bill_je_memo, journal_entry_lines_attributes: attrs)
  rescue ActiveRecord::RecordInvalid => e
    raise if e.record.equal?(self)

    e.record.errors.full_messages.each { |m| errors.add(:base, "Ledger entry: #{m}") }
    raise ActiveRecord::RecordInvalid, self
  end

  def total_covers_payments
    return if amount_paid.to_d <= total_amount.to_d

    errors.add(:base, "Total can't be less than the #{format('%.2f', amount_paid.to_d)} already paid")
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
