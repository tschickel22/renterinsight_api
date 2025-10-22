#!/usr/bin/env ruby
# Test script to verify all Land Parcel fields are saving correctly

# This script creates a test parcel with ALL fields populated,
# then checks what actually saved to the database

puts "="*80
puts "LAND PARCEL FIELD VALIDATION TEST"
puts "="*80
puts ""

# Define all fields that SHOULD be saveable
expected_fields = {
  parcel_number: "TEST-#{Time.now.to_i}",
  name: "Test Parcel Full",
  address: "123 Test Street",
  city: "Test City",
  state: "TX",
  zip: "78701",
  county: "Test County",
  latitude: 30.2672,
  longitude: -97.7431,
  acreage: 5.5,
  zoning_type: "residential",
  status: "available",
  price: 75000.00,
  price_per_acre: 13636.36,
  owner_name: "John Test Owner",
  owner_phone: "(555) 123-4567",
  owner_email: "owner@test.com",
  acquisition_date: "2025-01-15",
  description: "This is a test description with all fields populated.",
  notes: "These are internal test notes.",
  utilities: {
    water: true,
    sewer: true,
    electric: true,
    gas: false
  },
  features: ["wooded", "level", "corner lot"],
  images: ["data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="],
  documents: []
}

# Get the first company for testing
company = Company.first

unless company
  puts "ERROR: No company found in database!"
  exit 1
end

puts "Testing with Company: #{company.name} (ID: #{company.id})"
puts ""

# Create the test parcel
puts "Creating test parcel with ALL fields populated..."
parcel = company.land_parcels.new(expected_fields)
parcel.created_by = 1

if parcel.save
  puts "✓ Parcel created successfully (ID: #{parcel.id})"
  puts ""
  
  # Reload from database to ensure we're checking what was actually saved
  parcel.reload
  
  # Check each field
  puts "FIELD VALIDATION RESULTS:"
  puts "-" * 80
  
  missing_fields = []
  incorrect_fields = []
  successful_fields = []
  
  expected_fields.each do |field, expected_value|
    actual_value = parcel.send(field)
    
    if actual_value.nil? && !expected_value.nil?
      missing_fields << field
      puts "✗ #{field.to_s.ljust(25)} MISSING (expected: #{expected_value.inspect})"
    elsif actual_value != expected_value && !(actual_value.is_a?(Float) && expected_value.is_a?(Float) && (actual_value - expected_value).abs < 0.01)
      # For floats, allow small differences due to rounding
      if field == :utilities || field == :features || field == :images || field == :documents
        # JSON fields might have different representations
        if actual_value.to_json == expected_value.to_json
          successful_fields << field
          puts "✓ #{field.to_s.ljust(25)} #{actual_value.inspect}"
        else
          incorrect_fields << field
          puts "⚠ #{field.to_s.ljust(25)} MISMATCH"
          puts "  Expected: #{expected_value.inspect}"
          puts "  Actual:   #{actual_value.inspect}"
        end
      else
        incorrect_fields << field
        puts "⚠ #{field.to_s.ljust(25)} MISMATCH"
        puts "  Expected: #{expected_value.inspect}"
        puts "  Actual:   #{actual_value.inspect}"
      end
    else
      successful_fields << field
      puts "✓ #{field.to_s.ljust(25)} #{actual_value.inspect}"
    end
  end
  
  puts ""
  puts "="*80
  puts "SUMMARY"
  puts "="*80
  puts "Total fields tested:     #{expected_fields.count}"
  puts "✓ Successfully saved:    #{successful_fields.count}"
  puts "⚠ Mismatched values:     #{incorrect_fields.count}"
  puts "✗ Missing/null values:   #{missing_fields.count}"
  puts ""
  
  if missing_fields.any?
    puts "MISSING FIELDS:"
    missing_fields.each { |f| puts "  - #{f}" }
    puts ""
  end
  
  if incorrect_fields.any?
    puts "MISMATCHED FIELDS:"
    incorrect_fields.each { |f| puts "  - #{f}" }
    puts ""
  end
  
  # Check database schema
  puts "DATABASE SCHEMA CHECK:"
  puts "-" * 80
  
  db_columns = LandParcel.column_names
  expected_field_names = expected_fields.keys.map(&:to_s)
  
  missing_columns = expected_field_names - db_columns
  if missing_columns.any?
    puts "⚠ Fields that don't exist in database:"
    missing_columns.each { |col| puts "  - #{col}" }
  else
    puts "✓ All expected fields exist in database schema"
  end
  puts ""
  
  # Clean up - delete test parcel
  puts "Cleaning up test data..."
  parcel.destroy
  puts "✓ Test parcel deleted"
  
else
  puts "✗ FAILED TO CREATE PARCEL"
  puts ""
  puts "Validation Errors:"
  parcel.errors.full_messages.each do |error|
    puts "  - #{error}"
  end
  puts ""
  puts "Attempted to save these attributes:"
  parcel.attributes.each do |key, value|
    puts "  #{key}: #{value.inspect}"
  end
end

puts ""
puts "="*80
puts "TEST COMPLETE"
puts "="*80
