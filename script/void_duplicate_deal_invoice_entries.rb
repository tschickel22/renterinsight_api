# frozen_string_literal: true

# Voids invoice journal entries that double-count a deal's sale.
#
# Approving a deal posts its closing entry (AR and revenue for the sale),
# then creates the deal's invoice as 'sent', which auto-posted the invoice
# too, so the sale was in AR and revenue twice. Invoice posting now skips a
# deal's sale invoice; this cleans up the ones already posted.
#
#   bin/rails runner script/void_duplicate_deal_invoice_entries.rb all           # preview every company
#   bin/rails runner script/void_duplicate_deal_invoice_entries.rb 4             # preview one company
#   bin/rails runner script/void_duplicate_deal_invoice_entries.rb all --apply   # void them
#
# Only voids an invoice entry when the deal's own closing entry is in the
# ledger, so the sale stays booked exactly once. A deal whose closing entry
# is missing is listed and left alone: its invoice entry is the only booking.
# Voiding adds a reversal dated today, so closed periods are untouched.
# One company per transaction, rolled back unless its books still tie.

target = ARGV[0] or abort 'usage: bin/rails runner script/void_duplicate_deal_invoice_entries.rb <company_id|all> [--apply]'
apply  = ARGV.include?('--apply')

def money(v) = format('%.2f', v.to_d)

def ties?(company)
  bs = Reports::BalanceSheetReportService.new(company).generate(as_of_date: Date.current)
  tb = Reports::TrialBalanceReportService.new(company).generate(as_of_date: Date.current)
  bs[:total_assets] == bs[:total_liabilities] + bs[:total_equity] && tb[:total_debits] == tb[:total_credits]
end

def deal_sale_invoices(company)
  company.invoices.where(source_type: %w[Deal deal_close])
         .or(company.invoices.where(id: company.deals.where.not(deal_invoice_id: nil).select(:deal_invoice_id)))
end

companies = target == 'all' ? Company.where(id: JournalEntry.distinct.select(:company_id)) : Company.where(id: target)
puts apply ? 'APPLYING — duplicate invoice entries will be voided' : 'PREVIEW — nothing will be changed (add --apply to void)'

found = 0
companies.find_each do |company|
  # Live entries only. A void's reversal also carries the invoice as its
  # source; counting it would "void" the reversal and restore the duplicate.
  invoice_entries = company.journal_entries.excluding_void_pairs.where(source_entity_type: 'Invoice')
  candidates = deal_sale_invoices(company).where(id: invoice_entries.select(:source_entity_id)).where.not(deal_id: nil)
  next unless candidates.exists?

  rows = candidates.map do |inv|
    deal_entry = company.journal_entries.in_ledger.where(source_entity_type: 'Deal', source_entity_id: inv.deal_id).exists?
    [inv, invoice_entries.where(source_entity_id: inv.id).to_a, deal_entry]
  end
  duplicates = rows.select { |_inv, _jes, deal_entry| deal_entry }
  next if duplicates.empty? && rows.none?

  found += 1
  puts "\n#{company.name} (id #{company.id}#{company.respond_to?(:account_number) ? ", #{company.account_number}" : ''})"
  rows.each do |inv, jes, deal_entry|
    status = deal_entry ? 'DUPLICATE — deal closing entry also books it' : 'keep — deal has no closing entry, this is the only booking'
    puts "  #{inv.invoice_number}  deal ##{inv.deal_id}  total #{money(inv.total)}  entries #{jes.map(&:entry_number).join(', ')}  #{status}"
  end
  puts "  To void: #{duplicates.size} (#{money(duplicates.sum { |inv, _j, _d| inv.total.to_d })})"
  next unless apply && duplicates.any?

  voided = false
  ActiveRecord::Base.transaction do
    duplicates.each { |_inv, jes, _d| jes.each { |je| je.void!(nil) } }
    raise ActiveRecord::Rollback unless ties?(company)

    voided = true
  end
  puts(voided ? "  Voided #{duplicates.sum { |_i, jes, _d| jes.size }} entries; balance sheet and trial balance tie." \
              : '  NOT VOIDED: the books would not tie afterwards, so this company was rolled back.')
rescue StandardError => e
  puts "  NOT VOIDED for #{company.name}: #{e.class}: #{e.message}"
end

summary = apply ? 'processed' : 'with deal invoices posted to the ledger'
puts "\n#{found.zero? ? 'No' : found} #{'company'.pluralize(found)} #{summary}."
