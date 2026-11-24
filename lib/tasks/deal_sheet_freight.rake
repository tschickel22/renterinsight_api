# frozen_string_literal: true

# Deal Sheets used to fold freight into the deal's home line. They now write it
# as its own line (Truebuild::DealBuild::HOME_KINDS), so a commission plan paid
# on the home only leaves freight out. This rewrites the deals already priced.
#
#   bin/rails deal_sheets:split_freight                    # dry run, every company
#   bin/rails deal_sheets:split_freight COMPANY_ID=24
#   bin/rails deal_sheets:split_freight APPLY=1 COMPANY_ID=24
#
# An open deal is rewritten from its sheet as it stands (no repricing). A won or
# posted deal goes through the Deal Sheet correction path: its frozen price and
# cost follow the home line, a posted deal gets a journal entry for the
# difference, its invoice is recalculated, and so are unpaid commissions.
namespace :deal_sheets do
  desc 'Write Deal Sheet freight as its own deal line (dry run unless APPLY=1)'
  task split_freight: :environment do
    apply = ENV['APPLY'] == '1'
    builds = DealHomeBuild.where(live: true).joins(:deal).where(deals: { deleted_at: nil })
    builds = builds.where(company_id: ENV['COMPANY_ID']) if ENV['COMPANY_ID'].present?
    counts = Hash.new(0)

    builds.includes(:deal).find_each do |build|
      deal = build.deal
      # Only freight charged to the buyer becomes its own line; its cost stays on the home.
      freight = build.lines.select { |l| l.kind == 'freight' && l.priced? && !l.retail.to_d.zero? }
      next if freight.empty?
      next if freight.all? { |l| deal.deal_products.any? { |dp| dp.notes.to_s.include?("deal_sheet:#{l.id}") } }

      home = deal.home_line_item
      closed = deal.cost_snapshotted?
      retail = freight.sum { |l| l.retail.to_d }
      cost = freight.sum { |l| l.cost.to_d }
      puts "#{apply ? 'SPLIT' : 'WOULD'} co #{build.company_id} deal #{deal.id} #{deal.stage}#{' (closed)' if closed}#{' (posted)' if deal.gl_posted?}: " \
           "freight #{retail.to_s('F')} charged, #{cost.to_s('F')} cost, out of home line #{home&.unit_price.to_d.to_s('F')} / #{home&.cost.to_d.to_s('F')}"
      counts[closed ? :closed : :open] += 1
      next unless apply

      ActiveRecord::Base.transaction do
        if closed
          Truebuild::DealBuild.new(build, correcting_by: deal.owner || deal.primary_salesperson).send(:write_closed_deal!, nil)
        else
          Truebuild::DealBuild.new(build).send(:write_deal!, deal)
        end
      end
    rescue StandardError => e
      counts[:failed] += 1
      puts "FAILED deal #{build.deal_id}: #{e.class}: #{e.message}"
    end
    puts "#{apply ? 'Split' : 'Would split'}: #{counts[:open]} open, #{counts[:closed]} won or posted. Failed: #{counts[:failed]}."
  end
end
