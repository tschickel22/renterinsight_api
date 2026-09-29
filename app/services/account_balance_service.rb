# frozen_string_literal: true

class AccountBalanceService
  CASH_SUB_TYPES = %w[bank cash checking savings].freeze

  def initialize(company)
    @company = company
  end

  def balance_as_of(account, as_of_date, location_id: nil, department: nil, basis: 'accrual')
    lines = JournalEntryLine
      .joins(:journal_entry)
      .merge(JournalEntry.in_ledger)
      .where(
        journal_entries: { company_id: @company.id },
        chart_of_account_id: account.id
      )
      .where('journal_entries.entry_date <= ?', as_of_date)

    lines = lines.where(location_id: location_id) if location_id
    lines = lines.where(department: department) if department

    if basis.to_s == 'cash'
      cash_je_ids = cash_basis_je_ids_through(as_of_date)
      lines = cash_je_ids.any? ? lines.where(journal_entries: { id: cash_je_ids }) : lines.none
    end

    total_debits = lines.sum(:debit_amount)
    total_credits = lines.sum(:credit_amount)

    net = if account.normal_balance == 'debit'
      total_debits - total_credits
    else
      total_credits - total_debits
    end

    # Opening balances are journal entries now (OpeningBalancePostingService)
    # and already in the lines above; one typed before that is still added here.
    legacy = legacy_opening_balances(as_of_date).find_by(id: account.id)
    legacy ? net + legacy.opening_balance : net
  end

  # Opening balances typed on accounts before they were posted as entries.
  # Still counted at report time, as they always were, until they're posted;
  # the balance sheet shows their other side as calculated Opening Balance
  # Equity so it balances without anyone writing to the ledger.
  def legacy_opening_balances(as_of_date)
    posted = JournalEntry.in_ledger.where(company_id: @company.id, source_entity_type: 'ChartOfAccount')
                         .select(:source_entity_id)
    @company.chart_of_accounts
            .where.not(opening_balance: [nil, 0])
            .where('opening_balance_date IS NULL OR opening_balance_date <= ?', as_of_date)
            .where.not(id: posted)
  end

  # Debit-side minus credit-side total of the legacy opening balances: the
  # equity credit that would balance them.
  def legacy_opening_offset(as_of_date)
    legacy_opening_balances(as_of_date).sum do |a|
      a.normal_balance == 'debit' ? a.opening_balance.to_d : -a.opening_balance.to_d
    end
  end

  def all_balances(as_of_date: Date.current, location_id: nil, department: nil, basis: 'accrual')
    scope = JournalEntryLine
      .joins(:journal_entry)
      .merge(JournalEntry.in_ledger)
      .where(journal_entries: { company_id: @company.id })
      .where('journal_entries.entry_date <= ?', as_of_date)

    scope = scope.where(location_id: location_id) if location_id
    scope = scope.where(department: department) if department

    if basis.to_s == 'cash'
      cash_je_ids = cash_basis_je_ids_through(as_of_date)
      scope = cash_je_ids.any? ? scope.where(journal_entries: { id: cash_je_ids }) : scope.none
    end

    raw = scope
      .group(:chart_of_account_id)
      .select(
        'chart_of_account_id',
        'SUM(debit_amount) as total_debits',
        'SUM(credit_amount) as total_credits'
      )

    balances = {}
    raw.each do |row|
      balances[row.chart_of_account_id] = {
        total_debits: row.total_debits,
        total_credits: row.total_credits
      }
    end

    legacy_opening_balances(as_of_date).pluck(:id, :opening_balance, :normal_balance).each do |acct_id, opening, normal_bal|
      balances[acct_id] ||= { total_debits: BigDecimal('0'), total_credits: BigDecimal('0') }
      side = normal_bal == 'debit' ? :total_debits : :total_credits
      balances[acct_id][side] += opening
    end

    balances
  end

  def period_balances(start_date:, end_date:, location_id: nil, department: nil, basis: 'accrual')
    scope = JournalEntryLine
      .joins(:journal_entry)
      .merge(JournalEntry.in_ledger)
      .where(journal_entries: { company_id: @company.id })
      .where(journal_entries: { entry_date: start_date..end_date })

    scope = scope.where(location_id: location_id) if location_id
    scope = scope.where(department: department) if department

    if basis.to_s == 'cash'
      cash_je_ids = cash_basis_je_ids_in_range(start_date, end_date)
      scope = cash_je_ids.any? ? scope.where(journal_entries: { id: cash_je_ids }) : scope.none
    end

    raw = scope
      .group(:chart_of_account_id)
      .select(
        'chart_of_account_id',
        'SUM(debit_amount) as total_debits',
        'SUM(credit_amount) as total_credits'
      )

    balances = {}
    raw.each do |row|
      balances[row.chart_of_account_id] = {
        total_debits: row.total_debits,
        total_credits: row.total_credits
      }
    end

    balances
  end

  # IDs of cash/bank accounts for this company. Used to identify JEs that
  # represent actual cash movement when filtering on cash basis.
  def cash_account_ids
    @cash_account_ids ||= @company.chart_of_accounts
      .where(account_type: 'asset')
      .where(
        "sub_type IN (?) OR sub_type ILIKE '%bank%' OR sub_type ILIKE '%cash%'",
        CASH_SUB_TYPES
      )
      .pluck(:id)
  end

  def cash_basis_je_ids_through(as_of_date)
    cash_ids = if cash_account_ids.empty?
                 []
               else
                 JournalEntryLine
                   .joins(:journal_entry)
                   .merge(JournalEntry.in_ledger)
                   .where(journal_entries: { company_id: @company.id })
                   .where(chart_of_account_id: cash_account_ids)
                   .where('journal_entries.entry_date <= ?', as_of_date)
                   .distinct
                   .pluck('journal_entries.id')
               end
    cash_ids | opening_balance_je_ids.where('entry_date <= ?', as_of_date).pluck(:id)
  end

  # Opening balances represent the prior position on both bases, as they did
  # when they were added at report time, whether or not they touch cash.
  def opening_balance_je_ids
    @company.journal_entries.in_ledger.where(source_entity_type: 'ChartOfAccount')
  end

  def cash_basis_je_ids_in_range(start_date, end_date)
    cash_ids = if cash_account_ids.empty?
                 []
               else
                 JournalEntryLine
                   .joins(:journal_entry)
                   .merge(JournalEntry.in_ledger)
                   .where(journal_entries: { company_id: @company.id })
                   .where(chart_of_account_id: cash_account_ids)
                   .where(journal_entries: { entry_date: start_date..end_date })
                   .distinct
                   .pluck('journal_entries.id')
               end
    cash_ids | opening_balance_je_ids.where(entry_date: start_date..end_date).pluck(:id)
  end
end
