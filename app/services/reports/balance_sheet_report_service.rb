# frozen_string_literal: true

module Reports
  class BalanceSheetReportService
    def initialize(company)
      @company = company
    end

    def generate(as_of_date: Date.current, location_id: nil)
      balance_service = AccountBalanceService.new(@company)
      raw_balances = balance_service.all_balances(as_of_date: as_of_date, location_id: location_id)

      accounts = @company.chart_of_accounts.active.postable.ordered

      assets = []
      liabilities = []
      equity = []

      accounts.each do |account|
        bal = raw_balances[account.id]
        next unless bal

        net = if account.normal_balance == 'debit'
                bal[:total_debits] - bal[:total_credits]
              else
                bal[:total_credits] - bal[:total_debits]
              end

        next if net.zero?

        row = {
          account_id: account.id,
          account_number: account.account_number,
          name: account.name,
          sub_type: account.sub_type,
          balance: net
        }

        case account.account_type
        when 'asset' then assets << row
        when 'liability' then liabilities << row
        when 'equity' then equity << row
        end
      end

      settings = AccountingSettings.for_company(@company)
      fy_start_month = settings&.fiscal_year_start_month || 1
      fy_start = if as_of_date.month >= fy_start_month
                   Date.new(as_of_date.year, fy_start_month, 1)
                 else
                   Date.new(as_of_date.year - 1, fy_start_month, 1)
                 end

      pnl = ProfitAndLossReportService.new(@company).generate(
        start_date: fy_start,
        end_date: as_of_date,
        location_id: location_id
      )

      if pnl[:net_income] != 0
        equity << {
          account_id: nil,
          account_number: '',
          name: 'Current Year Earnings',
          sub_type: 'retained_earnings',
          balance: pnl[:net_income],
          is_calculated: true
        }
      end

      total_assets = assets.sum { |r| r[:balance] }
      total_liabilities = liabilities.sum { |r| r[:balance] }
      total_equity = equity.sum { |r| r[:balance] }

      {
        as_of_date: as_of_date,
        location_id: location_id,
        assets: assets,
        total_assets: total_assets,
        liabilities: liabilities,
        total_liabilities: total_liabilities,
        equity: equity,
        total_equity: total_equity,
        total_liabilities_and_equity: total_liabilities + total_equity,
        is_balanced: total_assets == (total_liabilities + total_equity)
      }
    end
  end
end
