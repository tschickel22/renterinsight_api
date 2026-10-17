# frozen_string_literal: true

class JournalEntry < ApplicationRecord
  # Confidential files: stored as references, served as expiring links (PrivateFiles).
  include PrivateFileColumns
  private_file_attachments :attachments, %w[url]

  include Reportable

  belongs_to :company
  belongs_to :posted_by, class_name: 'User', optional: true
  belongs_to :voided_by, class_name: 'User', optional: true
  belongs_to :reversed_by, class_name: 'JournalEntry', optional: true
  belongs_to :source_entity, polymorphic: true, optional: true

  has_many :journal_entry_lines, dependent: :destroy
  accepts_nested_attributes_for :journal_entry_lines, allow_destroy: true

  validates :entry_date, presence: true
  validate :lines_balance
  validate :at_least_two_lines
  validate :no_edits_if_locked
  validate :no_edits_if_voided
  validate :period_is_open, if: -> { (new_record? || will_save_change_to_entry_date?) && !allow_closed_period }

  # Set only when recording something the closed period already reported,
  # e.g. converting an opening balance that reports were adding at report
  # time (script/post_opening_balances.rb). Never for new activity.
  attr_accessor :allow_closed_period

  before_create :assign_entry_number
  before_save :set_fiscal_period
  # E68: expense on a project from Record Expense or a manual entry is job
  # cost. Bills keep their own cost lines and reversals are 'auto', so only
  # these two sources are counted here.
  JOB_COST_SOURCES = %w[manual quick_entry].freeze
  after_save :sync_project_job_cost, if: -> { JOB_COST_SOURCES.include?(source_type) }
  before_destroy :drop_project_job_cost

  scope :posted, -> { where(is_void: false) }
  # Entries that count toward balances. Voiding keeps the original in its own
  # period and adds a reversal on the void date, so both must be counted and
  # net to zero. Filtering on is_void alone dropped the original but kept the
  # reversal, so every void showed up as the negative of the entry, and a
  # void in a closed year rewrote that year's profit.
  scope :in_ledger, -> { where(is_void: false).or(where(is_void: true).where.not(reversed_by_id: nil)) }
  # Live entries minus void pairs: what bank reconciliation and matching
  # should see, since a voided entry and its reversal never touched the bank.
  scope :excluding_void_pairs, lambda {
    where(is_void: false).where.not(id: unscoped.where(is_void: true).where.not(reversed_by_id: nil).select(:reversed_by_id))
  }
  scope :voided, -> { where(is_void: true) }
  scope :manual, -> { where(source_type: 'manual') }
  scope :for_period, ->(year, period) { where(fiscal_year: year, fiscal_period: period) }
  scope :for_date_range, ->(start_date, end_date) { where(entry_date: start_date..end_date) }

  # Closing a period only locked the entries already in it; new or backdated
  # entries still landed there, so a closed year's profit changed after its
  # Year-End Close had moved it into Retained Earnings.
  def period_is_open
    return if entry_date.blank? || company_id.blank?

    closed = FiscalPeriod.where(company_id: company_id, status: %w[closed locked])
                         .where('start_date <= ? AND end_date >= ?', entry_date, entry_date)
                         .first
    return unless closed

    errors.add(:entry_date, "#{entry_date} is in a closed period (FY#{closed.fiscal_year} period #{closed.period_number}). " \
                            'Reopen the period or date the entry in an open one.')
  end

  def lines_balance
    return if journal_entry_lines.empty?

    total_debits = journal_entry_lines.reject(&:marked_for_destruction?).sum(&:debit_amount)
    total_credits = journal_entry_lines.reject(&:marked_for_destruction?).sum(&:credit_amount)

    unless total_debits == total_credits
      errors.add(:base, "Debit and Credit amounts must be equal (debits: #{total_debits}, credits: #{total_credits})")
    end
  end

  def at_least_two_lines
    active_lines = journal_entry_lines.reject(&:marked_for_destruction?)
    if active_lines.length < 2
      errors.add(:base, "Journal entry must have at least two lines")
    end
  end

  def no_edits_if_locked
    if locked && changed? && !new_record? && !is_void_changed?
      errors.add(:base, "Cannot edit a locked journal entry (period is closed)")
    end
  end

  def no_edits_if_voided
    if is_void && changed? && !is_void_changed?
      errors.add(:base, "Cannot edit a voided journal entry")
    end
  end

  # Advisory-lock namespace, distinct from Invoice#INVOICE_NUMBER_LOCK_NAMESPACE
  # so the two number-generators don't share a lock slot.
  ENTRY_NUMBER_LOCK_NAMESPACE = 0x1_2E_00_4E.freeze

  def assign_entry_number
    return if entry_number.present?
    return unless company_id

    # Serialize entry-number generation per company for the enclosing
    # transaction so concurrent journal saves can't both compute the same
    # max and race the unique index.
    self.class.connection.execute(
      self.class.sanitize_sql_array(['SELECT pg_advisory_xact_lock(?, ?)', ENTRY_NUMBER_LOCK_NAMESPACE, company_id])
    )

    # Only consider numeric entry numbers when computing the next sequence
    # value; entries with prefixed/labelled numbers (e.g., from seed data
    # or future imports) must not shadow the running counter.
    max = company.journal_entries
                 .where("entry_number ~ '^[0-9]+$'")
                 .maximum("entry_number::int") || 0
    # Defence-in-depth against numbers inserted via a path that bypasses
    # this generator (e.g. raw SQL import). Under the advisory lock this
    # normally exits on the first iteration.
    loop do
      candidate = (max + 1).to_s.rjust(6, '0')
      unless company.journal_entries.exists?(entry_number: candidate)
        self.entry_number = candidate
        break
      end
      max += 1
    end
  end

  def set_fiscal_period
    return unless entry_date.present?
    settings = company.accounting_settings
    start_month = settings&.fiscal_year_start_month || 1

    if entry_date.month >= start_month
      self.fiscal_year = entry_date.year
      self.fiscal_period = entry_date.month - start_month + 1
    else
      self.fiscal_year = entry_date.year - 1
      self.fiscal_period = 12 - start_month + entry_date.month + 1
    end
  end

  # entry_date: when the reversal lands, today by default. Undoing a QuickBooks
  # switch passes the opening entry's own date, so the books as of the cutover
  # and the month after it are left as if it never posted.
  def void!(user, entry_date: Date.current)
    return if is_void?

    transaction do
      reversing = company.journal_entries.build(
        entry_date: entry_date,
        memo: "VOID: #{memo}",
        source_type: 'auto',
        source_entity: source_entity,
        posted_by: user,
        locked: true  # Reversing entries can't be edited or voided
      )

      journal_entry_lines.each do |line|
        reversing.journal_entry_lines.build(
          chart_of_account_id: line.chart_of_account_id,
          debit_amount: line.credit_amount,
          credit_amount: line.debit_amount,
          memo: "VOID: #{line.memo}",
          location_id: line.location_id,
          department: line.department,
          contact_id: line.contact_id,
          deal_id: line.deal_id,
          vehicle_id: line.vehicle_id,
          project_id: line.project_id
        )
      end

      reversing.save!

      update!(
        is_void: true,
        voided_at: Time.current,
        voided_by: user,
        reversed_by: reversing
      )
    end
  end

  # One cost line per project for the expense this entry puts on it: paid when
  # it came out of the bank through Record Expense, otherwise on the books
  # (billed). A void or a removed tag takes the cost line away.
  def sync_project_job_cost
    linked = ProjectCostItem.not_deleted.where(company_id: company_id, journal_entry_id: id).to_a
    wanted = if is_void?
               {}
             else
               journal_entry_lines.reload.joins(:chart_of_account)
                                  .where(chart_of_accounts: { account_type: 'expense' })
                                  .where.not(project_id: nil)
                                  .group(:project_id)
                                  .sum('journal_entry_lines.debit_amount - journal_entry_lines.credit_amount')
                                  .transform_values(&:to_d)
             end

    status = source_type == 'quick_entry' ? 'paid' : 'approved'
    description = (memo.presence || "Journal entry #{entry_number}").truncate(250)
    linked.each do |item|
      amount = wanted.delete(item.project_id)
      if amount&.positive?
        attrs = { amount: amount, date: entry_date, description: description }
        item.update!(attrs) if attrs.any? { |k, v| item[k] != v }
      else
        item.update!(is_deleted: true)
      end
    end

    wanted.each do |project_id, amount|
      next unless amount.positive?

      ProjectCostItem.create!(
        company_id: company_id, project_id: project_id, journal_entry_id: id,
        cost_type: 'other', description: description, amount: amount, date: entry_date,
        status: status, paid_at: status == 'paid' ? Time.current : nil,
        metadata: { 'source' => source_type }
      )
    end
  end

  def drop_project_job_cost
    ProjectCostItem.not_deleted.where(company_id: company_id, journal_entry_id: id).find_each { |item| item.update!(is_deleted: true) }
  end

  def total_debits
    journal_entry_lines.sum(:debit_amount)
  end

  def total_credits
    journal_entry_lines.sum(:credit_amount)
  end

  def self.reportable_config
    {
      label: 'Journal Entries',
      fields: [
        { key: 'id',             label: 'ID',             type: 'number',  filterable: true,  sortable: true },
        { key: 'entry_number',   label: 'Entry #',        type: 'string',  filterable: true,  sortable: true },
        { key: 'entry_date',     label: 'Date',           type: 'date',    filterable: true,  sortable: true },
        { key: 'memo',           label: 'Memo',           type: 'string',  filterable: true,  sortable: false },
        { key: 'source_type',    label: 'Source',         type: 'string',  filterable: true,  sortable: true },
        { key: 'is_void',        label: 'Voided',         type: 'boolean', filterable: true,  sortable: true },
        { key: 'fiscal_year',    label: 'Fiscal Year',    type: 'number',  filterable: true,  sortable: true },
        { key: 'fiscal_period',  label: 'Fiscal Period',  type: 'number',  filterable: true,  sortable: true },
        { key: 'created_at',     label: 'Created',        type: 'date',    filterable: true,  sortable: true },
      ]
    }
  end
end
