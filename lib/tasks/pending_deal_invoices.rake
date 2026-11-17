# frozen_string_literal: true

# Closed deals awaiting approval from before deals got their draft sale invoice
# at close (DealInvoiceService#create_pending_invoice!). DRY_RUN=1 only counts.
# A deal that already has an invoice someone made by hand is skipped and
# listed: it may bill the sale already, and a draft on top would make it look
# billed twice. Approval shows those invoices and can cancel a duplicate.
namespace :deals do
  desc 'Give closed, unapproved deals their draft sale invoice (DRY_RUN=1 to count only)'
  task pending_invoices: :environment do
    dry = ENV['DRY_RUN'].present?
    made = 0
    failed = 0
    skipped = []
    Company.find_each do |company|
      next if AccountingSettings.for_company(company).try(:auto_post_deals)

      company.deals.where(deleted_at: nil, stage: company.won_stage_keys, gl_posted: [false, nil], deal_invoice_id: nil)
             .find_each do |deal|
        next if company.invoices.not_deleted.awaiting_deal_approval.where(source_id: deal.id).exists?

        others = company.invoices.not_deleted.where(deal_id: deal.id).where.not(status: 'cancelled').pluck(:invoice_number)
        if others.any?
          skipped << "company #{company.id} deal #{deal.id} #{deal.deal_number}: #{others.join(', ')}"
          next
        end

        made += 1
        next if dry

        DealInvoiceService.new(deal, user: deal.try(:owner)).create_pending_invoice!
      rescue => e
        failed += 1
        puts "Deal #{deal.id} (company #{company.id}): #{e.class}: #{e.message}"
      end
    end
    puts "#{dry ? 'Would make' : 'Made'} #{made - failed} draft invoices#{failed.positive? ? ", #{failed} failed" : ''}."
    puts "Skipped #{skipped.size} deals that already have an invoice (check them at approval):" if skipped.any?
    skipped.each { |line| puts "  #{line}" }
  end
end
