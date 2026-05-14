# frozen_string_literal: true

module Reports
  class ProfitAndLossReportService
    def initialize(company)
      @company = company
    end

    def generate(start_date:, end_date:, location_id: nil, department: nil, compare_prior: false, basis: 'accrual')
      balance_service = AccountBalanceService.new(@company)
      period_balances = balance_service.period_balances(
        start_date: start_date,
        end_date: end_date,
        location_id: location_id,
        department: department,
        basis: basis
      )

      accounts = @company.chart_of_accounts.active.postable.ordered

      revenue_rows = []
      cogs_rows = []
      expense_rows = []

      accounts.each do |account|
        bal = period_balances[account.id]
        next unless bal

        case account.account_type
        when 'revenue'
          net = bal[:total_credits] - bal[:total_debits]
          next if net.zero?
          revenue_rows << {
            account_id: account.id,
            account_number: account.account_number,
            account_name: account.name,
            sub_type: account.sub_type,
            amount: net
          }
        when 'expense'
          net = bal[:total_debits] - bal[:total_credits]
          next if net.zero?
          target = account.sub_type == 'cost_of_goods_sold' ? cogs_rows : expense_rows
          target << {
            account_id: account.id,
            account_number: account.account_number,
            account_name: account.name,
            sub_type: account.sub_type,
            amount: net
          }
        end
      end

      total_revenue = revenue_rows.sum { |r| r[:amount] }
      total_cogs = cogs_rows.sum { |r| r[:amount] }
      gross_profit = total_revenue - total_cogs
      total_expenses = expense_rows.sum { |r| r[:amount] }
      net_income = gross_profit - total_expenses

      result = {
        period: { start_date: start_date, end_date: end_date },
        location_id: location_id,
        department: department,
        basis: basis,
        revenue: revenue_rows,
        total_revenue: total_revenue,
        cogs: cogs_rows,
        total_cogs: total_cogs,
        gross_profit: gross_profit,
        gross_margin: total_revenue.zero? ? 0 : (gross_profit / total_revenue * 100).round(2),
        expenses: expense_rows,
        total_expenses: total_expenses,
        net_income: net_income,
        net_margin: total_revenue.zero? ? 0 : (net_income / total_revenue * 100).round(2)
      }

      if compare_prior
        period_length = (end_date - start_date).to_i
        prior_start = start_date - period_length.days - 1.day
        prior_end = start_date - 1.day

        prior = generate(
          start_date: prior_start,
          end_date: prior_end,
          location_id: location_id,
          department: department,
          compare_prior: false,
          basis: basis
        )

        result[:prior_period] = prior
        result[:revenue_change] = total_revenue - prior[:total_revenue]
        result[:net_income_change] = net_income - prior[:net_income]
        result[:revenue_change_pct] = prior[:total_revenue].zero? ? nil : ((total_revenue - prior[:total_revenue]) / prior[:total_revenue] * 100).round(2)
      end

      result
    end
  end
end
