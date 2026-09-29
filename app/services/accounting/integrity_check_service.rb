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
        *unposted_documents
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

      posted = @company.journal_entries.in_ledger.where(source_entity_type: 'Invoice').select(:source_entity_id)
      missing = @company.invoices.where(status: %w[sent viewed partial paid overdue])
                        .where.not(total: 0)
                        .where('invoices.created_at < ?', 1.day.ago)
                        .where.not(id: posted)
      missing = missing.where(is_deleted: [false, nil]) if Invoice.column_names.include?('is_deleted')
      count = missing.count
      return [] if count.zero?

      [Issue.new(:warning, "#{count} sent/paid #{'invoice'.pluralize(count)} not in the ledger, " \
                           "totaling #{money(missing.sum(:total))}")]
    end

    def money(value) = format('%.2f', value.to_d)
  end
end
