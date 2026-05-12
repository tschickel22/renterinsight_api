# frozen_string_literal: true

# Seed file: db/seeds/budget_test_actuals.rb
# Creates journal entries with realistic variance against existing budgets
# Run: bin/rails runner db/seeds/budget_test_actuals.rb

company = Company.find(47) # Summit Park
user = company.users.first || User.find(1)

puts "\n🧪 Budget Test Actuals Seeder"
puts "Company: #{company.name} (ID: #{company.id})"

budget = company.budgets.where(status: %w[active locked]).order(fiscal_year: :desc).first
unless budget
  puts "❌ No active/locked budget found. Activate or lock a budget first."
  exit
end

puts "📊 Using budget: #{budget.name} (FY #{budget.fiscal_year}, #{budget.status})"
puts "   #{budget.budget_lines.count} budget lines"

# Determine fiscal year date range
start_month = company.accounting_settings&.fiscal_year_start_month || 1
fy_start = Date.new(budget.fiscal_year, start_month, 1)
fy_end = (fy_start >> 12) - 1

puts "   Fiscal year: #{fy_start} to #{fy_end}"

# Clean up any previous test actuals for this fiscal year
previous = company.journal_entries.where(
  source_type: 'budget_test_seed',
  entry_date: fy_start..fy_end
)
if previous.any?
  count = previous.count
  previous.destroy_all
  puts "🗑️  Removed #{count} previous test entries"
end

# Variance patterns — makes the report interesting
# Each array has 12 multipliers (one per fiscal month)
# > 1.0 = over budget, < 1.0 = under budget
VARIANCE_PATTERNS = {
  # Revenue: strong spring/summer, weak winter — overall ~92% of budget
  revenue: [0.70, 0.75, 0.85, 0.95, 1.10, 1.15, 1.20, 1.10, 1.00, 0.90, 0.80, 0.55],
  # Expenses: mostly under but a few over — overall ~95% of budget
  expense: [0.88, 0.92, 0.95, 1.02, 0.97, 1.05, 1.08, 0.93, 0.96, 0.90, 0.85, 0.94],
  # COGS: tracks revenue pattern — overall ~90% of budget
  cost_of_goods_sold: [0.65, 0.72, 0.82, 0.92, 1.05, 1.12, 1.18, 1.08, 0.98, 0.88, 0.78, 0.52],
}.freeze

# Generate all 12 months for testing
months_to_generate = 12
puts "   Generating #{months_to_generate} months of actuals"

# Use the first asset account (e.g., Cash or Checking) as the offset
cash_account = company.chart_of_accounts
                      .where(is_active: true, is_header: false, account_type: 'asset')
                      .order(:account_number)
                      .first

unless cash_account
  puts "❌ No active asset account found for balancing entries."
  exit
end

puts "   Offset account: #{cash_account.account_number} - #{cash_account.name}"

created_count = 0
line_count = 0
skipped = 0

budget.budget_lines.includes(:chart_of_account).each do |bl|
  acct = bl.chart_of_account
  next unless acct&.is_active
  next if acct.is_header
  # Skip asset/liability/equity accounts — budgets for those aren't P&L
  next if %w[asset liability equity].include?(acct.account_type)

  pattern = VARIANCE_PATTERNS[acct.account_type.to_sym] ||
            VARIANCE_PATTERNS[:expense]

  (1..months_to_generate).each do |fiscal_month|
    budget_amount = bl.month_amount(fiscal_month).to_d
    next if budget_amount.zero?

    # Apply variance pattern + small random jitter (+/- 5%)
    multiplier = pattern[fiscal_month - 1] || 1.0
    jitter = 1.0 + (rand(-5..5) / 100.0)
    actual_amount = (budget_amount.abs * multiplier * jitter).round(2)
    next if actual_amount.zero?

    # Calculate the calendar date for this fiscal month
    cal_month = ((start_month - 1 + fiscal_month - 1) % 12) + 1
    cal_year = budget.fiscal_year + ((start_month - 1 + fiscal_month - 1) / 12)
    entry_date = Date.new(cal_year, cal_month, [15, Date.new(cal_year, cal_month, -1).day].min)

    # Build double-entry journal entry
    je = company.journal_entries.build(
      entry_date:   entry_date,
      memo:         "Budget test: #{acct.name} - #{entry_date.strftime('%B %Y')}",
      source_type:  'budget_test_seed',
      is_void:      false,
      posted_by:    user
    )

    if acct.normal_balance == 'debit'
      # Expense/COGS: debit the expense account, credit cash
      je.journal_entry_lines.build(
        chart_of_account: acct,
        debit_amount:     actual_amount,
        credit_amount:    0,
        memo:             acct.name,
        location_id:      budget.location_id
      )
      je.journal_entry_lines.build(
        chart_of_account: cash_account,
        debit_amount:     0,
        credit_amount:    actual_amount,
        memo:             "Offset: #{acct.name}",
        location_id:      budget.location_id
      )
    else
      # Revenue: credit the revenue account, debit cash
      je.journal_entry_lines.build(
        chart_of_account: acct,
        debit_amount:     0,
        credit_amount:    actual_amount,
        memo:             acct.name,
        location_id:      budget.location_id
      )
      je.journal_entry_lines.build(
        chart_of_account: cash_account,
        debit_amount:     actual_amount,
        credit_amount:    0,
        memo:             "Offset: #{acct.name}",
        location_id:      budget.location_id
      )
    end

    if je.save
      created_count += 1
      line_count += 2
    else
      skipped += 1
      puts "  ⚠️  Failed: #{acct.account_number} #{entry_date}: #{je.errors.full_messages.join(', ')}"
    end
  end
end

puts "\n✅ Created #{created_count} journal entries (#{line_count} lines)"
puts "⚠️  Skipped: #{skipped}" if skipped > 0
puts "\n📈 Expected variance highlights:"
puts "   Revenue: ~92% of budget (strong summer, weak winter) → RED dots"
puts "   Expenses: ~95% of budget (mostly favorable) → GREEN dots"
puts "   COGS: ~90% of budget (tracks revenue seasonality) → GREEN dots"
puts "   Net Income: Will vary by period selection"
puts "\n🔄 Refresh the Budget vs Actual report to see results!"
