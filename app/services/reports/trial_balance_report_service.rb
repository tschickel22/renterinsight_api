# frozen_string_literal: true

module Reports
  class TrialBalanceReportService
    def initialize(company)
      @company = company
    end

    def generate(as_of_date: Date.current, location_id: nil, department: nil)
      balance_service = AccountBalanceService.new(@company)
      raw_balances = balance_service.all_balances(
        as_of_date: as_of_date,
        location_id: location_id,
        department: department
      )

      accounts = @company.chart_of_accounts.active.postable.ordered

      rows = []
      total_debits = BigDecimal('0')
      total_credits = BigDecimal('0')

      accounts.each do |account|
        bal = raw_balances[account.id]
        next unless bal

        debit_balance = BigDecimal('0')
        credit_balance = BigDecimal('0')

        if account.normal_balance == 'debit'
          net = bal[:total_debits] - bal[:total_credits]
          net >= 0 ? debit_balance = net : credit_balance = net.abs
        else
          net = bal[:total_credits] - bal[:total_debits]
          net >= 0 ? credit_balance = net : debit_balance = net.abs
        end

        next if debit_balance.zero? && credit_balance.zero?

        total_debits += debit_balance
        total_credits += credit_balance

        rows << {
          account_id: account.id,
          account_number: account.account_number,
          account_name: account.name,
          account_type: account.account_type,
          debit_balance: debit_balance,
          credit_balance: credit_balance
        }
      end

      {
        as_of_date: as_of_date,
        location_id: location_id,
        department: department,
        rows: rows,
        total_debits: total_debits,
        total_credits: total_credits,
        is_balanced: total_debits == total_credits
      }
    end
  end
end
