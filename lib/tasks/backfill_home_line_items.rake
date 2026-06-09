# Backfill a HOME line item onto deals where the home price still lives only on
# selling_price (Phase 2A groundwork — making the home a real line item).
#
# For deals that have a vehicle_id AND selling_price > 0 but NO home line item
# (DealProduct with SKU VEHICLE-<id>), create one:
#   product_sku  = VEHICLE-<vehicle_id>
#   product_name = vehicle.display_name
#   quantity     = 1
#   unit_price   = deal.selling_price
#   cost         = vehicle.structured_cost (nil-safe; left 0 when not entered)
#   notes        = 'category:home, source:home'
#
# Idempotent: deals that already have a home line item are skipped. This does NOT
# change deal economics — front_gross stays selling_price-based; the home line is
# tagged category:home (neither fee nor accessory), so front_end_addon_margin and
# the fee readers ignore it.
#
# DRY-RUN by default — prints what it WOULD create. Set APPLY=1 to write.
# Set COMPANY_ID=<id> to limit to one tenant.
#
#   bin/rails deals:backfill_home_line_items                 # dry-run, all companies
#   COMPANY_ID=47 bin/rails deals:backfill_home_line_items   # dry-run, company 47
#   COMPANY_ID=47 APPLY=1 bin/rails deals:backfill_home_line_items   # write
namespace :deals do
  desc "Backfill a home line item (VEHICLE-<id>) on deals with a vehicle + selling_price but no home line. DRY-RUN by default; APPLY=1 to write; COMPANY_ID=<id> to scope."
  task backfill_home_line_items: :environment do
    apply      = ENV['APPLY'] == '1'
    company_id = ENV['COMPANY_ID'].presence

    scope = Deal.active.where.not(vehicle_id: nil).where('selling_price > 0')
    scope = scope.where(company_id: company_id) if company_id

    mode = apply ? 'APPLY' : 'DRY-RUN'
    puts "[deals:backfill_home_line_items] mode=#{mode} company_id=#{company_id || 'ALL'}"

    would_create = 0
    created      = 0
    skipped_has  = 0
    skipped_veh  = 0

    scope.find_each do |deal|
      # has_home_line_item? now detects BOTH home-line formats — the Phase 3 FE's
      # `category:home`-tagged CUSTOM-<uuid> line as well as a VEHICLE-<id> line (see
      # DealProduct#home_line_item?). So deals that already carry a CUSTOM- home line are
      # correctly SKIPPED here — fixing the earlier double-add (the old check only saw
      # VEHICLE-<id> SKUs and re-added a home line to deals that already had one).
      if deal.has_home_line_item?
        skipped_has += 1
        next
      end

      vehicle = deal.vehicle
      # Tenant-isolation guard: only backfill from a vehicle in this deal's company.
      unless vehicle && vehicle.company_id == deal.company_id
        Rails.logger.warn(
          "[backfill_home_line_items] Deal #{deal.id}: vehicle #{deal.vehicle_id} missing or " \
          "cross-company (deal company #{deal.company_id}); skipping."
        )
        skipped_veh += 1
        next
      end

      attrs = {
        product_sku:  "VEHICLE-#{vehicle.id}",
        product_name: vehicle.display_name,
        quantity:     1,
        unit_price:   deal.selling_price,
        cost:         vehicle.structured_cost || 0,
        notes:        'category:home, source:home'
      }

      if apply
        deal.deal_products.create!(attrs)
        created += 1
        puts "  [APPLY]   Deal #{deal.id} (#{deal.deal_number}) co=#{deal.company_id}: " \
             "created #{attrs[:product_sku]} name='#{attrs[:product_name]}' " \
             "price=#{attrs[:unit_price]} cost=#{attrs[:cost]}"
      else
        would_create += 1
        puts "  [DRY-RUN] Deal #{deal.id} (#{deal.deal_number}) co=#{deal.company_id}: " \
             "WOULD create #{attrs[:product_sku]} name='#{attrs[:product_name]}' " \
             "price=#{attrs[:unit_price]} cost=#{attrs[:cost]}"
      end
    end

    puts "---"
    if apply
      puts "Created: #{created}; skipped (already have home line): #{skipped_has}; " \
           "skipped (no/cross-company vehicle): #{skipped_veh}"
    else
      puts "Would create: #{would_create}; skipped (already have home line): #{skipped_has}; " \
           "skipped (no/cross-company vehicle): #{skipped_veh}"
      puts "(DRY-RUN — re-run with APPLY=1 to write)"
    end
  end
end
