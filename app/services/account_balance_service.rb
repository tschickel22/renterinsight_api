# frozen_string_literal: true

class AccountBalanceService
  def initialize(company)
    @company = company
  end

  def balance_as_of(account, as_of_date, location_id: nil, department: nil)
    lines = JournalEntryLine
      .joins(:journal_entry)
      .where(
        journal_entries: { company_id: @company.id, is_void: false },
        chart_of_account_id: account.id
      )
      .where('journal_entries.entry_date <= ?', as_of_date)

    lines = lines.where(location_id: location_id) if location_id
    lines = lines.where(department: department) if department

    total_debits = lines.sum(:debit_amount)
    total_credits = lines.sum(:credit_amount)

    net = if account.normal_balance == 'debit'
      total_debits - total_credits
    else
      total_credits - total_debits
    end

    # Include opening balance from COA (set during initial setup/migration)
    opening = account.opening_balance || 0
    opening_date = account.opening_balance_date
    if opening != 0 && (opening_date.nil? || opening_date <= as_of_date)
      net + opening
    else
      net
    end
  end

  def all_balances(as_of_date: Date.current, location_id: nil, department: nil)
    scope = JournalEntryLine
      .joins(:journal_entry)
      .where(journal_entries: { company_id: @company.id, is_void: false })
      .where('journal_entries.entry_date <= ?', as_of_date)

    scope = scope.where(location_id: location_id) if location_id
    scope = scope.where(department: department) if department

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
      # Add opening balance as a debit or credit depending on normal balance
      if normal_bal == 'debit'
        balances[acct_id][:total_debits] += opening
      else
        balances[acct_id][:total_credits] += opening
      end
    end

    balances
  end

  def period_balances(start_date:, end_date:, location_id: nil, department: nil)
    scope = JournalEntryLine
      .joins(:journal_entry)
      .where(journal_entries: { company_id: @company.id, is_void: false })
      .where(journal_entries: { entry_date: start_date..end_date })

    scope = scope.where(location_id: location_id) if location_id
    scope = scope.where(department: department) if department

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
end
