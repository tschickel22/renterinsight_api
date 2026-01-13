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
