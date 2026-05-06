# frozen_string_literal: true

module Reports
  class CashFlowStatementReportService
    def initialize(company)
      @company = company
    end

    def generate(start_date:, end_date:, location_id: nil)
      balance_service = AccountBalanceService.new(@company)

      pnl = ProfitAndLossReportService.new(@company).generate(
        start_date: start_date, end_date: end_date, location_id: location_id
      )
      net_income = pnl[:net_income]

      period_balances = balance_service.period_balances(
        start_date: start_date, end_date: end_date, location_id: location_id
      )
      accounts = @company.chart_of_accounts.active.postable.ordered.index_by(&:id)

      operating_adjustments = []

      accounts.each do |id, account|
        next unless account.sub_type == 'accumulated_depreciation' || account.name.downcase.include?('depreciation')
        bal = period_balances[id]
        next unless bal
        dep_amount = bal[:total_credits] - bal[:total_debits]
        next if dep_amount.zero?
        operating_adjustments << { name: account.name, amount: dep_amount, type: 'add_back' }
      end

      working_capital_types = %w[accounts_receivable accounts_payable inventory prepaid]
      accounts.each do |id, account|
        next unless account.sub_type.in?(working_capital_types)
        bal = period_balances[id]
        next unless bal

        change = if account.normal_balance == 'debit'
                   bal[:total_debits] - bal[:total_credits]
                 else
                   bal[:total_credits] - bal[:total_debits]
                 end
        next if change.zero?

        cash_impact = account.account_type == 'asset' ? -change : change

        operating_adjustments << {
          name: "Change in #{account.name}",
          amount: cash_impact,
          type: account.account_type == 'asset' ? 'working_capital_asset' : 'working_capital_liability'
        }
      end

      total_operating = net_income + operating_adjustments.sum { |a| a[:amount] }

      investing = []
      accounts.each do |id, account|
        next unless account.sub_type == 'fixed_asset'
        bal = period_balances[id]
        next unless bal
        change = bal[:total_debits] - bal[:total_credits]
        next if change.zero?
        investing << { name: account.name, amount: -change }
      end
      total_investing = investing.sum { |i| i[:amount] }

      financing = []
      accounts.each do |id, account|
        next unless account.sub_type.in?(%w[long_term_liability owners_equity]) ||
                    account.name.downcase.include?('notes payable') ||
                    account.name.downcase.include?("owner's draw")
        bal = period_balances[id]
        next unless bal
        change = if account.normal_balance == 'credit'
                   bal[:total_credits] - bal[:total_debits]
                 else
                   -(bal[:total_debits] - bal[:total_credits])
                 end
        next if change.zero?
        financing << { name: account.name, amount: change }
      end
      total_financing = financing.sum { |f| f[:amount] }

      net_change = total_operating + total_investing + total_financing

      cash_accounts = @company.chart_of_accounts.where(sub_type: 'bank', is_active: true)
      beginning_cash = cash_accounts.sum { |a| balance_service.balance_as_of(a, start_date - 1.day, location_id: location_id) }
      ending_cash = beginning_cash + net_change

      {
        period: { start_date: start_date, end_date: end_date },
        operating: {
          net_income: net_income,
          adjustments: operating_adjustments,
          total: total_operating
        },
        investing: { items: investing, total: total_investing },
        financing: { items: financing, total: total_financing },
        net_change_in_cash: net_change,
        beginning_cash: beginning_cash,
        ending_cash: ending_cash
      }
    end
  end
end
