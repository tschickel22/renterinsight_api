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

    # A bank or cash account on the balance sheet: sub type bank, or an asset
    # with no sub type whose name says cash or a bank account (older charts
    # left the sub type blank).
    CASH_NAME = /\b(cash|checking|chk|savings|money market|bank)\b/i

    def cash_account?(account)
      return false unless account&.account_type == 'asset'

      account.sub_type == 'bank' || (account.sub_type.blank? && account.name.to_s.match?(CASH_NAME))
    end

    # GL accounts a bank feed line can be booked to only as a transfer: every
    # bank or cash account, plus whatever GL account a bank account is linked
    # to (even a mislinked one, since that is where its money is booked).
    def cash_account_ids(ctx, accounts)
      ids = accounts.each_value.select { |a| cash_account?(a) }.map(&:id)
      ids.concat(ctx.company.bank_accounts.where(is_deleted: [false, nil]).where.not(chart_of_account_id: nil).pluck(:chart_of_account_id))
      ids.to_set
    end

    # Said when a bank account's GL account is not a bank or cash account, as
    # when a checking account is linked to Customer Receivables. Every line
    # categorized from that feed would post to the wrong account.
    def bank_gl_warning(bank_account)
      gl = bank_account.chart_of_account
      return 'Not linked to a GL account, so lines cannot be categorized. Link it under Accounting, Bank Accounts.' unless gl
      return nil if cash_account?(gl)

      kind = gl.sub_type.presence&.tr('_', ' ') || gl.account_type.to_s
      "Linked to GL #{[gl.account_number, gl.name].compact_blank.join(' ')}, which is #{kind.match?(/\A[aeiou]/i) ? 'an' : 'a'} " \
        "#{kind} account, not a bank or cash account. Everything " \
        'categorized from this feed posts there. Check the link under Accounting, Bank Accounts before categorizing.'
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
        memo: txn.memo.presence,
        # Un-excluding a line in the app leaves the old reason behind, so a
        # reason on a line that is not excluded is stale, not a fact.
        excluded_reason: (txn.excluded_reason.presence if txn.status == 'excluded'),
        booked_by: booked_by(txn),
        journal_entry: txn.matched_journal_entry && { id: "journal_entry:#{txn.matched_journal_entry.id}",
                                                      number: txn.matched_journal_entry.entry_number,
                                                      date: txn.matched_journal_entry.entry_date&.iso8601 },
        url: ctx.app_url('/accounting/bank-transactions')
      }.compact
    end

    # For a matched or reconciled line, how it got into the books:
    #   posted     categorizing it posted a new entry for it (the entry's source is this line)
    #   linked     it was matched to an entry that already existed (an invoice payment, a bill, a manual entry)
    #   not_posted it was categorized with no entry behind it, so the money is not in the books
    def booked_by(txn)
      return nil unless %w[matched reconciled].include?(txn.status)

      je = txn.matched_journal_entry
      return 'not_posted' unless je

      txn.posted_by_categorization?(je) ? 'posted' : 'linked'
    end

    # One journal entry with its lines, as the journal entry screen shows it.
    def journal_entry(ctx, je)
      lines = je.journal_entry_lines.sort_by(&:id).map do |line|
        account = line.chart_of_account
        { account_number: account&.account_number, account_name: account&.name,
          debit: money(line.debit_amount.to_d.positive? ? line.debit_amount : nil),
          credit: money(line.credit_amount.to_d.positive? ? line.credit_amount : nil),
          memo: line.memo.presence, location: ctx.location_names[line.location_id],
          contact: line.contact_id && "contact:#{line.contact_id}", deal: line.deal_id && "deal:#{line.deal_id}" }.compact
      end
      reverses = je.company.journal_entries.find_by(reversed_by_id: je.id)
      source_record = "#{je.source_entity_type}:#{je.source_entity_id}" if je.source_entity_type.present? && je.source_entity_id
      {
        id: "journal_entry:#{je.id}", entry_number: je.entry_number, date: je.entry_date&.iso8601, memo: je.memo.presence,
        source: je.source_type.presence, source_record: source_record,
        is_void: je.is_void ? true : false, voided_at: je.voided_at&.iso8601,
        reversed_by: je.reversed_by && { id: "journal_entry:#{je.reversed_by.id}", entry_number: je.reversed_by.entry_number },
        reverses: reverses && { id: "journal_entry:#{reverses.id}", entry_number: reverses.entry_number },
        adjusting: je.is_adjusting ? true : nil, closing: je.is_closing ? true : nil,
        total_debits: money(lines.sum { |l| l[:debit].to_d }), total_credits: money(lines.sum { |l| l[:credit].to_d }),
        lines: lines, url: ctx.app_url('/accounting/journal-entries')
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
      open = OPEN_INVOICE_STATUSES.include?(invoice.status) && invoice.amount_due.to_d.positive?
      # Aged exactly as the aging totals age it, so the two always agree.
      days = ListInvoices.days_past_due(invoice.due_date, invoice.invoice_date) if open
      customer = invoice.contact ? [invoice.contact.first_name, invoice.contact.last_name].compact_blank.join(' ') : nil
      {
        id: "invoice:#{invoice.id}", invoice_number: invoice.invoice_number, status: invoice.status,
        customer: customer.presence, category: invoice.billing_category.presence,
        invoice_date: invoice.invoice_date&.iso8601, due_date: invoice.due_date&.iso8601,
        total: money(invoice.total), paid: money(invoice.amount_paid), amount_due: money(invoice.amount_due),
        days_past_due: days&.positive? ? days : nil, aging_bucket: days && ListInvoices.bucket(days), sent_at: invoice.sent_at&.iso8601,
        deal: invoice.deal_id && "deal:#{invoice.deal_id}", location: ctx.location_names[invoice.location_id],
        url: ctx.app_url("/finance/invoices/#{invoice.id}")
      }.compact
    end
  end
end
