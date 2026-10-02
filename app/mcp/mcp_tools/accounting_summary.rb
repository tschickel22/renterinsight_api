# frozen_string_literal: true

module McpTools
  # The owner's view of the books in one call: profit for the month and the
  # fiscal year so far, cash, what is owed to and by the dealership, and how
  # much of the bank feed is still to be categorized. Each section needs the
  # same permission as its screen in the app; sections the person cannot see
  # are left out and named, so the AI does not report them as zero.
  class AccountingSummary < Base
    tool_name 'accounting_summary'
    title 'Accounting summary'
    description 'Profit and loss for a period (default this month) and fiscal year to date, from posted journal ' \
                'entries as the P&L report shows them; book cash per bank account; bank feed lines still to be ' \
                'categorized; unpaid vendor bills; and open customer invoices with a balance due, with aging (the ' \
                'same count list_invoices gives). Sections the user cannot see are listed under skipped (always ' \
                'present, empty when nothing was skipped). profit_and_loss.notes says when invoices are not set ' \
                'to post to the books. Note: profit only reflects what has been booked, so a large ' \
                'uncategorized bank feed means the P&L is incomplete.'
    input_schema(
      properties: {
        start_date: { type: 'string', description: 'ISO date; default the first of this month' },
        end_date: { type: 'string', description: 'ISO date; default today' }
      }
    )
    read_only!

    def self.perform(ctx, start_date: nil, end_date: nil)
      AccountingAccess.require_module!(ctx)
      ctx.row_limit(1)
      from = ListTool.parse_date(start_date, 'start_date') || Date.current.beginning_of_month
      to = ListTool.parse_date(end_date, 'end_date') || Date.current
      raise UserError, 'start_date must be on or before end_date.' if from > to

      payload = { as_of: Date.current.iso8601, dates_apply_to: DATES_APPLY_TO, skipped: [] }
      section(ctx, payload, 'financial_reports', :profit_and_loss) { profit(ctx, from, to) }
      section(ctx, payload, 'financial_reports', :cash) { cash(ctx) }
      section(ctx, payload, 'bank_accounts_accounting', :bank_feed) { bank_feed(ctx, from, to) }
      section(ctx, payload, 'bills', :bills) { bills(ctx) }
      section(ctx, payload, 'finance', :customer_invoices) { ListInvoices.aging(AccountingAccess.invoices(ctx)) }
      payload[:url] = ctx.app_url('/accounting')
      Base::Result.new(payload: payload, count: 1)
    end

    def self.section(ctx, payload, resource, key)
      if ctx.can?(resource, 'read')
        payload[key] = yield
      else
        payload[:skipped] << "#{key.to_s.tr('_', ' ')} (needs #{resource.tr('_', ' ')} read)"
      end
    end

    # nil = company-wide; otherwise the person's locations, each run through
    # the P&L report and added up.
    def self.report_locations(ctx)
      ctx.location_ids.nil? ? [nil] : ctx.location_ids
    end

    # find_by, not AccountingSettings.for_company: that creates the row, and
    # a read tool should not write.
    def self.settings(ctx)
      AccountingSettings.find_by(company_id: ctx.company.id)
    end

    def self.basis(ctx)
      settings(ctx)&.accounting_method.presence || 'accrual'
    end

    def self.fiscal_year_start(ctx, date)
      start_month = settings(ctx)&.fiscal_year_start_month || 1
      year = date.month >= start_month ? date.year : date.year - 1
      Date.new(year, start_month, 1)
    end

    def self.profit(ctx, from, to)
      ytd_from = fiscal_year_start(ctx, to)
      { basis: basis(ctx),
        period: pnl(ctx, from, to),
        fiscal_year_to_date: pnl(ctx, ytd_from, to),
        notes: posting_notes(ctx).presence,
        url: ctx.app_url('/accounting/reports/profit-and-loss') }.compact
    end

    # Invoices and payments reach the P&L only when Accounting Settings says
    # to post them, and both are off unless the dealer turned them on. Said
    # out loud so a P&L of zero next to open invoices is not read as a bug
    # or as no sales.
    def self.posting_notes(ctx)
      s = settings(ctx)
      notes = []
      unless s&.auto_post_invoices
        notes << 'Customer invoices are not set to post to the books (Accounting Settings, auto post invoices is off), ' \
                 'so invoice revenue is not in this P&L. Turning it on posts invoices from then on; it does not ' \
                 'back-post earlier ones.'
      end
      notes << 'Customer payments are not set to post to the books (auto post payments is off).' unless s&.auto_post_payments
      notes
    end

    def self.pnl(ctx, from, to)
      service = Reports::ProfitAndLossReportService.new(ctx.company)
      reports = report_locations(ctx).map do |loc|
        service.generate(start_date: from, end_date: to, location_id: loc, basis: basis(ctx))
      end
      revenue = reports.sum { |r| r[:total_revenue].to_d }
      cogs = reports.sum { |r| r[:total_cogs].to_d }
      expenses = reports.sum { |r| r[:total_expenses].to_d }
      net = reports.sum { |r| r[:net_income].to_d }
      {
        from: from.iso8601, to: to.iso8601,
        revenue: AccountingAccess.money(revenue), cost_of_goods_sold: AccountingAccess.money(cogs),
        gross_profit: AccountingAccess.money(revenue - cogs), expenses: AccountingAccess.money(expenses),
        net_income: AccountingAccess.money(net),
        top_expenses: top_rows(reports.flat_map { |r| r[:expenses] }),
        top_revenue: top_rows(reports.flat_map { |r| r[:revenue] })
      }
    end

    def self.top_rows(rows)
      rows.group_by { |r| [r[:account_number], r[:account_name]] }
          .map { |(number, name), rs| { account: [number, name].compact_blank.join(' '), amount: rs.sum { |r| r[:amount].to_d } } }
          .sort_by { |r| -r[:amount] }.first(5)
          .map { |r| r.merge(amount: AccountingAccess.money(r[:amount])) }
    end

    def self.cash(ctx)
      balances = AccountBalanceService.new(ctx.company)
      accounts = AccountingAccess.bank_accounts(ctx).includes(:chart_of_account).filter_map do |ba|
        next unless ba.chart_of_account

        warning = AccountingAccess.bank_gl_warning(ba)
        { bank_account: AccountingAccess.bank_account_label(ba), gl_account: AccountingAccess.gl_account(ba.chart_of_account),
          book_balance: AccountingAccess.money(balances.balance_as_of(ba.chart_of_account, Date.current)),
          gl_account_warning: warning, in_total: warning ? false : nil }.compact
      end
      # A bank account linked to, say, Customer Receivables would add every
      # receivable to cash. Those are shown with a warning and left out of
      # the total.
      counted = accounts.reject { |a| a[:in_total] == false }
      { accounts: accounts, total: AccountingAccess.money(counted.sum { |a| a[:book_balance].to_d }),
        note: 'Book balances from the general ledger. They match the bank only once the feed is categorized.' \
              "#{' A bank account linked to a GL account that is not a bank or cash account is left out of the total.' if counted.size < accounts.size}" }
    end

    DATES_APPLY_TO = 'start_date and end_date apply to profit_and_loss only, plus the bank_feed counts named ' \
                     'in_period and through_period_end. Cash, the rest of bank_feed, bills and customer_invoices ' \
                     'are as of today.'

    def self.bank_feed(ctx, from, to)
      unmatched = AccountingAccess.bank_transactions(ctx).where(status: 'unmatched')
      { unmatched: unmatched.count,
        unmatched_in_period: unmatched.where(transaction_date: from..to).count,
        unmatched_through_period_end: unmatched.where('transaction_date <= ?', to).count, unmatched_total_in: AccountingAccess.money(unmatched.where('amount > 0').sum(:amount)),
        unmatched_total_out: AccountingAccess.money(unmatched.where('amount < 0').sum(:amount).abs),
        oldest_unmatched: unmatched.minimum(:transaction_date)&.iso8601,
        last_reconciled: ctx.company.bank_reconciliations.where(status: 'completed').maximum(:statement_date)&.iso8601,
        url: ctx.app_url('/accounting/bank-transactions') }
    end

    def self.bills(ctx)
      open = AccountingAccess.bills(ctx).where(status: AccountingAccess::OPEN_BILL_STATUSES)
      overdue = open.where('bills.due_date < ?', Date.current)
      { unpaid: open.count, balance_due: AccountingAccess.money(open.sum(:balance_due)),
        overdue: overdue.count, overdue_balance: AccountingAccess.money(overdue.sum(:balance_due)),
        due_next_7_days: AccountingAccess.money(open.where(due_date: Date.current..(Date.current + 7)).sum(:balance_due)),
        drafts_not_entered: AccountingAccess.bills(ctx).where(status: 'draft').count,
        url: ctx.app_url('/accounting/bills') }
    end
  end
end
