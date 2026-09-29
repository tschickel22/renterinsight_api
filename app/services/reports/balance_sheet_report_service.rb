# frozen_string_literal: true

module Reports
  class BalanceSheetReportService
    def initialize(company)
      @company = company
    end

    def generate(as_of_date: Date.current, location_id: nil, basis: 'accrual')
      balance_service = AccountBalanceService.new(@company)
      raw_balances = balance_service.all_balances(as_of_date: as_of_date, location_id: location_id, basis: basis)

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
          account_name: account.name,
          sub_type: account.sub_type,
          amount: net
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
        location_id: location_id,
        basis: basis
      )

      if pnl[:net_income] != 0
        equity << {
          account_id: nil,
          account_number: '',
          account_name: 'Current Year Earnings',
          sub_type: 'retained_earnings',
          amount: pnl[:net_income],
          is_calculated: true
        }
      end

      # Profit from earlier fiscal years that was never closed into Retained
      # Earnings. Asset and liability balances are all-time, but the line
      # above only adds this fiscal year's profit, so without this every year
      # nobody ran Year-End Close left the sheet out by that year's income
      # (RI-00004 was out by exactly its FY2025 net income). Closed years net
      # to zero here, because the closing entry clears their revenue and
      # expense into the Retained Earnings account already counted above.
      prior_unclosed = prior_years_unclosed_income(fy_start, location_id: location_id, basis: basis)
      if prior_unclosed != 0
        equity << {
          account_id: nil,
          account_number: '',
          account_name: 'Retained Earnings (prior years, not closed)',
          sub_type: 'retained_earnings',
          amount: prior_unclosed,
          is_calculated: true
        }
      end

      total_assets = assets.sum { |r| r[:amount] }
      total_liabilities = liabilities.sum { |r| r[:amount] }
      total_equity = equity.sum { |r| r[:amount] }

      {
        as_of_date: as_of_date,
        location_id: location_id,
        basis: basis,
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

    private

    # Net income from the first entry through the day before this fiscal
    # year, closing entries included, so only unclosed years remain.
    def prior_years_unclosed_income(fy_start, location_id:, basis:)
      first_entry = @company.journal_entries.where(is_void: false).minimum(:entry_date)
      return BigDecimal('0') if first_entry.nil? || first_entry >= fy_start

      ProfitAndLossReportService.new(@company).generate(
        start_date: first_entry,
        end_date: fy_start - 1.day,
        location_id: location_id,
        basis: basis
      )[:net_income]
    end
  end
end
