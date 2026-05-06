# frozen_string_literal: true

class BankTransaction < ApplicationRecord
  belongs_to :company
  belongs_to :bank_account
  belongs_to :matched_journal_entry, class_name: 'JournalEntry', optional: true
  belongs_to :category_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :rule, class_name: 'BankRule', optional: true
  belongs_to :contact, optional: true

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

  def match_to_journal_entry!(je, source: 'manual')
    update!(
      matched_journal_entry: je,
      matched_at: Time.current,
      matched_by: source,
      status: 'matched'
    )
  end

  def categorize!(account:, contact: nil, memo: nil, create_je: false, source: 'manual')
    update!(
      category_account: account,
      contact: contact,
      memo: memo || self.memo,
      status: 'matched',
      matched_at: Time.current,
      matched_by: source
    )

    if create_je
      create_journal_entry_from_categorization!
    end
  end

  def exclude!(reason: nil)
    update!(
      status: 'excluded',
      excluded_reason: reason
    )
  end

  def unmatch!
    update!(
      status: 'unmatched',
      matched_journal_entry: nil,
      matched_at: nil,
      matched_by: nil,
      category_account: nil,
      rule: nil
    )
  end

  def create_journal_entry_from_categorization!
    return unless category_account.present?

    bank_gl_account = bank_account.chart_of_account
    return unless bank_gl_account

    posting_service = Accounting::ManualPostingService.new(company)

    je = if deposit?
           posting_service.post_simple!(
             debit_account: bank_gl_account,
             credit_account: category_account,
             amount: amount.abs,
             memo: memo.presence || description,
             entry_date: transaction_date,
             source_entity: self,
             contact_id: contact_id
           )
         else
           posting_service.post_simple!(
             debit_account: category_account,
             credit_account: bank_gl_account,
             amount: amount.abs,
             memo: memo.presence || description,
             entry_date: transaction_date,
             source_entity: self,
             contact_id: contact_id
           )
         end

    if je
      update!(matched_journal_entry: je, matched_at: Time.current)
    end

    je
  end
end
