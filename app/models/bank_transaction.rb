# frozen_string_literal: true

class BankTransaction < ApplicationRecord
  include Reportable

  belongs_to :company
  belongs_to :bank_account
  belongs_to :matched_journal_entry, class_name: 'JournalEntry', optional: true
  belongs_to :category_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :rule, class_name: 'BankRule', optional: true
  belongs_to :contact, optional: true
  # E99: what the line was booked to. A project (and phase and vendor) on a
  # categorized line; a deal or invoice when a deposit was applied as a
  # payment, with the cash receipt that applying made.
  belongs_to :project, optional: true
  belongs_to :project_phase, optional: true
  belongs_to :vendor, optional: true
  belongs_to :deal, optional: true
  belongs_to :invoice, optional: true
  belongs_to :cash_receipt, optional: true

  STATUSES = %w[unmatched matched excluded reconciled].freeze
  MATCH_SOURCES = %w[auto manual rule].freeze
  TRANSACTION_TYPES = %w[debit credit check transfer fee interest payment deposit].freeze

  validates :transaction_date, presence: true
  validates :amount, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :fitid, uniqueness: { scope: :bank_account_id, allow_nil: true }
  validates :stripe_txn_id, uniqueness: true, allow_nil: true

  scope :unmatched, -> { where(status: 'unmatched') }
  scope :matched, -> { where(status: 'matched') }
  scope :excluded, -> { where(status: 'excluded') }
  scope :reconciled, -> { where(status: 'reconciled') }
  scope :deposits, -> { where('amount > 0') }
  scope :withdrawals, -> { where('amount < 0') }
  scope :for_date_range, ->(start_date, end_date) { where(transaction_date: start_date..end_date) }
  scope :ordered, -> { order(transaction_date: :desc, created_at: :desc) }

  def deposit?
    amount.present? && amount > 0
  end

  def withdrawal?
    amount.present? && amount < 0
  end

  def matched?
    status == 'matched' || status == 'reconciled'
  end

  def excluded?
    status == 'excluded'
  end

  def self.reportable_config
    {
      label: 'Bank Transactions',
      fields: [
        { key: 'id',                label: 'ID',              type: 'number',  filterable: true,  sortable: true },
        { key: 'transaction_date',  label: 'Date',            type: 'date',    filterable: true,  sortable: true },
        { key: 'description',       label: 'Description',     type: 'string',  filterable: true,  sortable: false },
        { key: 'amount',            label: 'Amount',          type: 'number',  filterable: true,  sortable: true },
        { key: 'transaction_type',  label: 'Type',            type: 'enum',    filterable: true,  sortable: true },
        { key: 'status',            label: 'Status',          type: 'enum',    filterable: true,  sortable: true },
        { key: 'payee_name',        label: 'Payee',           type: 'string',  filterable: true,  sortable: true },
        { key: 'check_number',      label: 'Check #',         type: 'string',  filterable: true,  sortable: false },
        { key: 'memo',              label: 'Memo',            type: 'string',  filterable: true,  sortable: false },
        { key: 'created_at',        label: 'Imported',        type: 'date',    filterable: true,  sortable: true },
      ]
    }
  end

  def match_to_journal_entry!(je, source: 'manual')
    update!(
      matched_journal_entry: je,
      matched_at: Time.current,
      matched_by: source,
      status: 'matched'
    )
  end

  # Raised when a line cannot be booked. Nothing is saved: a line marked
  # categorized with no entry behind it looks done in the feed while the
  # money is missing from the books. Factory Direct had 119 of those.
  class PostingError < StandardError; end

  # Raised when the money is already in the books as an entry nobody linked
  # to this line. Categorizing would post it a second time; matching the
  # line to that entry is what is wanted.
  class AlreadyBooked < StandardError
    attr_reader :entries

    def initialize(entries)
      @entries = entries
      first = entries.first
      super("This transaction is already in the books as entry #{first.entry_number} on " \
            "#{first.entry_date&.strftime('%m/%d/%Y')}. Match it to that entry instead of categorizing, " \
            'or it would be counted twice.')
    end
  end

  # Books the line to an account. With create_je (what the Categorize panel
  # sends), the entry is posted in the same transaction, and if it cannot be
  # posted nothing changes. Re-categorizing a line this replaces the entry
  # its earlier categorization posted (voided, as the app voids entries).
  def categorize!(account:, contact: nil, memo: nil, create_je: false, source: 'manual',
                  project: nil, project_phase: nil, vendor: nil)
    if project_phase && project_phase.project_id != project&.id
      raise PostingError, 'That phase is not on the project picked.'
    end
    raise PostingError, 'This line was applied as a payment. Unmatch it before categorizing.' if cash_receipt_id.present?

    transaction do
      previous = matched_journal_entry
      if previous && !posted_by_categorization?(previous)
        raise PostingError, "This transaction is matched to entry #{previous.entry_number}. Unmatch it before categorizing."
      end
      if create_je && previous.nil?
        booked = BankTransactionMatchingService.new(company).booked_entries(self)
        raise AlreadyBooked, booked if booked.any?
      end

      previous&.void!(Current.user) unless previous&.is_void?
      # Income on a job with a deal names the deal's customer when no one else is picked.
      contact ||= project&.deal&.contact if deposit?
      update!(
        category_account: account,
        contact: contact,
        memo: memo || self.memo,
        project: project,
        project_phase: project_phase,
        vendor: vendor,
        deal_id: project&.deal_id,
        status: 'matched',
        matched_journal_entry: nil,
        matched_at: Time.current,
        matched_by: source
      )

      create_journal_entry_from_categorization! if create_je
    end
  end

  # E99: a deposit that is a customer's or lender's payment. On a deal it goes
  # through DealPaymentService (applied to the deal invoice, filling draws in
  # order, or held as a deposit before approval); on any other open invoice it
  # is a cash receipt applied to that invoice. Either way the receipt is made
  # in this bank account on the line's date and the line is matched to its
  # entry, so the money is in the books once. Unmatch voids the receipt.
  def apply_payment!(deal: nil, invoice: nil, memo: nil, user: nil, source: 'manual')
    raise PostingError, 'Only a deposit can be applied as a payment.' unless deposit?
    raise PostingError, 'Pick a deal or an invoice.' unless deal || invoice
    raise PostingError, 'Unmatch this line before applying it.' if matched_journal_entry_id.present? || cash_receipt_id.present?

    booked = BankTransactionMatchingService.new(company).booked_entries(self)
    raise AlreadyBooked, booked if booked.any?

    receipt = nil
    transaction do
      if deal && invoice.nil?
        service = DealPaymentService.new(deal, user: user)
        entry = service.build_entry(amount: amount.abs, payment_date: transaction_date.to_s, payment_method: 'ach',
                                    bank_account_id: bank_account_id, reference_number: reference_number.presence,
                                    memo: memo.presence)
        receipt = service.record!(entry)
      else
        raise PostingError, 'That invoice is paid already.' unless invoice.amount_due.to_d.positive?
        problem = DealPaymentService.bank_problem(company, bank_account)
        raise PostingError, problem if problem

        applied = [amount.abs, invoice.amount_due.to_d].min
        receipt = company.cash_receipts.build(
          contact_id: invoice.contact_id,
          account_id: invoice.recipient_type == 'Account' ? invoice.recipient_id : nil,
          project_id: invoice.source_type == 'Project' ? invoice.source_id : nil,
          bank_account: bank_account, receipt_date: transaction_date, amount: amount.abs,
          payment_method: 'ach', reference_number: reference_number.presence,
          memo: memo.presence || "Payment on invoice #{invoice.invoice_number}",
          location_id: invoice.location_id || bank_account.try(:location_id),
          status: CashReceipt::STATUS_POSTED
        )
        receipt.created_by_id = user&.id
        receipt.cash_receipt_applications.build(invoice_id: invoice.id, amount_applied: applied)
        receipt.amount_applied = applied
        receipt.amount_unapplied = amount.abs - applied
        receipt.save!
      end
      je = receipt.reload.journal_entry
      raise PostingError, 'The payment was recorded but its entry could not be posted. Check the bank account is linked to a ledger account.' unless je

      applied_invoice = invoice || receipt.cash_receipt_applications.first&.invoice
      update!(
        cash_receipt: receipt, deal: deal || applied_invoice&.deal || (applied_invoice && company.deals.find_by(deal_invoice_id: applied_invoice.id)), invoice: applied_invoice,
        project_id: receipt.project_id, contact_id: receipt.contact_id || contact_id,
        memo: memo.presence || self.memo, category_account: nil,
        matched_journal_entry: je, matched_at: Time.current, matched_by: source, status: 'matched'
      )
    end
    receipt
  rescue DealPaymentService::Error => e
    raise PostingError, e.message
  end

  def exclude!(reason: nil)
    update!(
      status: 'excluded',
      excluded_reason: reason
    )
  end

  # An entry this line's categorization posted is voided with it, or it
  # would stay in the books and be posted again on the next categorize. An
  # entry the line was only matched to (booked another way) is left alone.
  def unmatch!
    transaction do
      je = matched_journal_entry
      je.void!(Current.user) if je && posted_by_categorization?(je) && !je.is_void?
      # A payment this line applied was made by the line, so it goes with it.
      cash_receipt.void! if cash_receipt && cash_receipt.status != CashReceipt::STATUS_VOIDED
      update!(
        status: 'unmatched',
        matched_journal_entry: nil,
        matched_at: nil,
        matched_by: nil,
        category_account: nil,
        rule: nil,
        project: nil, project_phase: nil, vendor: nil, deal: nil, invoice: nil, cash_receipt: nil
      )
    end
  end

  def posted_by_categorization?(je)
    je.source_entity_type == 'BankTransaction' && je.source_entity_id == id
  end

  def create_journal_entry_from_categorization!
    raise PostingError, 'Pick an account to categorize to.' unless category_account.present?

    bank_gl_account = bank_account.chart_of_account
    unless bank_gl_account
      raise PostingError, 'This bank account is not linked to a GL account, so nothing can be posted. ' \
                          'Link it under Accounting, Bank Accounts first.'
    end

    je_location_id = bank_account.try(:location_id) ||
                     (Current.location_id if Current.respond_to?(:location_id))
    entry_memo = memo.presence || description
    # The category line names the job (and its deal and the customer or
    # vendor); the bank line stays plain, as Record Expense does it.
    tags = { contact_id: contact_id, project_id: project_id, deal_id: project&.deal_id }
    je = company.journal_entries.build(
      entry_date: transaction_date, memo: entry_memo, source_type: 'auto', source_entity: self,
      posted_by: Current.user
    )
    # A project's cost line names who was paid and the phase (E87 job cost).
    je.job_cost_vendor = vendor
    je.job_cost_phase_id = project_phase_id
    je.job_cost_description = memo.presence || description
    bank_line = { chart_of_account: bank_gl_account, memo: entry_memo, location_id: je_location_id }
    cat_line = { chart_of_account: category_account, memo: entry_memo, location_id: je_location_id, **tags }
    if deposit?
      je.journal_entry_lines.build(bank_line.merge(debit_amount: amount.abs, credit_amount: 0))
      je.journal_entry_lines.build(cat_line.merge(debit_amount: 0, credit_amount: amount.abs))
    else
      je.journal_entry_lines.build(cat_line.merge(debit_amount: amount.abs, credit_amount: 0))
      je.journal_entry_lines.build(bank_line.merge(debit_amount: 0, credit_amount: amount.abs))
    end
    unless je.save
      raise PostingError, "The journal entry could not be posted: #{je.errors.full_messages.join(', ')}"
    end

    update!(matched_journal_entry: je, matched_at: Time.current)
    je
  end
end
