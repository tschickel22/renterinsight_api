# frozen_string_literal: true

# Deals priced on a Deal Sheet before the sheet linked the deal's home
# (DealHomeLink). Lists what would change; APPLY=1 changes it.
#
#   bin/rails deal_homes:link_from_sheets                 # dry run, every company
#   COMPANY_ID=24 bin/rails deal_homes:link_from_sheets
#   APPLY=1 COMPANY_ID=24 bin/rails deal_homes:link_from_sheets
#
# An open deal points at the sheet's home, or the model's one "available to
# order" home. A won deal pointed at an "available to order" home gets the
# dealer's own copy, sold to that buyer, the way winning a deal does it.
namespace :deal_homes do
  desc 'Link deals priced on a Deal Sheet to their home (dry run unless APPLY=1)'
  task link_from_sheets: :environment do
    apply = ENV['APPLY'] == '1'
    builds = DealHomeBuild.where(live: true).joins(:deal).where(deals: { vehicle_id: nil, deleted_at: nil })
    builds = builds.where(company_id: ENV['COMPANY_ID']) if ENV['COMPANY_ID'].present?
    counts = Hash.new(0)

    builds.includes(:deal, :vehicle, :company).find_each do |build|
      deal = build.deal
      company = build.company
      next if company.lost_stage_keys.include?(deal.stage.to_s)

      home = build.vehicle || DealHomeLink.listing_for(company, build.variant, location_id: deal.location_id)
      unless home
        counts[:no_home] += 1
        puts "SKIP  co #{company.id} deal #{deal.id} #{deal.stage}: model #{build.catalog_plan_variant_id} has no single home in inventory"
        next
      end

      won = company.won_stage_keys.include?(deal.stage.to_s)
      plan = if won && home.catalog_row? then "copy of available-to-order home #{home.id} (#{DealHomeLink.title(home)}), sold to this buyer"
             else "home #{home.id} (#{DealHomeLink.title(home)}, #{home.status})"
             end
      puts "#{apply ? 'LINK' : 'WOULD'} co #{company.id} deal #{deal.id} #{deal.stage} #{deal.name}: #{plan}"
      counts[won ? :won : :open] += 1
      next unless apply

      ActiveRecord::Base.transaction do
        deal.update_columns(vehicle_id: home.id, updated_at: Time.current)
        DealVehicleStatusSync.mark_sold(deal, home) if won
      end
    end
    puts "#{apply ? 'Linked' : 'Would link'}: #{counts[:open]} open, #{counts[:won]} won. No single home: #{counts[:no_home]}."
  end
end
