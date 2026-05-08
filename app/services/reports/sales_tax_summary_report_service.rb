# frozen_string_literal: true

module Reports
  class SalesTaxSummaryReportService
    def initialize(company)
      @company = company
    end

    def generate(start_date:, end_date:, location_id: nil, basis: 'accrual')
      tax_accounts = @company.chart_of_accounts
        .where(account_type: 'liability', is_active: true)
        .where(
          "account_number IN (?) OR name ILIKE ?",
          ['2210', '2220', '2230'],
          '%sales tax%'
        )

      balance_service = AccountBalanceService.new(@company)
      period_data = balance_service.period_balances(
        start_date: start_date, end_date: end_date, location_id: location_id, basis: basis
      )

      rows = tax_accounts.map do |account|
        bal = period_data[account.id]
        next unless bal

        collected = bal[:total_credits] - bal[:total_debits]
        next if collected.zero?

        {
          account_id: account.id,
          account_number: account.account_number,
          account_name: account.name,
          tax_collected: collected,
          jurisdiction: account.name.gsub(/Sales Tax[- ]*/i, '').strip
        }
      end.compact

      total_collected = rows.sum { |r| r[:tax_collected] }

      {
        period: { start_date: start_date, end_date: end_date },
        location_id: location_id,
        basis: basis,
        jurisdictions: rows,
        total_collected: total_collected
      }
    end
  end
end
