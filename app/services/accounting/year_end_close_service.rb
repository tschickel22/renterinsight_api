# frozen_string_literal: true

module Accounting
  class YearEndCloseService
    def initialize(company)
      @company = company
    end

    def preview(fiscal_year)
      settings = AccountingSettings.for_company(@company)
      re_account = settings&.retained_earnings_account
      return { error: 'No Retained Earnings account configured. Go to Accounting Settings to set one.' } unless re_account

      balance_service = AccountBalanceService.new(@company)

      start_month = settings&.fiscal_year_start_month || 1
      fy_start = Date.new(fiscal_year, start_month, 1)
      fy_end = (fy_start + 1.year - 1.day)

      period_balances = balance_service.period_balances(start_date: fy_start, end_date: fy_end)

      accounts = @company.chart_of_accounts.active.postable.ordered
      lines = []

      accounts.each do |account|
        next unless account.account_type.in?(%w[revenue expense])
        bal = period_balances[account.id]
        next unless bal

        net = if account.normal_balance == 'debit'
                bal[:total_debits] - bal[:total_credits]
              else
                bal[:total_credits] - bal[:total_debits]
              end

        next if net.zero?

        lines << {
          accountId: account.id,
          accountNumber: account.account_number,
          accountName: account.name,
          accountType: account.account_type,
          debitAmount: account.account_type == 'expense' ? 0 : net,
          creditAmount: account.account_type == 'expense' ? net : 0,
        }
      end

      return { error: 'No revenue or expense activity to close for this fiscal year' } if lines.empty?

      net_income = lines.sum { |l| (l[:creditAmount] || 0) - (l[:debitAmount] || 0) }

      {
        fiscalYear: fiscal_year,
        periodStart: fy_start,
        periodEnd: fy_end,
        netIncome: net_income,
        retainedEarningsAccount: {
          id: re_account.id,
          accountNumber: re_account.account_number,
          name: re_account.name,
        },
        closingEntries: lines,
        totalAccountsClosed: lines.count,
      }
    end

    def close_year!(fiscal_year, user:)
      settings = AccountingSettings.for_company(@company)
      re_account = settings&.retained_earnings_account
      return { error: 'No Retained Earnings account configured' } unless re_account

      balance_service = AccountBalanceService.new(@company)

      start_month = settings&.fiscal_year_start_month || 1
      fy_start = Date.new(fiscal_year, start_month, 1)
      fy_end = (fy_start + 1.year - 1.day)

      period_balances = balance_service.period_balances(start_date: fy_start, end_date: fy_end)

      accounts = @company.chart_of_accounts.active.postable.ordered
      lines = []

      accounts.each do |account|
        next unless account.account_type.in?(%w[revenue expense])
        bal = period_balances[account.id]
        next unless bal

        net = if account.normal_balance == 'debit'
                bal[:total_debits] - bal[:total_credits]
              else
                bal[:total_credits] - bal[:total_debits]
              end

        next if net.zero?

        if account.account_type == 'revenue'
          lines << { chart_of_account_id: account.id, debit_amount: net, credit_amount: 0,
                     memo: "Year-end close FY#{fiscal_year}" }
        else
          lines << { chart_of_account_id: account.id, debit_amount: 0, credit_amount: net,
                     memo: "Year-end close FY#{fiscal_year}" }
        end
      end

      return { error: 'No revenue or expense activity to close' } if lines.empty?

      net_income = lines.sum { |l| (l[:credit_amount] || 0) - (l[:debit_amount] || 0) }

      if net_income > 0
        lines << { chart_of_account_id: re_account.id, debit_amount: 0, credit_amount: net_income,
                   memo: "Net income to Retained Earnings FY#{fiscal_year}" }
      elsif net_income < 0
        lines << { chart_of_account_id: re_account.id, debit_amount: net_income.abs, credit_amount: 0,
                   memo: "Net loss to Retained Earnings FY#{fiscal_year}" }
      end

      posting_service = ManualPostingService.new(@company)
      je = posting_service.post_complex!(
        lines: lines,
        memo: "Year-end closing entries — FY#{fiscal_year}",
        entry_date: fy_end,
        posted_by: user
      )

      if je
        je.update!(is_closing: true)
        @company.fiscal_periods.for_year(fiscal_year).open_periods.each { |fp| fp.close!(user) }
        { success: true, journal_entry: je, net_income: net_income, accounts_closed: lines.count - 1 }
      else
        { error: 'Failed to create closing entries' }
      end
    end
  end
end
