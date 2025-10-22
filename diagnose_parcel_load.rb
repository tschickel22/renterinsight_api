#!/usr/bin/env ruby
# Diagnostic script to check what data is saved and what API returns

puts "="*80
puts "PARCEL DATA DIAGNOSTIC"
puts "="*80
puts ""

# Get the most recent parcel
parcel = LandParcel.last

unless parcel
  puts "No parcels found in database!"
  exit 1
end

puts "CHECKING PARCEL ID: #{parcel.id}"
puts "="*80
puts ""

puts "RAW DATABASE VALUES:"
puts "-"*80
attributes = parcel.attributes
attributes.each do |key, value|
  puts "#{key.ljust(25)} = #{value.inspect}"
end

puts ""
puts "="*80
puts "WHAT THE API WOULD RETURN (via parcel_json):"
puts "-"*80

# Simulate what the controller returns
base_url = "http://localhost:3001"
full_image_urls = (parcel.images || []).map do |url|
  url.start_with?('http') ? url : "#{base_url}#{url}"
end

api_response = {
  id: parcel.id.to_s,
  parcelNumber: parcel.parcel_number,
  name: parcel.name,
  displayName: parcel.display_name,
  status: parcel.status,
  zoningType: parcel.zoning_type,
  acreage: parcel.acreage&.to_f,
  price: parcel.price&.to_f,
  pricePerAcre: parcel.price_per_acre&.to_f,
  address: parcel.address,
  city: parcel.city,
  state: parcel.state,
  zip: parcel.zip,
  county: parcel.county,
  fullAddress: parcel.full_address,
  coordinates: parcel.coordinates,
  utilities: parcel.utilities || {},
  features: parcel.features || [],
  images: full_image_urls,
  documents: parcel.documents || [],
  description: parcel.description,
  notes: parcel.notes,
  ownerName: parcel.owner_name,
  ownerPhone: parcel.owner_phone,
  ownerEmail: parcel.owner_email,
  acquisitionDate: parcel.acquisition_date,
  createdAt: parcel.created_at,
  updatedAt: parcel.updated_at
}

api_response.each do |key, value|
  status = value.nil? ? "❌ NULL" : "✓"
  puts "#{status} #{key.to_s.ljust(25)} = #{value.inspect}"
end

puts ""
puts "="*80
puts "FIELDS WITH NO DATA (NULL):"
puts "-"*80

null_fields = api_response.select { |k, v| v.nil? || (v.is_a?(String) && v.empty?) }
if null_fields.any?
  null_fields.each do |field, _|
    puts "  - #{field}"
  end
else
  puts "  ✓ All fields have data!"
end

puts ""
puts "="*80
