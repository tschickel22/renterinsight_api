# frozen_string_literal: true

module Accounting
  # Read-only health check of one company's books: the problems that used to
  # surface only when a customer's numbers didn't tie out. Run nightly by
  # `rake accounting:integrity_check`, which emails the platform when any
  # company has issues. See script/accounting_integrity_report.rb for the
  # detailed per-company breakdown.
  class IntegrityCheckService
    Issue = Struct.new(:severity, :message)

    def initialize(company, as_of: Date.current)
      @company = company
      @as_of = as_of
    end

    def issues
      [
        *ledger_issues,
        *report_issues,
        *posting_failures,
        *unposted_documents,
        *changed_after_posting,
        *deal_invoice_issues
      ]
    end

    private

    def ledger_issues
      lines = JournalEntryLine.joins(:journal_entry).merge(JournalEntry.in_ledger)
                              .where(journal_entries: { company_id: @company.id })
      diff = lines.sum(:debit_amount) - lines.sum(:credit_amount)
      return [] if diff.zero?

      [Issue.new(:error, "Ledger debits and credits differ by #{money(diff)}")]
    end

    def report_issues
      out = []
      bs = Reports::BalanceSheetReportService.new(@company).generate(as_of_date: @as_of)
      bs_diff = bs[:total_assets] - (bs[:total_liabilities] + bs[:total_equity])
      out << Issue.new(:error, "Balance sheet is out by #{money(bs_diff)}") unless bs_diff.zero?

      tb = Reports::TrialBalanceReportService.new(@company).generate(as_of_date: @as_of)
      tb_diff = tb[:total_debits] - tb[:total_credits]
      out << Issue.new(:error, "Trial balance is out by #{money(tb_diff)}") unless tb_diff.zero?
      out
    end

    def posting_failures
      [Invoice, Bill].filter_map do |model|
        failed = model.where(company_id: @company.id).where.not(gl_post_error: nil)
        count = failed.count
        next if count.zero?

        sample = failed.order(gl_post_failed_at: :desc).first
        Issue.new(:error, "#{count} #{model.name.downcase.pluralize(count)} failed to post " \
                          "(latest: #{sample.gl_post_error.to_s.first(160)})")
      end
    end

    # Sent or paid invoices a day old with no entry, when the company has
    # auto-posting on: they're owed or collected but not in receivables.
    def unposted_documents
      return [] unless AccountingSettings.for_company(@company)&.auto_post_invoices

      posted = @company.journal_entries.excluding_void_pairs.where(source_entity_type: 'Invoice').select(:source_entity_id)
      missing = @company.invoices.where(status: %w[sent viewed partial paid overdue])
                        .where.not(total: 0)
                        .where('invoices.created_at < ?', 1.day.ago)
                        .where.not(id: posted)
      missing = missing.where(is_deleted: [false, nil]) if Invoice.column_names.include?('is_deleted')
      missing = missing.where.not(id: deal_sale_invoices.select(:id)) # booked by the deal; see deal_invoice_issues
      count = missing.count
      return [] if count.zero?

      [Issue.new(:warning, "#{count} sent/paid #{'invoice'.pluralize(count)} not in the ledger, " \
                           "totaling #{money(missing.sum(:total))}")]
    end

    # An invoice whose total no longer matches the receivable its entry
    # recorded, e.g. QuickBooks-wins sync rewrote a posted invoice's totals.
    def changed_after_posting
      # Live invoice entries only; a void's reversal carries the invoice as its
      # source too, so it is excluded along with the voided original.
      rows = @company.invoices
                     .joins("JOIN journal_entries je ON je.source_entity_type = 'Invoice' " \
                            'AND je.source_entity_id = invoices.id AND je.is_void = FALSE ' \
                            'AND je.id NOT IN (SELECT reversed_by_id FROM journal_entries ' \
                            'WHERE is_void = TRUE AND reversed_by_id IS NOT NULL)')
                     .joins('JOIN journal_entry_lines jl ON jl.journal_entry_id = je.id')
                     .group('invoices.id', 'invoices.invoice_number', 'invoices.total')
                     .pluck('invoices.invoice_number', 'invoices.total', Arel.sql('SUM(jl.debit_amount)'))
      off = rows.reject { |_num, total, posted| total.to_d == posted.to_d }
      return [] if off.empty?

      sample = off.first(3).map { |num, total, posted| "#{num}: #{money(total)} vs #{money(posted)} posted" }.join('; ')
      [Issue.new(:error, "#{off.size} #{'invoice'.pluralize(off.size)} changed after posting (#{sample})")]
    end

    # A deal's sale invoice is booked by the deal's GL approval, never by the
    # invoice itself (Accounting::InvoicePostingService#deal_invoice?).
    def deal_invoice_issues
      out = []
      posted = @company.journal_entries.excluding_void_pairs.where(source_entity_type: 'Invoice').select(:source_entity_id)
      doubled = deal_sale_invoices.where(id: posted)
      if doubled.exists?
        out << Issue.new(:error, "#{doubled.count} deal #{'invoice'.pluralize(doubled.count)} counted twice " \
                                 "(posted on top of the deal's closing entry), totaling #{money(doubled.sum(:total))}. " \
                                 'Run script/void_duplicate_deal_invoice_entries.rb')
      end

      unapproved = deal_sale_invoices.where(status: %w[sent viewed partial paid overdue])
                                     .joins('JOIN deals ON deals.id = invoices.deal_id')
                                     .where(deals: { gl_posted: [false, nil] })
      if unapproved.exists?
        out << Issue.new(:warning, "#{unapproved.count} deal #{'invoice'.pluralize(unapproved.count)} sent while the deal " \
                                   "isn't GL-approved, so the sale isn't in the ledger (#{money(unapproved.sum(:total))}). " \
                                   'Approve the deal under Deals & Commissions → Pending GL Approval.')
      end
      out
    end

    def deal_sale_invoices
      @company.invoices.where(source_type: %w[Deal deal_close])
              .or(@company.invoices.where(id: @company.deals.where.not(deal_invoice_id: nil).select(:deal_invoice_id)))
    end

    def money(value) = format('%.2f', value.to_d)
  end
end
