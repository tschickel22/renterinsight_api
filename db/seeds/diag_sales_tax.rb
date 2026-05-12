# diag_sales_tax.rb
# Run: bin/rails runner db/seeds/diag_sales_tax.rb

company = Company.find(47)

# 1. Tax accounts
tax_accounts = company.chart_of_accounts.where(account_number: ['2210', '2220', '2230'])
puts "Tax accounts:"
tax_accounts.each { |a| puts "  id=#{a.id} #{a.account_number} #{a.name} (active=#{a.is_active}, type=#{a.account_type})" }

# 2. Check JE lines that reference these accounts
tax_ids = tax_accounts.pluck(:id)
puts "\nTax account IDs: #{tax_ids.inspect}"

lines = JournalEntryLine
  .joins(:journal_entry)
  .where(journal_entries: { company_id: company.id })
  .where(chart_of_account_id: tax_ids)

puts "Total JE lines for tax accounts: #{lines.count}"
lines.limit(5).each do |l|
  je = l.journal_entry
  puts "  JE##{je.id} date=#{je.entry_date} void=#{je.is_void} | line: acct=#{l.chart_of_account_id} debit=#{l.debit_amount} credit=#{l.credit_amount} location=#{l.location_id}"
end

# 3. Check non-void
non_void = lines.where(journal_entries: { is_void: false })
puts "\nNon-void lines: #{non_void.count}"

# 4. Check date range
in_range = non_void.where(journal_entries: { entry_date: Date.new(2024,5,1)..Date.current })
puts "In date range (2024-05-01 to today): #{in_range.count}"

# 5. Run period_balances directly
service = AccountBalanceService.new(company)
result = service.period_balances(start_date: Date.new(2024,5,1), end_date: Date.current)
puts "\nperiod_balances result for tax accounts:"
tax_ids.each do |tid|
  bal = result[tid]
  if bal
    puts "  account #{tid}: debits=#{bal[:total_debits]} credits=#{bal[:total_credits]}"
  else
    puts "  account #{tid}: NOT FOUND in results"
  end
end

puts "\nAll accounts in period_balances: #{result.keys.count} accounts"
