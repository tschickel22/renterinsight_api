# frozen_string_literal: true

module McpTools
  # Plan and permission checks for the accounting tools, plus the scoping and
  # serializers they share. Every check uses the RBAC resource key the app's
  # own controller uses for the same screen, so a person sees through the AI
  # exactly the books they see in DealerTide.
  #
  #   bank feed         bank_accounts_accounting
  #   chart of accounts chart_of_accounts
  #   bills             bills
  #   customer invoices finance (InvoicesController)
  #   P&L and cash      financial_reports
  module AccountingAccess
    MODULE_KEY = 'finance.accounting'

    module_function

    def require_module!(ctx)
      return if ModuleAccessService.new(ctx.company).has_module?(MODULE_KEY)

      raise Denied, "Accounting is not part of this account's plan, so I cannot read or change the books."
    end

    def require!(ctx, resource, action)
      require_module!(ctx)
      ctx.authorize!(resource, action)
    end

    def module?(ctx)
      ModuleAccessService.new(ctx.company).has_module?(MODULE_KEY)
    end

    # Bank accounts the person can see. The app scopes these by company only;
    # the connector also narrows a location-tier user to their locations, as
    # it does everywhere else. Unlocated accounts (bank feeds connected
    # company-wide) stay visible, as unlocated records do for accounts.
    def bank_accounts(ctx)
      ctx.scope_locations(ctx.company.bank_accounts.where(is_deleted: [false, nil]), include_unlocated: true)
    end

    def bank_transactions(ctx)
      ctx.company.bank_transactions.where(bank_account_id: bank_accounts(ctx).select(:id))
    end

    def bills(ctx)
      ctx.scope_locations(ctx.company.bills.active, include_unlocated: true)
    end

    # Customer invoices as the invoices list shows them: not deleted, and
    # future loan payment invoices left out until they are due.
    def invoices(ctx)
      rel = ctx.company.invoices.not_deleted.where(
        '(invoices.loan_id IS NULL) OR (invoices.status != ? OR invoices.due_date <= ?)', 'draft', Date.current
      )
      ctx.scope_locations(rel, include_unlocated: true)
    end

    # Statuses that make up open receivables, as Reports::ArAgingReportService
    # counts them (drafts are not owed yet).
    OPEN_INVOICE_STATUSES = %w[finalized sent viewed partial overdue].freeze
    OPEN_BILL_STATUSES = %w[pending partially_paid].freeze

    # Ids come typed ("bank_txn:12") but a bare number is accepted too.
    def parse_id(value, prefix)
      text = value.to_s.strip
      text = text.delete_prefix("#{prefix}:")
      raise UserError, "Ids look like #{prefix}:12, not #{value.inspect}." unless text.match?(/\A\d+\z/)

      text.to_i
    end

    def money(value)
      value&.to_d&.round(2)&.to_f
    end

    def gl_account(account)
      return nil unless account

      { id: "gl_account:#{account.id}", number: account.account_number, name: account.name,
        type: account.account_type, sub_type: account.sub_type.presence }.compact
    end

    def bank_account_label(bank_account)
      [bank_account.bank_name, bank_account.try(:account_name).presence,
       bank_account.display_last_four.present? ? "x#{bank_account.display_last_four}" : nil].compact_blank.join(' ')
    end

    def bank_txn(ctx, txn)
      {
        id: "bank_txn:#{txn.id}", date: txn.transaction_date&.iso8601, description: txn.description,
        amount: money(txn.amount), direction: txn.amount.to_d.negative? ? 'withdrawal' : 'deposit',
        reference: txn.reference_number.presence, type: txn.transaction_type.presence, status: txn.status,
        bank_account: bank_account_label(txn.bank_account), category: gl_account(txn.category_account),
        memo: txn.memo.presence, excluded_reason: txn.excluded_reason.presence,
        journal_entry: txn.matched_journal_entry && { number: txn.matched_journal_entry.entry_number,
                                                      date: txn.matched_journal_entry.entry_date&.iso8601 },
        url: ctx.app_url('/accounting/bank-transactions')
      }.compact
    end

    def bill(ctx, bill)
      overdue = bill.due_date && bill.due_date < Date.current && OPEN_BILL_STATUSES.include?(bill.status)
      {
        id: "bill:#{bill.id}", bill_number: bill.bill_number.presence, vendor: bill.vendor_name.presence || bill.vendor&.name,
        status: bill.status, bill_date: bill.bill_date&.iso8601, due_date: bill.due_date&.iso8601,
        total: money(bill.total_amount), paid: money(bill.amount_paid), balance_due: money(bill.balance_due),
        days_overdue: overdue ? (Date.current - bill.due_date).to_i : nil, terms: bill.payment_terms.presence,
        memo: bill.memo.to_s.first(300).presence, location: ctx.location_names[bill.location_id],
        url: ctx.app_url('/accounting/bills')
      }.compact
    end

    def invoice(ctx, invoice)
      days = invoice.due_date && OPEN_INVOICE_STATUSES.include?(invoice.status) ? (Date.current - invoice.due_date).to_i : nil
      customer = invoice.contact ? [invoice.contact.first_name, invoice.contact.last_name].compact_blank.join(' ') : nil
      {
        id: "invoice:#{invoice.id}", invoice_number: invoice.invoice_number, status: invoice.status,
        customer: customer.presence, category: invoice.billing_category.presence,
        invoice_date: invoice.invoice_date&.iso8601, due_date: invoice.due_date&.iso8601,
        total: money(invoice.total), paid: money(invoice.amount_paid), amount_due: money(invoice.amount_due),
        days_past_due: days&.positive? ? days : nil, sent_at: invoice.sent_at&.iso8601,
        deal: invoice.deal_id && "deal:#{invoice.deal_id}", location: ctx.location_names[invoice.location_id],
        url: ctx.app_url("/finance/invoices/#{invoice.id}")
      }.compact
    end
  end
end
