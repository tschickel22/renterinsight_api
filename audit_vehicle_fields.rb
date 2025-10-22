#!/usr/bin/env ruby
# Comprehensive audit of ALL form fields vs database columns

require 'json'

puts "=" * 80
puts "COMPREHENSIVE FIELD AUDIT FOR RV AND MH INVENTORY FORMS"
puts "=" * 80
puts

# Extract all fields from RV Form
puts "📋 Reading RV Form fields..."
rv_form_path = '/mnt/c/Users/tschi/src/Platform_DMS_8.4.25/Platform_DMS_8.4.25/src/modules/inventory-management/forms/RVInventoryForm.tsx'
rv_form_content = File.read(rv_form_path)

rv_fields = []
# Extract from useState initialization
if rv_form_content =~ /const \[formData, setFormData\] = useState\(\{(.*?)\}\)/m
  form_data_block = $1
  form_data_block.scan(/(\w+):\s*initialData\?\.\w+/) do |match|
    rv_fields << match[0]
  end
end

puts "Found #{rv_fields.length} fields in RV form"
rv_fields.sort!

# Extract all fields from MH Form
puts "📋 Reading MH Form fields..."
mh_form_path = '/mnt/c/Users/tschi/src/Platform_DMS_8.4.25/Platform_DMS_8.4.25/src/modules/inventory-management/forms/MHInventoryForm.tsx'
mh_form_content = File.read(mh_form_path)

mh_fields = []
# Extract from useState initialization
if mh_form_content =~ /const \[formData, setFormData\] = useState\(\{(.*?)\}\)/m
  form_data_block = $1
  form_data_block.scan(/(\w+):\s*initialData\?\.\w+/) do |match|
    mh_fields << match[0]
  end
end

puts "Found #{mh_fields.length} fields in MH form"
mh_fields.sort!

# Read database schema
puts "📋 Reading database schema..."
schema_path = '/home/tschi/src/renterinsight_api/db/schema.rb'
schema_content = File.read(schema_path)

db_columns = []
if schema_content =~ /create_table "vehicles".*?do \|t\|(.*?)end/m
  vehicles_block = $1
  vehicles_block.scan(/t\.\w+\s+"(\w+)"/) do |match|
    db_columns << match[0]
  end
end

puts "Found #{db_columns.length} columns in vehicles table"
db_columns.sort!

# Read controller mappings
puts "📋 Reading controller field mappings..."
controller_path = '/home/tschi/src/renterinsight_api/app/controllers/api/v1/vehicles_controller.rb'
controller_content = File.read(controller_path)

# Extract field_mappings
mapped_fields = {}
if controller_content =~ /field_mappings = \{(.*?)\}/m
  mappings_block = $1
  mappings_block.scan(/(\w+):\s*:(\w+)/) do |camel, snake|
    mapped_fields[camel] = snake
  end
end

# Extract direct_fields
direct_fields = []
if controller_content =~ /direct_fields = \[(.*?)\]/m
  direct_block = $1
  direct_block.scan(/:(\w+)/) do |match|
    direct_fields << match[0]
  end
end

# Extract permit list
permitted_fields = []
if controller_content =~ /\.permit\((.*?)\)/m
  permit_block = $1
  permit_block.scan(/:(\w+)/) do |match|
    permitted_fields << match[0]
  end
end

puts "Found #{mapped_fields.length} field mappings"
puts "Found #{direct_fields.length} direct fields"
puts "Found #{permitted_fields.length} permitted fields"
puts

# Perform comprehensive audit
puts "=" * 80
puts "RV FORM FIELD AUDIT (#{rv_fields.length} fields)"
puts "=" * 80
puts

rv_missing = []
rv_unmapped = []
rv_unpermitted = []

rv_fields.each do |field|
  camel_field = field
  snake_field = mapped_fields[field] || field
  
  in_direct = direct_fields.include?(field)
  in_db = db_columns.include?(snake_field)
  in_permit = permitted_fields.include?(snake_field)
  
  status = "✅"
  issues = []
  
  if !in_db && !['images', 'videos', 'features', 'appliances'].include?(field)
    status = "❌"
    issues << "NOT IN DB"
    rv_missing << field
  end
  
  if !mapped_fields.key?(field) && !in_direct
    status = "⚠️ "
    issues << "NOT MAPPED"
    rv_unmapped << field
  end
  
  if !in_permit && !['images', 'videos', 'features', 'appliances'].include?(field)
    status = "⚠️ "
    issues << "NOT PERMITTED"
    rv_unpermitted << field
  end
  
  if issues.any?
    puts "#{status} #{field.ljust(30)} → #{snake_field.ljust(30)} [#{issues.join(', ')}]"
  end
end

if rv_missing.empty? && rv_unmapped.empty? && rv_unpermitted.empty?
  puts "✅ ALL RV FIELDS ARE PROPERLY CONFIGURED!"
else
  puts "\nSummary:"
  puts "❌ Missing from DB: #{rv_missing.length}" if rv_missing.any?
  puts "⚠️  Not mapped: #{rv_unmapped.length}" if rv_unmapped.any?
  puts "⚠️  Not permitted: #{rv_unpermitted.length}" if rv_unpermitted.any?
end

puts
puts "=" * 80
puts "MH FORM FIELD AUDIT (#{mh_fields.length} fields)"
puts "=" * 80
puts

mh_missing = []
mh_unmapped = []
mh_unpermitted = []

mh_fields.each do |field|
  camel_field = field
  snake_field = mapped_fields[field] || field
  
  in_direct = direct_fields.include?(field)
  in_db = db_columns.include?(snake_field)
  in_permit = permitted_fields.include?(snake_field)
  
  status = "✅"
  issues = []
  
  if !in_db && !['images', 'videos', 'features', 'appliances', 'location'].include?(field)
    status = "❌"
    issues << "NOT IN DB"
    mh_missing << field
  end
  
  if !mapped_fields.key?(field) && !in_direct
    status = "⚠️ "
    issues << "NOT MAPPED"
    mh_unmapped << field
  end
  
  if !in_permit && !['images', 'videos', 'features', 'appliances', 'location'].include?(field)
    status = "⚠️ "
    issues << "NOT PERMITTED"
    mh_unpermitted << field
  end
  
  if issues.any?
    puts "#{status} #{field.ljust(30)} → #{snake_field.ljust(30)} [#{issues.join(', ')}]"
  end
end

if mh_missing.empty? && mh_unmapped.empty? && mh_unpermitted.empty?
  puts "✅ ALL MH FIELDS ARE PROPERLY CONFIGURED!"
else
  puts "\nSummary:"
  puts "❌ Missing from DB: #{mh_missing.length}" if mh_missing.any?
  puts "⚠️  Not mapped: #{mh_unmapped.length}" if mh_unmapped.any?
  puts "⚠️  Not permitted: #{mh_unpermitted.length}" if mh_unpermitted.any?
end

puts
puts "=" * 80
puts "DETAILED FIELD LISTINGS"
puts "=" * 80

if rv_missing.any?
  puts "\n❌ RV Fields Missing from Database:"
  rv_missing.each { |f| puts "   - #{f}" }
end

if rv_unmapped.any?
  puts "\n⚠️  RV Fields Not Mapped in Controller:"
  rv_unmapped.each { |f| puts "   - #{f}" }
end

if rv_unpermitted.any?
  puts "\n⚠️  RV Fields Not in Permit List:"
  rv_unpermitted.each { |f| puts "   - #{f}" }
end

if mh_missing.any?
  puts "\n❌ MH Fields Missing from Database:"
  mh_missing.each { |f| puts "   - #{f}" }
end

if mh_unmapped.any?
  puts "\n⚠️  MH Fields Not Mapped in Controller:"
  mh_unmapped.each { |f| puts "   - #{f}" }
end

if mh_unpermitted.any?
  puts "\n⚠️  MH Fields Not in Permit List:"
  mh_unpermitted.each { |f| puts "   - #{f}" }
end

puts
puts "=" * 80
puts "AUDIT COMPLETE"
puts "=" * 80

total_issues = rv_missing.length + rv_unmapped.length + rv_unpermitted.length + 
               mh_missing.length + mh_unmapped.length + mh_unpermitted.length

if total_issues == 0
  puts "✅ ALL FIELDS ARE PROPERLY CONFIGURED!"
  puts "   All form fields are mapped to database columns and permitted in the controller."
else
  puts "⚠️  Found #{total_issues} configuration issues that need to be fixed."
end

puts
