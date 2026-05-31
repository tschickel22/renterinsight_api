namespace :deals do
  desc "Backfill deal pricing from vehicles"
  task backfill_vehicle_pricing: :environment do
    puts "🔄 Starting deal vehicle pricing backfill..."
    
    updated_count = 0
    skipped_count = 0
    error_count = 0
    
    # Find all deals with vehicle_id but missing pricing
    deals = Deal.where.not(vehicle_id: nil)
                .where("selling_price IS NULL OR unit_cost IS NULL OR value IS NULL OR value = 0")
    
    total = deals.count
    puts "📊 Found #{total} deals with vehicles but missing pricing data"
    
    deals.find_each.with_index do |deal, index|
      begin
        vehicle = deal.vehicle
        
        unless vehicle
          puts "  ⚠️  Deal ##{deal.id}: Vehicle ##{deal.vehicle_id} not found"
          skipped_count += 1
          next
        end
        
        updates = {}
        
        # Get vehicle price (sale_price or msrp)
        vehicle_price = vehicle.sale_price || vehicle.msrp
        
        # Only update if field is blank or zero
        if deal.selling_price.nil? || deal.selling_price == 0
          updates[:selling_price] = vehicle_price
        end
        
        if deal.unit_cost.nil? || deal.unit_cost == 0
          updates[:unit_cost] = vehicle.cost
        end
        
        if deal.value.nil? || deal.value == 0
          updates[:value] = vehicle_price || 0
        end
        
        if deal.quantity.nil?
          updates[:quantity] = 1
        end
        
        if updates.any?
          deal.update_columns(updates)
          updated_count += 1
          
          if (index + 1) % 10 == 0
            puts "  ✓ Processed #{index + 1}/#{total} deals (#{updated_count} updated)"
          end
        else
          skipped_count += 1
        end
        
      rescue StandardError => e
        puts "  ❌ Error processing deal ##{deal.id}: #{e.message}"
        error_count += 1
      end
    end
    
    puts "\n✅ Backfill complete!"
    puts "  📈 Updated: #{updated_count} deals"
    puts "  ⏭️  Skipped: #{skipped_count} deals (no vehicle or already had pricing)"
    puts "  ❌ Errors: #{error_count} deals"
  end
  
  # Backfills deal.vehicle_id for deals whose vehicle FK was never set even though a
  # vehicle line item exists in deal_products. Idempotent — safe to re-run. Conservative:
  # acts only when the line item carries an unambiguous VEHICLE-<id> SKU AND the
  # referenced vehicle lives in the same company. Multi-vehicle / cross-company / missing
  # cases are reported for human review and skipped.
  desc "Backfill deal.vehicle_id from VEHICLE-<id> line items in deal_products"
  task backfill_vehicle_links_from_products: :environment do
    puts "🔄 Starting deal vehicle-link backfill from deal_products..."

    sku_pattern = /\AVEHICLE-(\d+)\z/i
    sql_pattern = '^VEHICLE-[0-9]+$'

    candidate_deals = Deal.where(vehicle_id: nil)
      .where(id: DealProduct.where('product_sku ~* ?', sql_pattern).select(:deal_id))

    total = candidate_deals.count
    puts "📊 Found #{total} deals with NULL vehicle_id and a VEHICLE-<id> line item"

    linked = 0
    ambiguous = 0
    cross_company = 0
    missing_vehicle = 0
    errors = 0

    candidate_deals.find_each do |deal|
      begin
        vehicle_ids = deal.deal_products
          .where('product_sku ~* ?', sql_pattern)
          .pluck(:product_sku)
          .map { |sku| sku.to_s.match(sku_pattern)&.[](1)&.to_i }
          .compact
          .uniq

        if vehicle_ids.size > 1
          puts "  ⚠️  Deal ##{deal.id}: ambiguous — #{vehicle_ids.size} vehicle line items #{vehicle_ids.inspect}; skipping"
          ambiguous += 1
          next
        end

        vehicle_id = vehicle_ids.first
        next unless vehicle_id

        unless deal.company_id.present?
          puts "  ⚠️  Deal ##{deal.id}: no company_id; skipping"
          errors += 1
          next
        end

        vehicle = Vehicle.find_by(id: vehicle_id)
        unless vehicle
          puts "  ⚠️  Deal ##{deal.id}: line item references vehicle ##{vehicle_id} but vehicle not found; skipping"
          missing_vehicle += 1
          next
        end

        if vehicle.company_id != deal.company_id
          puts "  ⚠️  Deal ##{deal.id} (company #{deal.company_id}): vehicle ##{vehicle_id} belongs to company #{vehicle.company_id}; skipping"
          cross_company += 1
          next
        end

        deal.update!(vehicle_id: vehicle_id)
        linked += 1
        puts "  ✓ Deal ##{deal.id} → vehicle ##{vehicle_id}"
      rescue StandardError => e
        puts "  ❌ Error processing deal ##{deal.id}: #{e.message}"
        errors += 1
      end
    end

    puts "\n✅ Backfill complete!"
    puts "  📈 Linked: #{linked} deals"
    puts "  ⚠️  Ambiguous (multi-vehicle): #{ambiguous}"
    puts "  ⚠️  Cross-company: #{cross_company}"
    puts "  ⚠️  Missing vehicle: #{missing_vehicle}"
    puts "  ❌ Errors: #{errors}"
  end

  # One-shot backfill for the new deal_products.source_type column. Conservative:
  # only tags rows where the SKU prefix gives an unambiguous signal. Untagged rows
  # stay NULL — writers will fill them in as they're updated.
  desc "Backfill deal_products.source_type from existing SKU prefixes"
  task backfill_deal_product_source_type: :environment do
    puts "🔄 Backfilling deal_products.source_type from SKU prefixes..."

    unless DealProduct.column_names.include?('source_type')
      puts "❌ deal_products.source_type column not present. Run migrations first."
      exit 1
    end

    mapping = {
      'vehicle'  => '^VEHICLE-',
      'part'     => '^PART-',
      'fee'      => '^FEE-',
      'fni'      => '^FNI-',
      'discount' => '^DISCOUNT-'
    }

    total_updated = 0
    mapping.each do |source_type, sql_pattern|
      count = DealProduct.where(source_type: nil)
        .where('product_sku ~* ?', sql_pattern)
        .update_all(source_type: source_type)
      puts "  ✓ Tagged #{count} rows as '#{source_type}'"
      total_updated += count
    end

    untagged = DealProduct.where(source_type: nil).count
    puts "\n✅ Backfill complete!"
    puts "  📈 Tagged: #{total_updated}"
    puts "  ⏭️  Left untagged (no recognizable SKU prefix): #{untagged}"
  end

  desc "Show deals with missing pricing"
  task check_missing_pricing: :environment do
    puts "🔍 Checking for deals with missing pricing..."
    
    deals_with_vehicle_no_price = Deal.where.not(vehicle_id: nil)
                                       .where("selling_price IS NULL OR unit_cost IS NULL")
                                       .count
    
    deals_with_vehicle_zero_value = Deal.where.not(vehicle_id: nil)
                                         .where(value: [nil, 0])
                                         .count
    
    total_deals = Deal.count
    deals_with_vehicles = Deal.where.not(vehicle_id: nil).count
    
    puts "📊 Deal Pricing Status:"
    puts "  Total Deals: #{total_deals}"
    puts "  Deals with Vehicles: #{deals_with_vehicles}"
    puts "  Missing selling_price/unit_cost: #{deals_with_vehicle_no_price}"
    puts "  Missing/zero value: #{deals_with_vehicle_zero_value}"
    
    if deals_with_vehicle_no_price > 0 || deals_with_vehicle_zero_value > 0
      puts "\n💡 Run 'rake deals:backfill_vehicle_pricing' to fix"
    else
      puts "\n✅ All deals with vehicles have pricing data!"
    end
  end
end
