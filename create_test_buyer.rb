#!/usr/bin/env ruby
# Create test buyer with all required associations

# Get or create company
company = Company.first_or_create!(name: 'Test Company')
puts "✅ Company: #{company.name}"

# Get or create source
source = Source.first_or_create!(name: 'Buyer Portal') do |s|
  s.source_type = 'portal'
  s.is_active = true
end
puts "✅ Source: #{source.name}"

# Delete existing test buyer if exists
Lead.where(email: 'testbuyer@example.com').destroy_all
BuyerPortalAccess.where(email: 'testbuyer@example.com').destroy_all

# Create lead with company AND source
lead = Lead.create!(
  company: company,
  source: source,
  first_name: 'Test',
  last_name: 'Buyer',
  email: 'testbuyer@example.com',
  phone: '555-1234'
)
puts "✅ Lead: #{lead.email}"

# Create portal access
portal = BuyerPortalAccess.create!(
  buyer: lead,
  email: 'testbuyer@example.com',
  password: 'Password123!',
  password_confirmation: 'Password123!',
  portal_enabled: true
)
puts "✅ Portal access: #{portal.email}"
puts ""
puts "🎉 Test buyer created successfully!"
puts ""
puts "Credentials:"
puts "  Email: testbuyer@example.com"
puts "  Password: Password123!"
puts ""
puts "Test with:"
puts "curl -X POST http://localhost:3001/api/portal/auth/login \\"
puts "  -H 'Content-Type: application/json' \\"
puts "  -d '{\"email\": \"testbuyer@example.com\", \"password\": \"Password123!\"}' | jq '.'"
