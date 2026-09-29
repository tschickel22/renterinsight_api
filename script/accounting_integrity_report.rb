# frozen_string_literal: true

# Read-only accounting integrity report for one company.
#
#   bin/rails runner script/accounting_integrity_report.rb <company_id> [as_of YYYY-MM-DD]
#
# Answers "why doesn't this tie out?" without anyone dissecting the ledger by
# hand: whether the ledger itself balances, what the balance sheet leaves out,
# and which documents never made it into the ledger. Every query runs inside a
# READ ONLY transaction that is rolled back, so it cannot change data.
#
# Each check is independent; one that fails prints its error and the rest run.

company_id = ARGV[0] or abort 'usage: bin/rails runner script/accounting_integrity_report.rb <company_id> [as_of]'
as_of      = ARGV[1] ? Date.parse(ARGV[1]) : Date.current

def money(v) = format('%.2f', v.to_d)
def section(title) = puts("\n== #{title} " + '=' * [0, 70 - title.length].max)

def check(title)
  section(title)
  yield
rescue StandardError => e
  puts "  !! check failed: #{e.class}: #{e.message.to_s.lines.first&.strip}"
end

ActiveRecord::Base.transaction do
  ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY')

  company = Company.find(company_id)
  puts "Accounting integrity report — #{company.name} (id #{company.id}" \
       "#{company.respond_to?(:account_number) ? ", #{company.account_number}" : ''}) as of #{as_of}"

  lines = JournalEntryLine.joins(:journal_entry)
                          .where(journal_entries: { company_id: company.id })
                          .where('journal_entries.entry_date <= ?', as_of)
  live_lines = lines.merge(JournalEntry.in_ledger)
  coa = company.chart_of_accounts

  # 1. The ledger itself. Every entry is validated debits == credits, so this
  #    should be exactly zero; anything else means data got in another way.
  check('1. Ledger totals (all entries, all locations)') do
    d = live_lines.sum(:debit_amount)
    c = live_lines.sum(:credit_amount)
    puts "  debits #{money(d)}  credits #{money(c)}  difference #{money(d - c)}"
    bad = company.journal_entries.in_ledger.where('entry_date <= ?', as_of)
                 .joins(:journal_entry_lines).group('journal_entries.id')
                 .having('SUM(journal_entry_lines.debit_amount) <> SUM(journal_entry_lines.credit_amount)')
                 .count
    puts "  entries whose own lines don't balance: #{bad.size}#{bad.any? ? " (ids #{bad.keys.first(20).join(', ')})" : ''}"
  end

  # 2. Opening balances not yet posted as an entry against Opening Balance
  #    Equity. Reports count them and show a calculated offset; re-saving the
  #    account (or Accounting::OpeningBalancePostingService#sync!) posts them.
  check('2. Opening balances not yet posted as entries') do
    rows = AccountBalanceService.new(company).legacy_opening_balances(as_of)
    if rows.none?
      puts '  none'
    else
      debit_side  = rows.where(normal_balance: 'debit').sum(:opening_balance)
      credit_side = rows.where.not(normal_balance: 'debit').sum(:opening_balance)
      rows.order(:account_number).each do |a|
        puts "  #{a.account_number} #{a.name} [#{a.account_type}/#{a.normal_balance}] #{money(a.opening_balance)}" \
             "#{a.try(:opening_balance_date) ? " dated #{a.opening_balance_date}" : ''}"
      end
      puts "  debit-side total #{money(debit_side)}  credit-side total #{money(credit_side)}  " \
           "=> shown as calculated Opening Balance Equity of #{money(debit_side - credit_side)}"
    end
  end

  # 3. Activity on accounts the reports skip (inactive or header).
  check('3. Balances on inactive or header accounts') do
    hidden = live_lines.joins(:chart_of_account)
                       .where('chart_of_accounts.is_active = FALSE OR chart_of_accounts.is_header = TRUE')
                       .group('chart_of_accounts.account_number', 'chart_of_accounts.name',
                              'chart_of_accounts.account_type', 'chart_of_accounts.is_active',
                              'chart_of_accounts.is_header')
                       .sum('journal_entry_lines.debit_amount - journal_entry_lines.credit_amount')
    if hidden.empty?
      puts '  none'
    else
      hidden.each do |(num, name, type, active, header), net|
        puts "  #{num} #{name} [#{type}] active=#{active} header=#{header}  net debit #{money(net)}"
      end
    end
  end

  # 4. Lines pointing at an account that belongs to another company.
  check('4. Lines on another company\'s accounts') do
    foreign = live_lines.joins(:chart_of_account).where.not(chart_of_accounts: { company_id: company.id })
    puts "  #{foreign.count} lines, net debit #{money(foreign.sum('journal_entry_lines.debit_amount - journal_entry_lines.credit_amount'))}"
  end

  # 5. Profit by fiscal year, and whether each year was closed. The balance
  #    sheet only adds the current fiscal year's profit; earlier years must be
  #    closed into Retained Earnings or they vanish from it.
  check('5. Net income by fiscal year vs Year-End Close') do
    fy_month = (AccountingSettings.for_company(company)&.fiscal_year_start_month rescue nil) || 1
    fy_of = ->(date) { date.month >= fy_month ? date.year : date.year - 1 }
    current_fy = fy_of.(as_of)

    pl = live_lines.joins(:chart_of_account)
                   .where(chart_of_accounts: { account_type: %w[revenue expense] })
                   .where(journal_entries: { is_closing: [false, nil] })
                   .pluck('journal_entries.entry_date', 'chart_of_accounts.account_type',
                          'journal_entry_lines.debit_amount', 'journal_entry_lines.credit_amount')
    by_year = Hash.new(BigDecimal('0'))
    pl.each { |date, _type, dr, cr| by_year[fy_of.(date)] += (cr.to_d - dr.to_d) }

    closings = company.journal_entries.where(is_closing: true, is_void: false).pluck(:entry_date).map { |d| fy_of.(d) }.tally
    unclosed = BigDecimal('0')
    by_year.keys.sort.each do |year|
      status = if year >= current_fy then 'current year (added to balance sheet)'
               elsif closings[year] then "closed (#{closings[year]} closing entr#{closings[year] == 1 ? 'y' : 'ies'})"
               else 'NOT CLOSED — missing from balance sheet'
               end
      unclosed += by_year[year] if year < current_fy && !closings[year]
      puts "  FY#{year}: net income #{money(by_year[year])}  #{status}"
    end
    puts "  prior-year income never closed: #{money(unclosed)}"
  end

  # 6. The reports as the customer sees them.
  check('6. Balance Sheet and Trial Balance (all locations)') do
    bs = Reports::BalanceSheetReportService.new(company).generate(as_of_date: as_of)
    t = bs[:totals] || bs
    ta = t[:total_assets] || bs[:total_assets]
    tl = t[:total_liabilities] || bs[:total_liabilities]
    te = t[:total_equity] || bs[:total_equity]
    puts "  balance sheet: assets #{money(ta)}  liabilities #{money(tl)}  equity #{money(te)}  " \
         "out by #{money(ta.to_d - (tl.to_d + te.to_d))}"
    tb = Reports::TrialBalanceReportService.new(company).generate(as_of_date: as_of)
    td = tb[:total_debits] || tb.dig(:totals, :total_debits)
    tc = tb[:total_credits] || tb.dig(:totals, :total_credits)
    puts "  trial balance: debits #{money(td)}  credits #{money(tc)}  out by #{money(td.to_d - tc.to_d)}"
  end

  # 7. Voided entries count together with their reversal and net to zero. One
  #    marked void with no reversal is dropped entirely.
  check('7. Voided entries') do
    voided = company.journal_entries.where(is_void: true).where('entry_date <= ?', as_of)
    orphan = voided.where(reversed_by_id: nil)
    puts "  #{voided.count} voided (netted against their reversals), #{orphan.count} with no reversal (excluded)"
  end

  # 8. Entries whose lines carry different locations (half-counted on a
  #    single-location report).
  check('8. Entries split across locations') do
    split = live_lines.group('journal_entries.id')
                      .having('COUNT(DISTINCT COALESCE(journal_entry_lines.location_id, 0)) > 1').count
    puts "  #{split.size} entries#{split.any? ? " (ids #{split.keys.first(20).join(', ')})" : ''}"
  end

  # 9. Invoices that should be in the ledger but aren't (a posting that failed
  #    to balance is only logged).
  check('9. Invoices with no journal entry') do
    invoices = company.invoices.where.not(status: %w[draft cancelled void voided]).where('total <> 0')
    invoices = invoices.where(is_deleted: false) if Invoice.column_names.include?('is_deleted')
    posted_ids = company.journal_entries.where(source_entity_type: 'Invoice').pluck(:source_entity_id)
    missing = invoices.where.not(id: posted_ids)
    puts "  #{missing.count} of #{invoices.count} invoices, total #{money(missing.sum(:total))}"
    missing.order(:id).limit(25).each do |inv|
      puts "    #{inv.invoice_number} #{inv.status} total #{money(inv.total)} tax #{money(inv.tax_amount)}"
    end
  end

  # 10. Invoice tax: header (rounded per line) vs ledger tax (raw 4dp per account).
  check('10. Invoice tax header vs line-tax snapshots') do
    diffs = []
    company.invoices.includes(invoice_items: :invoice_item_taxes).find_each do |inv|
      raw = inv.invoice_items.sum { |i| i.invoice_item_taxes.sum(&:computed_amount) }
      next if raw.zero?
      d = inv.tax_amount.to_d - raw.round(2)
      diffs << [inv.invoice_number, d] unless d.zero?
    end
    puts "  #{diffs.size} invoices where per-line rounding differs from the ledger's tax, net #{money(diffs.sum { |_, d| d })}"
    diffs.first(15).each { |num, d| puts "    #{num}: #{money(d)}" }
  end

  # 11. Credit memos and bills that should have hit the ledger.
  check('11. Credit memos applied (never posted to the ledger)') do
    applied = CreditMemoApplication.joins(:credit_memo).where(credit_memos: { company_id: company.id })
    puts "  #{applied.count} applications, #{money(applied.sum(:amount))} taken off invoices but not off GL receivables"
  end

  check('12. Bills with no journal entry') do
    bills = company.bills.where.not(status: %w[draft void voided cancelled])
    posted = company.journal_entries.where(source_entity_type: 'Bill').pluck(:source_entity_id)
    missing = bills.where.not(id: posted)
    puts "  #{missing.count} of #{bills.count} bills, total #{money(missing.sum(:total_amount))}" \
         " (#{missing.where('tax_amount > 0').count} with tax)"
  end

  raise ActiveRecord::Rollback
end
