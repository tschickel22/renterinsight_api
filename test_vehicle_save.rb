#!/usr/bin/env ruby
# Test script to verify vehicle fields are saving correctly

require_relative 'config/environment'

puts "Testing Vehicle Field Mappings...\n\n"

company = Company.first
if company.nil?
  puts "❌ No company found. Please create a company first."
  exit 1
end

# Test MH with problematic fields
puts "Creating test Manufactured Home..."
mh_data = {
  listing_type: 'manufactured_home',
  vin: 'TEST123456789',
  make: 'Clayton',
  model: 'Test Model',
  year: 2024,
  serial_number: 'SN123456',
  location_city: 'Denver',
  location_state: 'CO',
  location_zip: '80202',
  address1: '123 Main St',
  bedrooms: 3,
  bathrooms: 2,
  home_type: 'Double Wide'
}

begin
  mh = company.vehicles.create!(mh_data)
  puts "✅ MH Created successfully!"
  puts "   VIN: #{mh.vin}"
  puts "   City: #{mh.location_city}"
  puts "   State: #{mh.location_state}"
  puts "   Zip: #{mh.location_zip}"
  puts "   Address1: #{mh.address1}"
rescue => e
  puts "❌ MH Creation failed: #{e.message}"
  puts "   #{e.backtrace.first}"
end

puts "\n"

# Test RV with problematic fields  
puts "Creating test RV..."
rv_data = {
  listing_type: 'rv',
  vin: 'RV123456789ABC',
  make: 'Winnebago',
  model: 'Test RV',
  year: 2024,
  mileage: 50000,
  location_city: 'Boulder',
  location_state: 'CO',
  location_zip: '80301'
}

begin
  rv = company.vehicles.create!(rv_data)
  puts "✅ RV Created successfully!"
  puts "   VIN: #{rv.vin}"
  puts "   City: #{rv.location_city}"
  puts "   State: #{rv.location_state}"
  puts "   Zip: #{rv.location_zip}"
rescue => e
  puts "❌ RV Creation failed: #{e.message}"
  puts "   #{e.backtrace.first}"
end

puts "\n✅ All tests completed!"
