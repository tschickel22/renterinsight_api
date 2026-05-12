# frozen_string_literal: true

# Seed file: db/seeds/reconciliation_test_data.rb
# Creates bank account, journal entries, and a reconciliation for testing
# Run: bin/rails runner db/seeds/reconciliation_test_data.rb

company = Company.find(47) # Summit Park
user = company.users.first
location = company.locations.first

puts "\n🏦 Reconciliation Test Data Seeder"
puts "Company: #{company.name} (ID: #{company.id})"

# ── 1. Find or create Cash - Operating COA account ──
cash_acct = company.chart_of_accounts.find_by(account_number: '1000')
unless cash_acct
  cash_acct = company.chart_of_accounts.create!(
    account_number: '1000',
    name: 'Cash - Operating',
    account_type: 'asset',
    normal_balance: 'debit',
    is_active: true,
    is_header: false
  )
  puts "✅ Created COA account: 1000 - Cash - Operating"
end
puts "📋 COA: #{cash_acct.account_number} - #{cash_acct.name} (ID: #{cash_acct.id})"

# ── 2. Find or create bank account linked to Cash - Operating ──
bank_account = company.bank_accounts.find_by(chart_of_account_id: cash_acct.id)
unless bank_account
  bank_account = company.bank_accounts.create!(
    bank_name: 'First National Bank',
    account_type: 'checking',
    chart_of_account_id: cash_acct.id,
    institution_name: 'First National Bank',
    account_mask: '4521',
    is_active: true,
    current_balance: 0,
    location_id: location&.id,
    created_by: user.id.to_s
  )
  puts "✅ Created bank account: First National Bank (ID: #{bank_account.id})"
end
puts "🏦 Bank Account: #{bank_account.bank_name || bank_account.institution_name} (ID: #{bank_account.id})"

# ── 3. Clean up previous test data ──
previous_jes = company.journal_entries.where(source_type: 'recon_test_seed')
if previous_jes.any?
  count = previous_jes.count
  previous_jes.destroy_all
  puts "🗑️  Removed #{count} previous test journal entries"
end

previous_recons = BankReconciliation.where(bank_account_id: bank_account.id)
if previous_recons.any?
  count = previous_recons.count
  previous_recons.destroy_all
  puts "🗑️  Removed #{count} previous test reconciliations"
end

# ── 4. Find offset accounts for double-entry ──
revenue_acct = company.chart_of_accounts.find_by(account_number: '4000') ||
               company.chart_of_accounts.where(account_type: 'revenue', is_header: false).first
expense_acct = company.chart_of_accounts.find_by(account_number: '6000') ||
               company.chart_of_accounts.where(account_type: 'expense', is_header: false).first
ap_acct      = company.chart_of_accounts.find_by(account_number: '2000') ||
               company.chart_of_accounts.where(account_type: 'liability', is_header: false).first

puts "📋 Revenue offset: #{revenue_acct&.account_number} - #{revenue_acct&.name}"
puts "📋 Expense offset: #{expense_acct&.account_number} - #{expense_acct&.name}"
puts "📋 AP offset: #{ap_acct&.account_number} - #{ap_acct&.name}"

# ── 5. Create journal entries for April 2026 (statement period) ──
# Mix of deposits (debits to cash) and payments (credits from cash)

entries_data = [
  # DEPOSITS (debit cash, credit revenue/other)
  { date: '2026-04-02', memo: 'Home sale deposit - Johnson',    amount: 15000.00, type: :deposit },
  { date: '2026-04-05', memo: 'Home sale deposit - Williams',   amount: 28000.00, type: :deposit },
  { date: '2026-04-08', memo: 'Service invoice payment',        amount: 1250.00,  type: :deposit },
  { date: '2026-04-10', memo: 'Parts counter sale',             amount: 435.50,   type: :deposit },
  { date: '2026-04-12', memo: 'Home sale deposit - Davis',      amount: 72000.00, type: :deposit },
  { date: '2026-04-15', memo: 'Setup fee collection',           amount: 3500.00,  type: :deposit },
  { date: '2026-04-18', memo: 'Finance reserve income',         amount: 2100.00,  type: :deposit },
  { date: '2026-04-22', memo: 'Home sale deposit - Martinez',   amount: 45000.00, type: :deposit },
  { date: '2026-04-25', memo: 'Warranty reimbursement',         amount: 850.00,   type: :deposit },
  { date: '2026-04-28', memo: 'Parts counter sale',             amount: 612.75,   type: :deposit },

  # PAYMENTS (credit cash, debit expense/AP)
  { date: '2026-04-01', memo: 'Lot rent - April',               amount: 12000.00, type: :payment },
  { date: '2026-04-03', memo: 'Electric bill',                  amount: 485.20,   type: :payment },
  { date: '2026-04-05', memo: 'Insurance premium',              amount: 3500.00,  type: :payment },
  { date: '2026-04-07', memo: 'Office supplies - Staples',      amount: 127.45,   type: :payment },
  { date: '2026-04-10', memo: 'Floor plan interest payment',    amount: 4200.00,  type: :payment },
  { date: '2026-04-14', memo: 'Payroll - biweekly',             amount: 18500.00, type: :payment },
  { date: '2026-04-17', memo: 'Advertising - Facebook ads',     amount: 1500.00,  type: :payment },
  { date: '2026-04-20', memo: 'Contractor - HVAC install',      amount: 2800.00,  type: :payment },
  { date: '2026-04-23', memo: 'Water & sewer bill',             amount: 215.30,   type: :payment },
  { date: '2026-04-25', memo: 'Legal fees - attorney',          amount: 750.00,   type: :payment },
  { date: '2026-04-28', memo: 'Payroll - biweekly',             amount: 18500.00, type: :payment },
  { date: '2026-04-30', memo: 'Internet & phone bill',          amount: 389.00,   type: :payment },

  # A couple entries that will be "outstanding" (not on the bank statement)
  { date: '2026-04-29', memo: 'Check #1042 - parts vendor',     amount: 1875.00,  type: :payment },
  { date: '2026-04-30', memo: 'Mobile deposit - late sale',      amount: 5200.00,  type: :deposit },
]

created_count = 0
total_deposits = 0
total_payments = 0

entries_data.each do |entry|
  je = company.journal_entries.build(
    entry_date:  Date.parse(entry[:date]),
    memo:        entry[:memo],
    source_type: 'recon_test_seed',
    is_void:     false,
    posted_by:   user
  )

  if entry[:type] == :deposit
    # Deposit: debit cash, credit revenue
    je.journal_entry_lines.build(
      chart_of_account: cash_acct,
      debit_amount: entry[:amount],
      credit_amount: 0,
      memo: entry[:memo],
      location_id: location&.id
    )
    je.journal_entry_lines.build(
      chart_of_account: revenue_acct,
      debit_amount: 0,
      credit_amount: entry[:amount],
      memo: entry[:memo],
      location_id: location&.id
    )
    total_deposits += entry[:amount]
  else
    # Payment: credit cash, debit expense
    je.journal_entry_lines.build(
      chart_of_account: cash_acct,
      debit_amount: 0,
      credit_amount: entry[:amount],
      memo: entry[:memo],
      location_id: location&.id
    )
    je.journal_entry_lines.build(
      chart_of_account: expense_acct || ap_acct,
      debit_amount: entry[:amount],
      credit_amount: 0,
      memo: entry[:memo],
      location_id: location&.id
    )
    total_payments += entry[:amount]
  end

  if je.save
    created_count += 1
  else
    puts "  ⚠️  Failed: #{entry[:memo]}: #{je.errors.full_messages.join(', ')}"
  end
end

puts "\n✅ Created #{created_count} journal entries"
puts "   Deposits: $#{total_deposits.round(2)} (#{entries_data.count { |e| e[:type] == :deposit }} entries)"
puts "   Payments: $#{total_payments.round(2)} (#{entries_data.count { |e| e[:type] == :payment }} entries)"

# ── 6. Calculate expected statement balance ──
# The bank statement would show all CLEARED items.
# We'll make the last 2 entries "outstanding" (not on the statement yet).
# Outstanding: Check #1042 ($1,875 payment) + mobile deposit ($5,200 deposit)
# So statement balance = beginning + cleared deposits - cleared payments

beginning_balance = 50000.00  # Pretend the account started April with $50k
cleared_deposits = total_deposits - 5200.00   # Subtract outstanding deposit
cleared_payments = total_payments - 1875.00   # Subtract outstanding check
statement_ending = beginning_balance + cleared_deposits - cleared_payments

puts "\n📊 Expected Reconciliation:"
puts "   Beginning Balance: $#{beginning_balance}"
puts "   Cleared Deposits:  $#{cleared_deposits.round(2)}"
puts "   Cleared Payments:  $#{cleared_payments.round(2)}"
puts "   Statement Ending:  $#{statement_ending.round(2)}"
puts "   Outstanding deposit: $5,200.00 (mobile deposit - late sale)"
puts "   Outstanding check:   $1,875.00 (Check #1042 - parts vendor)"

# ── 7. Create the reconciliation via the service (populates items from JE lines) ──
service = BankReconciliationService.new(company)
reconciliation = service.start(
  bank_account: bank_account,
  statement_date: Date.new(2026, 4, 30),
  statement_ending_balance: BigDecimal(statement_ending.to_s)
)

# Handle both Hash result and AR object
if reconciliation.is_a?(Hash) && reconciliation[:error]
  puts "❌ Failed to create reconciliation: #{reconciliation[:error]}"
  exit
end

# The service may return a hash with the reconciliation or the object directly
recon = reconciliation.is_a?(BankReconciliation) ? reconciliation : BankReconciliation.last

# Set the beginning balance (service may not accept it)
if recon.beginning_balance.to_f.zero? && beginning_balance > 0
  recon.update_column(:beginning_balance, beginning_balance)
end

item_count = recon.bank_reconciliation_items.count

puts "\n✅ Created reconciliation ID: #{recon.id}"
puts "   Bank Account: #{bank_account.bank_name || bank_account.institution_name}"
puts "   Statement Date: #{recon.statement_date}"
puts "   Statement Balance: $#{recon.statement_ending_balance}"
puts "   Beginning Balance: $#{recon.beginning_balance}"
puts "   Items loaded: #{item_count}"

puts "\n🔄 Navigate to: /accounting/reconciliation/#{recon.id}"
puts "\n📋 Test Steps:"
puts "   1. Open the reconciliation"
puts "   2. You should see #{entries_data.length} journal entry lines to clear"
puts "   3. Check all items EXCEPT the last 2 (outstanding check + outstanding deposit)"
puts "   4. Difference should reach $0.00 when correct items are checked"
puts "   5. Click 'Complete reconciliation' when difference = $0"
puts "\n✅ Done!"
