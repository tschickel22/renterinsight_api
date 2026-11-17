# frozen_string_literal: true

# Closed deals awaiting approval from before deals got their draft sale invoice
# at close (DealInvoiceService#create_pending_invoice!). DRY_RUN=1 only counts.
namespace :deals do
  desc 'Give closed, unapproved deals their draft sale invoice (DRY_RUN=1 to count only)'
  task pending_invoices: :environment do
    dry = ENV['DRY_RUN'].present?
    made = 0
    failed = 0
    Company.find_each do |company|
      next if AccountingSettings.for_company(company).try(:auto_post_deals)

      company.deals.where(deleted_at: nil, stage: company.won_stage_keys, gl_posted: [false, nil], deal_invoice_id: nil)
             .find_each do |deal|
        next if company.invoices.not_deleted.awaiting_deal_approval.where(source_id: deal.id).exists?

        made += 1
        next if dry

        DealInvoiceService.new(deal, user: deal.try(:owner)).create_pending_invoice!
      rescue => e
        failed += 1
        puts "Deal #{deal.id} (company #{company.id}): #{e.class}: #{e.message}"
      end
    end
    puts "#{dry ? 'Would make' : 'Made'} #{made - failed} draft invoices#{failed.positive? ? ", #{failed} failed" : ''}."
  end
end
