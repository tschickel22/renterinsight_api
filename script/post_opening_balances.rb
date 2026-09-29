# frozen_string_literal: true

# Posts opening balances that were typed on accounts before they became
# journal entries, so they sit in the ledger against Opening Balance Equity
# instead of being added at report time with a calculated offset.
#
#   bin/rails runner script/post_opening_balances.rb all            # preview every company
#   bin/rails runner script/post_opening_balances.rb 4              # preview one company
#   bin/rails runner script/post_opening_balances.rb all --apply    # post them
#
# Preview is the default and changes nothing. --apply posts one entry per
# account, one company per transaction, and re-checks that the company's
# balance sheet and trial balance still tie (rolling that company back if
# not). Safe to re-run: accounts already posted are skipped.

target = ARGV[0] or abort 'usage: bin/rails runner script/post_opening_balances.rb <company_id|all> [--apply]'
apply  = ARGV.include?('--apply')

def money(v) = format('%.2f', v.to_d)

def ties?(company)
  bs = Reports::BalanceSheetReportService.new(company).generate(as_of_date: Date.current)
  tb = Reports::TrialBalanceReportService.new(company).generate(as_of_date: Date.current)
  bs[:total_assets] == bs[:total_liabilities] + bs[:total_equity] && tb[:total_debits] == tb[:total_credits]
end

companies = target == 'all' ? Company.where(id: ChartOfAccount.where.not(opening_balance: [nil, 0]).select(:company_id)) : Company.where(id: target)
puts apply ? 'APPLYING — entries will be posted' : 'PREVIEW — nothing will be changed (add --apply to post)'

found = 0
companies.find_each do |company|
  legacy = AccountBalanceService.new(company).legacy_opening_balances(Date.new(9999, 12, 31)).order(:account_number).to_a
  next if legacy.empty?

  found += 1
  offset = legacy.sum { |a| a.normal_balance == 'debit' ? a.opening_balance.to_d : -a.opening_balance.to_d }
  puts "\n#{company.name} (id #{company.id}#{company.respond_to?(:account_number) ? ", #{company.account_number}" : ''})"
  legacy.each do |a|
    date = Accounting::OpeningBalancePostingService.new(a).entry_date
    puts "  #{a.account_number} #{a.name} [#{a.account_type}/#{a.normal_balance}] #{money(a.opening_balance)} dated #{date}"
  end
  puts "  Opening Balance Equity offset: #{money(offset)}"
  next unless apply

  posted = false
  ActiveRecord::Base.transaction do
    legacy.each { |a| Accounting::OpeningBalancePostingService.new(a).sync!(legacy_conversion: true) }
    raise ActiveRecord::Rollback unless ties?(company)

    posted = true
  end
  puts(posted ? "  Posted #{legacy.size} #{'entry'.pluralize(legacy.size)}; balance sheet and trial balance tie." \
              : '  NOT POSTED: the books would not tie afterwards, so this company was rolled back.')
rescue StandardError => e
  puts "  NOT POSTED for #{company.name}: #{e.class}: #{e.message}"
end

summary = apply ? 'processed' : 'with opening balances not yet posted'
puts "\n#{found.zero? ? 'No' : found} #{'company'.pluralize(found)} #{summary}."
