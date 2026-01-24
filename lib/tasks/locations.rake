# lib/tasks/locations.rake
namespace :locations do
  desc "Create missing default locations for all companies"
  task create_missing_defaults: :environment do
    puts "🔍 Checking all companies for missing default locations..."
    puts "=" * 70

    companies_without_locations = []
    companies_with_locations = []
    locations_created = 0

    Company.find_each do |company|
      active_locations = company.locations.where(is_deleted: false)
      
      if active_locations.count == 0
        companies_without_locations << company
      else
        companies_with_locations << company
      end
    end

    puts "\n📊 Summary:"
    puts "   Companies with locations: #{companies_with_locations.count}"
    puts "   Companies WITHOUT locations: #{companies_without_locations.count}"
    puts ""

    if companies_without_locations.any?
      puts "🔧 Creating default locations for companies without any..."
      puts "-" * 70
      
      companies_without_locations.each do |company|
        begin
          location = company.locations.create!(
            name: 'Main Location',
            active: true,
            is_deleted: false,
            created_by: 'system',
            updated_by: 'system'
          )
          
          locations_created += 1
          puts "   ✅ Company #{company.id}: #{company.name}"
          puts "      Created: Main Location (ID: #{location.id})"
          
        rescue => e
          puts "   ❌ Company #{company.id}: #{company.name}"
          puts "      Error: #{e.message}"
        end
      end
      
      puts "-" * 70
      puts "\n🎉 Created #{locations_created} default locations!"
    else
      puts "✅ All companies already have locations - nothing to do!"
    end

    puts "\n" + "=" * 70
    puts "✅ Complete!"
  end
end
