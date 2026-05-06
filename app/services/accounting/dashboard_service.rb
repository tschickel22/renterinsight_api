# frozen_string_literal: true

module Accounting
  class DashboardService
    def initialize(company)
      @company = company
    end

    def widgets
      {
        cash_position: cash_position,
        ar_ap_summary: ar_ap_summary,
        monthly_pnl_trend: monthly_pnl_trend,
        recent_journal_entries: recent_entries,
        upcoming_recurring: upcoming_recurring
      }
    end

    private

    def cash_position
      balance_service = AccountBalanceService.new(@company)
      cash_accounts = @company.chart_of_accounts.where(sub_type: 'bank', is_active: true)
      accounts = cash_accounts.map do |account|
        { name: account.name, balance: balance_service.balance_as_of(account, Date.current) }
      end
      { accounts: accounts, total: accounts.sum { |a| a[:balance] } }
    end

    def ar_ap_summary
      ar_report = Reports::ArAgingReportService.new(@company).generate
      ap_report = begin
        Reports::ApAgingReportService.new(@company).generate
      rescue StandardError
        { grand_total: 0 }
      end
      {
        total_ar: ar_report[:grand_total],
        total_ap: ap_report[:grand_total],
        net: ar_report[:grand_total] - ap_report[:grand_total]
      }
    end

    def monthly_pnl_trend
      pnl_service = Reports::ProfitAndLossReportService.new(@company)
      (0..5).map do |months_ago|
        start_d = (Date.current - months_ago.months).beginning_of_month
        end_d = start_d.end_of_month
        pnl = pnl_service.generate(start_date: start_d, end_date: end_d)
        {
          month: start_d.strftime('%b %Y'),
          revenue: pnl[:total_revenue],
          expenses: pnl[:total_expenses] + pnl[:total_cogs],
          net_income: pnl[:net_income]
        }
      end.reverse
    end

    def recent_entries
      @company.journal_entries.posted.order(entry_date: :desc, created_at: :desc).limit(10).map do |je|
        {
          id: je.id,
          entry_number: je.entry_number,
          date: je.entry_date,
          memo: je.memo,
          amount: je.total_debits,
          source_type: je.source_type
        }
      end
    end

    def upcoming_recurring
      bills = @company.try(:recurring_bills)&.active&.order(:next_due_date)&.limit(5) || []
      rjes = @company.recurring_journal_entries.active.order(:next_run_date).limit(5)

      upcoming = []
      bills.each { |b| upcoming << { type: 'bill', name: b.name, amount: b.amount, due_date: b.next_due_date } }
      rjes.each { |r| upcoming << { type: 'recurring_je', name: r.name, due_date: r.next_run_date } }
      upcoming.sort_by { |u| u[:due_date] || Date.new(9999, 1, 1) }.first(10)
    end
  end
end
