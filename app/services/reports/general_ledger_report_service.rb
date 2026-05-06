# frozen_string_literal: true

module Reports
  class GeneralLedgerReportService
    def initialize(company)
      @company = company
    end

    def generate(account_id:, start_date:, end_date:, location_id: nil)
      account = @company.chart_of_accounts.find(account_id)

      lines = JournalEntryLine
        .joins(:journal_entry)
        .includes(journal_entry: :posted_by)
        .where(
          chart_of_account_id: account.id,
          journal_entries: { company_id: @company.id, is_void: false }
        )
        .where(journal_entries: { entry_date: start_date..end_date })
        .order('journal_entries.entry_date ASC, journal_entries.entry_number ASC')

      lines = lines.where(location_id: location_id) if location_id

      balance_service = AccountBalanceService.new(@company)
      opening_balance = balance_service.balance_as_of(account, start_date - 1.day, location_id: location_id)

      running_balance = opening_balance
      transactions = lines.map do |line|
        if account.normal_balance == 'debit'
          running_balance += (line.debit_amount - line.credit_amount)
        else
          running_balance += (line.credit_amount - line.debit_amount)
        end

        {
          date: line.journal_entry.entry_date,
          entry_number: line.journal_entry.entry_number,
          memo: line.memo.presence || line.journal_entry.memo,
          source_type: line.journal_entry.source_type,
          debit: line.debit_amount.zero? ? nil : line.debit_amount,
          credit: line.credit_amount.zero? ? nil : line.credit_amount,
          balance: running_balance,
          journal_entry_id: line.journal_entry_id,
          posted_by: line.journal_entry.posted_by&.email
        }
      end

      {
        account: {
          id: account.id,
          account_number: account.account_number,
          name: account.name,
          account_type: account.account_type,
          normal_balance: account.normal_balance
        },
        period: { start_date: start_date, end_date: end_date },
        opening_balance: opening_balance,
        closing_balance: running_balance,
        transactions: transactions,
        total_debits: lines.sum(:debit_amount),
        total_credits: lines.sum(:credit_amount)
      }
    end
  end
end
