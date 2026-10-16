# frozen_string_literal: true

module Reports
  # Deal Funding (E78 step 1): for every approved deal, what it sold for, what
  # has come in, what is still owed and which draws are due or late.
  #
  # It reads what exists and posts nothing. The deal's invoice (one per deal,
  # made at approval) carries the amount, the money applied to it and the draw
  # schedule. Draw progress is worked out here by filling the draws in order
  # with everything paid or credited on the invoice, the same order Record
  # Deal Payment fills them, because portal and card payments never update the
  # stored draw schedule.
  #
  # The books check compares the invoice with the ledger: accounts receivable
  # tagged to the deal (closing entry, sales tax, later adjustments) less what
  # has been paid on the invoice. Payments never carry the deal on their AR
  # line, so they are taken from the invoice instead. A difference means the
  # invoice and the books disagree (fees billed but never posted, a credit memo,
  # a change after approval that only one side picked up).
  class DealFundingReportService
    STATUSES = %w[open overdue paid no_invoice].freeze
    TOLERANCE = BigDecimal('0.01')

    def initialize(company, today: Date.current)
      @company = company
      @today = today
    end

    def generate(location_id: nil, status: nil, start_date: nil, end_date: nil, payment_type: nil)
      deals = scoped_deals(location_id: location_id, start_date: start_date, end_date: end_date, payment_type: payment_type).to_a
      invoices = @company.invoices.where(id: deals.map(&:deal_invoice_id).compact, is_deleted: [false, nil]).index_by(&:id)
      ledger_ar = ledger_ar_by_deal(deals.map(&:id))
      projects = @company.projects.not_deleted.where(deal_id: deals.map(&:id)).index_by(&:deal_id)
      job_costs = ProjectJobCostReportService.new(@company).job_cost_by_project(projects.values.map(&:id))

      rows = deals.map do |deal|
        row(deal, invoices[deal.deal_invoice_id], ledger_ar[deal.id], projects[deal.id], job_costs)
      end
      statuses = Array(status).map(&:to_s) & STATUSES
      rows = rows.select { |r| statuses.include?(r[:status]) } if statuses.any?

      { deals: rows, summary: summary(rows) }
    end

    private

    def scoped_deals(location_id:, start_date:, end_date:, payment_type:)
      deals = @company.deals.where(deleted_at: nil)
                      .where.not(gl_posted_at: nil).or(@company.deals.where(deleted_at: nil).where.not(deal_invoice_id: nil))
                      .includes(:contact, :account, :location)
      deals = deals.where(location_id: location_id) if location_id.present?
      deals = deals.where(payment_type: payment_type) if payment_type.present?
      approved = 'COALESCE(deals.gl_posted_at::date, deals.actual_close_date, deals.won_at::date, deals.created_at::date)'
      deals = deals.where("#{approved} >= ?", start_date) if start_date
      deals = deals.where("#{approved} <= ?", end_date) if end_date
      deals.order(Arel.sql("#{approved} DESC"), id: :desc)
    end

    def row(deal, invoice, ledger_ar, project, job_costs)
      total = invoice ? invoice.total.to_d : DealInvoiceService.new(deal).deal_total
      paid = invoice ? invoice.amount_paid.to_d : 0.to_d
      credited = invoice ? invoice.amount_credited.to_d : 0.to_d
      owed = invoice ? [invoice.amount_due.to_d, 0.to_d].max : total
      draws = invoice ? draw_progress(invoice, paid + credited) : []
      unpaid = draws.reject { |d| d[:status] == 'paid' }
      overdue = unpaid.select { |d| d[:due_date] && d[:due_date] < @today }
      overdue_amount = overdue.sum { |d| d[:balance] }
      # Without a draw schedule the invoice's own due date is the one date owed.
      if draws.empty? && invoice&.due_date && invoice.due_date < @today && owed.positive?
        overdue_amount = owed
      end
      next_draw = unpaid.min_by { |d| [d[:due_date] || Date.new(9999), d[:position].to_i] }
      closed_on = deal.actual_close_date || deal.won_at&.to_date

      books_owed = ledger_ar && (ledger_ar - paid)
      difference = books_owed && (books_owed - owed)

      {
        id: deal.id,
        deal_number: deal.deal_number,
        name: deal.name,
        customer_name: deal.customer_display_name,
        location: deal.location&.name,
        payment_type: deal.payment_type,
        lender_name: deal.lender_name,
        closed_on: closed_on,
        approved_on: deal.gl_posted_at&.to_date,
        days_since_close: closed_on && (@today - closed_on).to_i,
        invoice_id: invoice&.id,
        invoice_number: invoice&.invoice_number,
        deal_amount: total.to_f,
        received: paid.to_f,
        credited: credited.to_f,
        owed: owed.to_f,
        overdue_amount: overdue_amount.to_f,
        overdue_draws: overdue.size,
        draw_count: draws.size,
        draws: draws.map { |d| d.merge(amount: d[:amount].to_f, paid: d[:paid].to_f, balance: d[:balance].to_f) },
        next_draw: next_draw && { description: next_draw[:description], due_date: next_draw[:due_date], balance: next_draw[:balance].to_f },
        due_date: invoice&.due_date,
        status: invoice ? funding_status(owed, overdue_amount) : 'no_invoice',
        project_id: project&.id,
        project_number: project&.project_number,
        job_cost: project && job_costs.fetch(project.id, 0.to_d).to_f,
        books_owed: books_owed&.to_f,
        books_difference: difference&.to_f,
        books_check: books_check(invoice, ledger_ar, difference)
      }
    end

    def funding_status(owed, overdue_amount)
      return 'paid' unless owed > TOLERANCE
      overdue_amount > TOLERANCE ? 'overdue' : 'open'
    end

    def books_check(invoice, ledger_ar, difference)
      return 'no_invoice' unless invoice
      return 'not_posted' if ledger_ar.nil?
      difference.abs <= TOLERANCE ? 'ok' : 'differs'
    end

    # The invoice's draws, filled in order with what was paid or credited.
    def draw_progress(invoice, applied)
      schedule = invoice.draw_schedule
      draws = schedule.is_a?(Hash) ? schedule['draws'] : nil
      return [] unless draws.is_a?(Array)

      left = applied
      draws.sort_by { |d| d['position'].to_i }.map do |d|
        amount = d['amount'].to_d
        paid = [left, amount].min
        left -= paid
        balance = amount - paid
        {
          position: d['position'],
          description: d['description'],
          due_date: (Date.parse(d['due_date'].to_s) rescue nil),
          amount: amount,
          paid: paid,
          balance: balance,
          status: if balance <= TOLERANCE then 'paid'
                  elsif paid.positive? then 'partial'
                  else 'pending'
                  end
        }
      end
    end

    # Receivable on the ledger tagged to each deal. Nil for a deal with no
    # receivable line at all (not posted).
    def ledger_ar_by_deal(deal_ids)
      return {} if deal_ids.empty?

      ar_ids = @company.chart_of_accounts.where(sub_type: 'accounts_receivable').pluck(:id)
      default_ar = AccountingSettings.for_company(@company).default_ar_account
      ar_ids |= [default_ar.id] if default_ar

      JournalEntryLine.joins(:journal_entry)
                      .merge(JournalEntry.in_ledger)
                      .where(journal_entries: { company_id: @company.id }, deal_id: deal_ids, chart_of_account_id: ar_ids)
                      .group(:deal_id)
                      .sum('journal_entry_lines.debit_amount - journal_entry_lines.credit_amount')
                      .transform_values(&:to_d)
    end

    def summary(rows)
      this_month = @today.beginning_of_month
      # A deal with no invoice has nowhere to record a payment, so what it owes
      # is unknown; it is counted on its own, not in the totals.
      no_invoice = rows.select { |r| r[:status] == 'no_invoice' }
      rows = rows - no_invoice
      {
        deal_count: rows.size,
        total_deal_amount: rows.sum { |r| r[:deal_amount] },
        total_received: rows.sum { |r| r[:received] },
        total_owed: rows.sum { |r| r[:owed] },
        total_overdue: rows.sum { |r| r[:overdue_amount] },
        overdue_count: rows.count { |r| r[:status] == 'overdue' },
        open_count: rows.count { |r| r[:status] == 'open' },
        paid_count: rows.count { |r| r[:status] == 'paid' },
        books_issue_count: rows.count { |r| r[:books_check] != 'ok' },
        no_invoice_count: no_invoice.size,
        no_invoice_amount: no_invoice.sum { |r| r[:deal_amount] },
        received_this_month: received_since(rows.map { |r| r[:invoice_id] }.compact, this_month)
      }
    end

    # Money applied to these deals' invoices since the first of the month, from
    # posted receipts and completed payments.
    def received_since(invoice_ids, date)
      return 0.0 if invoice_ids.empty?

      receipts = CashReceiptApplication.joins(:cash_receipt)
                                       .where(invoice_id: invoice_ids)
                                       .where(cash_receipts: { company_id: @company.id, status: CashReceipt::STATUS_POSTED, is_deleted: [false, nil] })
                                       .where('cash_receipts.receipt_date >= ?', date)
                                       .sum(:amount_applied)
      payments = PaymentApplication.joins(:payment)
                                   .where(applicable_type: 'Invoice', applicable_id: invoice_ids)
                                   .where(payments: { company_id: @company.id, status: 'completed' })
                                   .where('COALESCE(payment_applications.applied_at, payment_applications.created_at) >= ?', date.beginning_of_day)
                                   .sum(:amount)
      (receipts + payments).to_f
    end
  end
end
