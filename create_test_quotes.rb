#!/usr/bin/env ruby
# frozen_string_literal: true
# Create test quotes for buyer portal testing

puts "🔧 Creating test data for Phase 4B - Quote Management..."

# Create or find required records
company = Company.first_or_create!(name: 'Test Company')
source = Source.first_or_create!(name: 'Portal') { |s| s.is_active = true }

# Find the existing test buyer from Phase 4A
lead = Lead.find_by(email: 'testbuyer@example.com')

if lead.nil?
  puts "❌ Test buyer not found. Please run Phase 4A setup first."
  exit 1
end

# Find or create account for the lead
account = if lead.is_converted && lead.converted_account_id.present?
  Account.find_by(id: lead.converted_account_id)
else
  Account.create!(
    company: company,
    name: "#{lead.first_name} #{lead.last_name} Account",
    email: lead.email,
    status: 'active'
  )
end

# Link lead to account if not already
unless lead.is_converted
  lead.update!(converted_account_id: account.id, is_converted: true)
end

puts "✅ Found buyer: #{lead.first_name} #{lead.last_name} (#{lead.email})"
puts "✅ Account: #{account.name} (ID: #{account.id})"

# Delete existing test quotes to start fresh
Quote.where(account: account).destroy_all

# Create test quotes with various statuses
quote1 = Quote.create!(
  account: account,
  quote_number: "Q-#{Time.current.year}-TEST-001",
  status: 'sent',
  subtotal: 1250.00,
  tax: 125.00,
  total: 1375.00,
  items: [
    { description: 'Oil Change Service', quantity: 1, unit_price: '45.00', total: '45.00' },
    { description: 'Tire Rotation', quantity: 1, unit_price: '35.00', total: '35.00' },
    { description: 'Brake Pad Replacement', quantity: 2, unit_price: '125.00', total: '250.00' },
    { description: 'Air Filter Replacement', quantity: 1, unit_price: '25.00', total: '25.00' }
  ],
  notes: 'Standard maintenance package with 1-year warranty on all parts',
  valid_until: 30.days.from_now.to_date,
  sent_at: Time.current,
  vehicle_id: 'VIN123',
  custom_fields: {
    vehicle_make: 'Toyota',
    vehicle_model: 'Camry',
    vehicle_year: 2020,
    mileage: 45000
  }
)

quote2 = Quote.create!(
  account: account,
  quote_number: "Q-#{Time.current.year}-TEST-002",
  status: 'viewed',
  subtotal: 2500.00,
  tax: 250.00,
  total: 2750.00,
  items: [
    { description: 'Transmission Service', quantity: 1, unit_price: '350.00', total: '350.00' },
    { description: 'Coolant Flush', quantity: 1, unit_price: '120.00', total: '120.00' },
    { description: 'Spark Plugs Replacement', quantity: 6, unit_price: '15.00', total: '90.00' }
  ],
  notes: 'Recommended 60k mile service package',
  valid_until: 15.days.from_now.to_date,
  sent_at: 2.days.ago,
  viewed_at: 1.day.ago,
  vehicle_id: 'VIN123',
  custom_fields: {
    vehicle_make: 'Toyota',
    vehicle_model: 'Camry',
    vehicle_year: 2020,
    mileage: 60000
  }
)

quote3 = Quote.create!(
  account: account,
  quote_number: "Q-#{Time.current.year}-TEST-003",
  status: 'accepted',
  subtotal: 850.00,
  tax: 85.00,
  total: 935.00,
  items: [
    { description: 'Battery Replacement', quantity: 1, unit_price: '180.00', total: '180.00' },
    { description: 'Serpentine Belt', quantity: 1, unit_price: '95.00', total: '95.00' }
  ],
  notes: 'Battery includes 3-year warranty',
  valid_until: 45.days.from_now.to_date,
  sent_at: 7.days.ago,
  viewed_at: 6.days.ago,
  accepted_at: 5.days.ago,
  vehicle_id: 'VIN123'
)

quote4 = Quote.create!(
  account: account,
  quote_number: "Q-#{Time.current.year}-TEST-004",
  status: 'draft',
  subtotal: 450.00,
  tax: 45.00,
  total: 495.00,
  items: [
    { description: 'Diagnostic Service', quantity: 1, unit_price: '120.00', total: '120.00' },
    { description: 'Potential Repair (TBD)', quantity: 1, unit_price: '0.00', total: '0.00' }
  ],
  notes: 'Draft quote - awaiting diagnostic results',
  valid_until: 20.days.from_now.to_date,
  vehicle_id: 'VIN456'
)

# Create one expired quote (create with future date, then update to past)
quote5 = Quote.create!(
  account: account,
  quote_number: "Q-#{Time.current.year}-TEST-005",
  status: 'sent',
  subtotal: 320.00,
  tax: 32.00,
  total: 352.00,
  items: [
    { description: 'Alignment Service', quantity: 1, unit_price: '95.00', total: '95.00' }
  ],
  notes: 'This quote has expired',
  valid_until: 10.days.from_now.to_date,  # Create with future date
  sent_at: 10.days.ago
)
# Now update to past date to make it expired
quote5.update_column(:valid_until, 5.days.ago.to_date)

puts ""
puts "✅ Created test quotes:"
puts "   Quote 1: #{quote1.quote_number} - #{quote1.status} - $#{quote1.total} (#{quote1.items.length} items)"
puts "   Quote 2: #{quote2.quote_number} - #{quote2.status} - $#{quote2.total} (#{quote2.items.length} items)"
puts "   Quote 3: #{quote3.quote_number} - #{quote3.status} - $#{quote3.total} (#{quote3.items.length} items)"
puts "   Quote 4: #{quote4.quote_number} - #{quote4.status} - $#{quote4.total} (#{quote4.items.length} items)"
puts "   Quote 5: #{quote5.quote_number} - #{quote5.status} (EXPIRED) - $#{quote5.total}"
puts ""
puts "🔐 Test credentials:"
puts "   Email: testbuyer@example.com"
puts "   Password: Password123!"
puts ""
puts "📋 Get JWT token:"
puts "curl -X POST http://localhost:3001/api/portal/auth/login \\"
puts "  -H 'Content-Type: application/json' \\"
puts "  -d '{\"email\":\"testbuyer@example.com\",\"password\":\"Password123!\"}'"
puts ""
puts "📋 Test endpoints (replace YOUR_TOKEN with JWT from login):"
puts ""
puts "# List all quotes:"
puts "curl -X GET http://localhost:3001/api/portal/quotes \\"
puts "  -H 'Authorization: Bearer YOUR_TOKEN'"
puts ""
puts "# Filter by status:"
puts "curl -X GET 'http://localhost:3001/api/portal/quotes?status=sent' \\"
puts "  -H 'Authorization: Bearer YOUR_TOKEN'"
puts ""
puts "# View single quote:"
puts "curl -X GET http://localhost:3001/api/portal/quotes/#{quote1.id} \\"
puts "  -H 'Authorization: Bearer YOUR_TOKEN'"
puts ""
puts "# Accept quote:"
puts "curl -X POST http://localhost:3001/api/portal/quotes/#{quote1.id}/accept \\"
puts "  -H 'Authorization: Bearer YOUR_TOKEN' \\"
puts "  -H 'Content-Type: application/json' \\"
puts "  -d '{\"notes\":\"Please schedule for Monday\"}'"
puts ""
puts "# Reject quote:"
puts "curl -X POST http://localhost:3001/api/portal/quotes/#{quote2.id}/reject \\"
puts "  -H 'Authorization: Bearer YOUR_TOKEN' \\"
puts "  -H 'Content-Type: application/json' \\"
puts "  -d '{\"reason\":\"Price is too high\"}'"
puts ""
puts "✅ Phase 4B test data ready!"
