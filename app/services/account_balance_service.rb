# frozen_string_literal: true

class AccountBalanceService
  CASH_SUB_TYPES = %w[bank cash checking savings].freeze

  def initialize(company)
    @company = company
  end

  def balance_as_of(account, as_of_date, location_id: nil, department: nil, basis: 'accrual')
    lines = JournalEntryLine
      .joins(:journal_entry)
      .where(
        journal_entries: { company_id: @company.id, is_void: false },
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

    # Include opening balance from COA (set during initial setup/migration).
    # Opening balances apply on both bases — they represent prior cash + accrual position.
    opening = account.opening_balance || 0
    opening_date = account.opening_balance_date
    if opening != 0 && (opening_date.nil? || opening_date <= as_of_date)
      net + opening
    else
      net
    end
  end

  def all_balances(as_of_date: Date.current, location_id: nil, department: nil, basis: 'accrual')
    scope = JournalEntryLine
      .joins(:journal_entry)
      .where(journal_entries: { company_id: @company.id, is_void: false })
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

    # Merge opening balances from COA records
    opening_balances = @company.chart_of_accounts
      .where('opening_balance IS NOT NULL AND opening_balance != 0')
      .where('opening_balance_date IS NULL OR opening_balance_date <= ?', as_of_date)
      .pluck(:id, :opening_balance, :normal_balance)

    opening_balances.each do |acct_id, opening, normal_bal|
      balances[acct_id] ||= { total_debits: BigDecimal('0'), total_credits: BigDecimal('0') }
      if normal_bal == 'debit'
        balances[acct_id][:total_debits] += opening
      else
        balances[acct_id][:total_credits] += opening
      end
    end

    balances
  end

  def period_balances(start_date:, end_date:, location_id: nil, department: nil, basis: 'accrual')
    scope = JournalEntryLine
      .joins(:journal_entry)
      .where(journal_entries: { company_id: @company.id, is_void: false })
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
    return [] if cash_account_ids.empty?

    JournalEntryLine
      .joins(:journal_entry)
      .where(journal_entries: { company_id: @company.id, is_void: false })
      .where(chart_of_account_id: cash_account_ids)
      .where('journal_entries.entry_date <= ?', as_of_date)
      .distinct
      .pluck('journal_entries.id')
  end

  def cash_basis_je_ids_in_range(start_date, end_date)
    return [] if cash_account_ids.empty?

    JournalEntryLine
      .joins(:journal_entry)
      .where(journal_entries: { company_id: @company.id, is_void: false })
      .where(chart_of_account_id: cash_account_ids)
      .where(journal_entries: { entry_date: start_date..end_date })
      .distinct
      .pluck('journal_entries.id')
  end
end
