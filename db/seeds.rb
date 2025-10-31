# frozen_string_literal: true

# Production & Test Users Setup
# Run with: bin/rails db:seed

puts "🔐 Creating Users..."

# Clear existing test users
User.where(email: [
  'admin@test.com', 
  'sarah.johnson@example.com', 
  'admin@renterinsight.com', 
  'client@test.com',
  't+admin@renterinsight.com',
  't+client@renterinsight.com'
]).destroy_all

# PRODUCTION ADMIN USER
admin_prod = User.create!(
  email: 't+admin@renterinsight.com',
  password: 'Mindzenty1!',
  password_confirmation: 'Mindzenty1!',
  first_name: 'Tom',
  last_name: 'Admin',
  role: 'admin',
  status: 'active'
)
puts "✅ Created PRODUCTION ADMIN: #{admin_prod.email}"

# PRODUCTION CLIENT USER
client_prod = User.create!(
  email: 't+client@renterinsight.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Tom',
  last_name: 'Client',
  role: 'client',
  status: 'active'
)
puts "✅ Created PRODUCTION CLIENT: #{client_prod.email}"

# TEST USERS (for development)
if Rails.env.development? || ENV['CREATE_TEST_USERS'] == 'true'

# Admin User 1
admin1 = User.create!(
  email: 'admin@test.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Admin',
  last_name: 'User',
  role: 'admin',
  status: 'active'
)
puts "✅ Created: #{admin1.email} (#{admin1.role})"

# Admin User 2
admin2 = User.create!(
  email: 'admin@renterinsight.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'System',
  last_name: 'Admin',
  role: 'admin',
  status: 'active'
)
puts "✅ Created: #{admin2.email} (#{admin2.role})"

# Client User 1
client1 = User.create!(
  email: 'sarah.johnson@example.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Sarah',
  last_name: 'Johnson',
  role: 'client',
  status: 'active'
)
puts "✅ Created: #{client1.email} (#{client1.role})"

# Client User 2
client2 = User.create!(
  email: 'client@test.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Test',
  last_name: 'Client',
  role: 'client',
  status: 'active'
)
puts "✅ Created: #{client2.email} (#{client2.role})"

# Staff User
staff = User.create!(
  email: 'staff@test.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Staff',
  last_name: 'Member',
  role: 'staff',
  status: 'active'
)
puts "✅ Created: #{staff.email} (#{staff.role})"

puts "\n🎉 Test Users Created!\n\n"
end

puts "=" * 60
puts "TEST CREDENTIALS"
puts "=" * 60
puts "\n📧 Admin Login:"
puts "   Email: admin@test.com"
puts "   Password: password123"
puts "   Dashboard: /admin/dashboard\n"
puts "\n📧 Client Login:"
puts "   Email: sarah.johnson@example.com"
puts "   Password: password123"
puts "   Dashboard: /client/dashboard\n"
puts "\n📧 Staff Login:"
puts "   Email: staff@test.com"
puts "   Password: password123"
puts "   Dashboard: /staff/dashboard\n"
puts "=" * 60

# Verify passwords work
puts "\n🔍 Verifying password authentication..."
test_user = User.find_by(email: 't+admin@renterinsight.com')
if test_user&.authenticate('Mindzenty1!')
  puts "✅ Production admin password authentication working correctly!"
else
  puts "❌ Production admin password authentication failed!"
end

# =============================================================================
# Communication Templates Seed Data
# =============================================================================
load Rails.root.join('db', 'seeds', 'communication_templates_company_user.rb')

# =============================================================================
# Land Parcels Seed Data
# =============================================================================
puts "\n\n🏞️ Creating Land Parcels..."

company = Company.first
if company.nil?
  puts "⚠️  No company found. Skipping land parcels seed."
else
  # Sample land parcels data
  parcels_data = [
    {
      parcel_number: 'LP-20251022-001',
      name: 'Sunset Ridge Acres',
      status: 'available',
      zoning_type: 'residential',
      acreage: 5.25,
      price: 250000,
      address: '1234 Mountain View Road',
      city: 'Phoenix',
      state: 'AZ',
      zip: '85001',
      county: 'Maricopa',
      latitude: 33.4484,
      longitude: -112.0740,
      utilities: { water: true, electric: true, sewer: false, gas: false },
      features: ['cleared', 'mountain_views', 'road_access', 'utilities_nearby'],
      description: 'Beautiful 5+ acre parcel with stunning mountain views. Perfect for your dream home.',
      owner_name: 'John Smith',
      owner_phone: '602-555-0100',
      acquisition_date: Date.today - 90.days
    },
    {
      parcel_number: 'LP-20251022-002',
      name: 'Downtown Commercial Plot',
      status: 'available',
      zoning_type: 'commercial',
      acreage: 2.5,
      price: 500000,
      address: '5678 Main Street',
      city: 'Denver',
      state: 'CO',
      zip: '80202',
      county: 'Denver',
      latitude: 39.7392,
      longitude: -104.9903,
      utilities: { water: true, electric: true, sewer: true, gas: true },
      features: ['cleared', 'high_traffic', 'corner_lot', 'all_utilities'],
      description: 'Prime commercial location in the heart of downtown.',
      owner_name: 'Denver Properties LLC',
      owner_phone: '303-555-0200',
      acquisition_date: Date.today - 60.days
    },
    {
      parcel_number: 'LP-20251022-003',
      name: 'Lakefront Paradise',
      status: 'pending',
      zoning_type: 'residential',
      acreage: 10.0,
      price: 400000,
      address: '9012 Lake Shore Drive',
      city: 'Boulder',
      state: 'CO',
      zip: '80301',
      county: 'Boulder',
      latitude: 40.0150,
      longitude: -105.2705,
      utilities: { water: true, electric: true, sewer: false, gas: false },
      features: ['wooded', 'waterfront', 'private', 'mountain_views'],
      description: '10 acres of lakefront property with mature trees.',
      owner_name: 'Mountain Lakes Trust',
      owner_phone: '303-555-0300',
      acquisition_date: Date.today - 120.days
    },
    {
      parcel_number: 'LP-20251022-004',
      name: 'Valley View Farm',
      status: 'available',
      zoning_type: 'agricultural',
      acreage: 50.0,
      price: 750000,
      address: '3456 County Road 42',
      city: 'Parker',
      state: 'CO',
      zip: '80138',
      county: 'Douglas',
      latitude: 39.5186,
      longitude: -104.7614,
      utilities: { water: true, electric: true, sewer: false, gas: false },
      features: ['irrigated', 'fenced', 'barn', 'well'],
      description: '50 acres of prime agricultural land. Fully fenced with irrigation rights.',
      owner_name: 'Valley Farms Inc',
      owner_phone: '720-555-0400',
      acquisition_date: Date.today - 30.days
    },
    {
      parcel_number: 'LP-20251022-005',
      name: 'Suburban Lot',
      status: 'sold',
      zoning_type: 'residential',
      acreage: 0.5,
      price: 180000,
      address: '7890 Meadow Lane',
      city: 'Scottsdale',
      state: 'AZ',
      zip: '85250',
      county: 'Maricopa',
      latitude: 33.5092,
      longitude: -111.8990,
      utilities: { water: true, electric: true, sewer: true, gas: true },
      features: ['cleared', 'flat', 'all_utilities', 'sidewalks'],
      description: 'Half-acre lot in established neighborhood. Ready to build.',
      owner_name: 'Sarah Johnson',
      owner_phone: '480-555-0500',
      acquisition_date: Date.today - 180.days
    },
    {
      parcel_number: 'LP-20251022-006',
      name: 'Industrial Park Site',
      status: 'under_contract',
      zoning_type: 'industrial',
      acreage: 15.0,
      price: 1200000,
      address: '1111 Industrial Boulevard',
      city: 'Denver',
      state: 'CO',
      zip: '80216',
      county: 'Denver',
      latitude: 39.7817,
      longitude: -104.9474,
      utilities: { water: true, electric: true, sewer: true, gas: true },
      features: ['level', 'paved_access', 'all_utilities', 'rail_access'],
      description: '15 acres zoned for industrial use. Level site with rail access.',
      owner_name: 'Industrial Partners LLC',
      owner_phone: '303-555-0600',
      acquisition_date: Date.today - 45.days
    },
    {
      parcel_number: 'LP-20251022-007',
      name: 'Creek Side Retreat',
      status: 'available',
      zoning_type: 'residential',
      acreage: 7.5,
      price: 325000,
      address: '2222 Forest Road',
      city: 'Evergreen',
      state: 'CO',
      zip: '80439',
      county: 'Jefferson',
      latitude: 39.6333,
      longitude: -105.3178,
      utilities: { water: false, electric: true, sewer: false, gas: false },
      features: ['wooded', 'creek_frontage', 'privacy', 'wildlife'],
      description: 'Beautiful mountain property with seasonal creek.',
      owner_name: 'Mountain Real Estate Co',
      owner_phone: '303-555-0700',
      acquisition_date: Date.today - 15.days
    },
    {
      parcel_number: 'LP-20251022-008',
      name: 'Desert Vista',
      status: 'available',
      zoning_type: 'residential',
      acreage: 2.25,
      price: 195000,
      address: '6666 Desert View Trail',
      city: 'Phoenix',
      state: 'AZ',
      zip: '85085',
      county: 'Maricopa',
      latitude: 33.7277,
      longitude: -112.0607,
      utilities: { water: true, electric: true, sewer: false, gas: false },
      features: ['desert_landscaping', 'views', 'privacy', 'utilities_nearby'],
      description: '2+ acres with incredible desert and mountain views.',
      owner_name: 'Desert Land Company',
      owner_phone: '623-555-1000',
      acquisition_date: Date.today - 10.days
    }
  ]
  
  # Create parcels
  created_count = 0
  parcels_data.each do |data|
    parcel = company.land_parcels.find_or_create_by(parcel_number: data[:parcel_number]) do |p|
      p.attributes = data
    end
    
    if parcel.persisted?
      created_count += 1
      puts "  ✅ #{parcel.display_name} (#{parcel.acreage} acres, #{parcel.status})"
    else
      puts "  ❌ Failed: #{data[:parcel_number]}"
    end
  end
  
  puts "\n🎉 Created #{created_count} land parcels!"
  puts "   Total active parcels: #{company.land_parcels.active.count}"
end
