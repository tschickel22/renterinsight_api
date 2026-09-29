# frozen_string_literal: true

# Read-only: explains why invoices are or aren't in the ledger, and flags any
# invoice counted twice (posted itself AND through its deal's closing entry).
#
#   bin/rails runner script/inspect_invoice_posting.rb <company_id> [invoice_number]
#
# Runs inside a READ ONLY transaction that is rolled back; it changes nothing.
# For each sent/paid invoice with no journal entry it shows where the invoice
# came from, whether a deal already booked the sale, what posting it would
# create, and a verdict.

company_id = ARGV[0] or abort 'usage: bin/rails runner script/inspect_invoice_posting.rb <company_id> [invoice_number]'
only_number = ARGV[1]

def money(v) = format('%.2f', v.to_d)

ActiveRecord::Base.transaction do
  ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY')

  company  = Company.find(company_id)
  settings = AccountingSettings.for_company(company)
  puts "Invoice posting review — #{company.name} (id #{company.id}" \
       "#{company.respond_to?(:account_number) ? ", #{company.account_number}" : ''})"
  puts "  auto-post invoices: #{settings&.auto_post_invoices.inspect}   auto-post payments: #{settings&.try(:auto_post_payments).inspect}"
  puts "  AR account: #{settings&.default_ar_account&.then { |a| "#{a.account_number} #{a.name}" } || 'NOT SET'}   " \
       "sales revenue: #{settings&.default_sales_revenue_account&.then { |a| "#{a.account_number} #{a.name}" } || 'NOT SET'}"

  ledger = company.journal_entries.in_ledger
  # Live entries only: a voided invoice entry and its reversal (which also
  # carries the invoice as its source) mean the invoice is no longer posted.
  invoice_entries = company.journal_entries.excluding_void_pairs.where(source_entity_type: 'Invoice')
  posted_ids = invoice_entries.pluck(:source_entity_id).to_set

  deal_booked = lambda do |deal_id|
    return BigDecimal('0') if deal_id.blank?

    # Receivables the deal's own entries debited (the closing entry books the
    # sale, F&I and tax to AR). Any receivable account counts: a deal can post
    # to one other than the company's default AR account.
    ar_ids = company.chart_of_accounts.where(sub_type: 'accounts_receivable').pluck(:id) | [settings&.default_ar_account_id].compact
    JournalEntryLine.joins(:journal_entry).merge(JournalEntry.in_ledger)
                    .where(journal_entries: { company_id: company.id, source_entity_type: 'Deal', source_entity_id: deal_id })
                    .where(chart_of_account_id: ar_ids)
                    .sum(:debit_amount)
  end

  scope = company.invoices.where.not(status: %w[draft cancelled])
  scope = scope.where(is_deleted: [false, nil]) if Invoice.column_names.include?('is_deleted')
  scope = scope.where(invoice_number: only_number) if only_number

  # 1. Invoices not in the ledger
  unposted = scope.where.not(total: 0).reject { |inv| posted_ids.include?(inv.id) }
  puts "\n== Invoices not in the ledger: #{unposted.size} " + '=' * 30
  unposted.each do |inv|
    puts "\n#{inv.invoice_number}  status=#{inv.status}  dated #{inv.invoice_date}  created #{inv.created_at.to_date}"
    puts "  subtotal #{money(inv.subtotal)}  tax #{money(inv.tax_amount)}  total #{money(inv.total)}  " \
         "paid #{money(inv.amount_paid)}  due #{money(inv.amount_due)}"
    puts "  source: #{inv.source_type.presence || 'manual'}#{inv.source_id ? " ##{inv.source_id}" : ''}" \
         "#{inv.deal_id ? "  deal ##{inv.deal_id}" : ''}#{inv.loan_id ? "  loan ##{inv.loan_id} payment #{inv.loan_payment_number}" : ''}" \
         "#{inv.quote_id ? "  quote ##{inv.quote_id}" : ''}  location #{inv.location_id.inspect}"
    puts "  recorded posting error: #{inv.gl_post_error}" if inv.respond_to?(:gl_post_error) && inv.gl_post_error.present?

    booked = deal_booked.(inv.deal_id)
    if inv.deal_id
      deal = Deal.find_by(id: inv.deal_id)
      puts "  deal ##{inv.deal_id}: status=#{deal&.try(:status).inspect}  AR the deal already booked: #{money(booked)}"
    end

    applied = inv.payment_applications.joins(:payment).where(payments: { status: 'completed' })
    if applied.exists?
      pay_ids = applied.pluck(:payment_id)
      posted_pays = ledger.where(source_entity_type: 'Payment', source_entity_id: pay_ids).distinct.count(:source_entity_id)
      puts "  payments applied: #{money(applied.sum('payment_applications.amount'))} " \
           "(#{posted_pays} of #{pay_ids.uniq.size} payments posted)"
    end

    # What posting it would create (computed only; nothing is saved)
    svc = Accounting::InvoicePostingService.new(inv)
    revenue = svc.send(:build_revenue_lines).sum { |_id, l| l[:amount].to_d }
    tax = svc.send(:tax_credit_buckets, default_account: settings&.default_sales_tax_payable_account).sum { |_a, b| b[:amount].to_d }
    puts "  posting it would: Dr AR #{money(inv.subtotal.to_d + inv.tax_amount.to_d)}  " \
         "Cr revenue #{money(revenue)}  Cr sales tax #{money(tax)}"

    verdict =
      if inv.deal_id && booked.positive?
        "ALREADY BOOKED by deal ##{inv.deal_id}'s closing entry. Do NOT post the invoice; that would double-count it."
      elsif inv.source_type.to_s == 'deal_close' || inv.deal_id
        "From a deal that has NOT posted its closing entry yet. Close/post the deal's accounting rather than the invoice."
      elsif inv.loan_id
        'Loan installment. Check how loan payments post before posting installments individually.'
      elsif !settings&.auto_post_invoices
        'Auto-post invoices is OFF for this company, so nothing posted it. Post it (or turn auto-post on) if it should be in AR.'
      elsif inv.location_id.blank?
        'No location on the invoice, which blocks posting. Set a location, then post it.'
      else
        'Should have posted. Post it: Accounting::InvoicePostingService.new(Invoice.find(' \
          "#{inv.id})).post! (the invoice page will show the reason if it fails)."
      end
    puts "  VERDICT: #{verdict}"
  end

  # 2. Counted twice: the invoice posted itself AND its deal booked the sale
  doubled = scope.where(id: posted_ids.to_a).where.not(deal_id: nil).select { |inv| deal_booked.(inv.deal_id).positive? }
  puts "\n== Invoices counted twice (invoice entry + deal closing entry): #{doubled.size} " + '=' * 5
  doubled.each do |inv|
    je = invoice_entries.find_by(source_entity_id: inv.id)
    puts "  #{inv.invoice_number}  total #{money(inv.total)}  invoice entry #{je&.entry_number}  deal ##{inv.deal_id} booked #{money(deal_booked.(inv.deal_id))}"
  end
  puts '  none' if doubled.empty?

  raise ActiveRecord::Rollback
end
