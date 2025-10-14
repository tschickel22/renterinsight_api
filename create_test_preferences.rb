#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 4D Test Data Script
# Creates test data for Communication Preferences API

require_relative 'config/environment'

puts "🚀 Phase 4D: Creating Test Data for Communication Preferences\n\n"

# Find or create test source
source = Source.find_or_create_by!(name: 'Test Source') do |s|
  s.source_type = 'website'
  s.is_active = true
end

# Create test lead (buyer)
lead = Lead.find_or_create_by!(email: 'testbuyer@example.com') do |l|
  l.first_name = 'Test'
  l.last_name = 'Buyer'
  l.phone = '555-0100'
  l.source = source
end

puts "✅ Created/found test lead: #{lead.email}"

# Create portal access with preferences
portal_access = BuyerPortalAccess.find_or_create_by!(buyer: lead) do |pa|
  pa.email = lead.email
  pa.password = 'TestPassword123!'
  pa.email_opt_in = true
  pa.sms_opt_in = true
  pa.marketing_opt_in = false
  pa.portal_enabled = true
end

puts "✅ Created portal access for #{lead.email}"
puts "   - Email opt-in: #{portal_access.email_opt_in}"
puts "   - SMS opt-in: #{portal_access.sms_opt_in}"
puts "   - Marketing opt-in: #{portal_access.marketing_opt_in}"
puts "   - Portal enabled: #{portal_access.portal_enabled}\n\n"

# Create some preference history
puts "Creating preference history..."
portal_access.update!(email_opt_in: false)
sleep 0.5
portal_access.update!(sms_opt_in: false)
sleep 0.5
portal_access.update!(marketing_opt_in: true)
sleep 0.5
portal_access.update!(email_opt_in: true)

puts "✅ Created 4 preference changes in history\n\n"

# Generate JWT token for API testing
token = JWT.encode(
  { 
    buyer_id: lead.id,
    buyer_type: 'Lead',
    exp: 24.hours.from_now.to_i 
  },
  Rails.application.secret_key_base,
  'HS256'
)

puts "🔑 JWT Token (valid for 24 hours):"
puts token
puts "\n"

# Output curl commands for testing
puts "=" * 80
puts "📋 CURL COMMANDS FOR TESTING"
puts "=" * 80
puts "\n"

puts "1️⃣  GET PREFERENCES"
puts "curl -X GET http://localhost:3001/api/portal/preferences \\"
puts "  -H 'Authorization: Bearer #{token}' \\"
puts "  -H 'Content-Type: application/json'"
puts "\n"

puts "2️⃣  UPDATE PREFERENCES (disable email)"
puts "curl -X PATCH http://localhost:3001/api/portal/preferences \\"
puts "  -H 'Authorization: Bearer #{token}' \\"
puts "  -H 'Content-Type: application/json' \\"
puts "  -d '{\"preferences\": {\"email_opt_in\": false}}'"
puts "\n"

puts "3️⃣  UPDATE MULTIPLE PREFERENCES"
puts "curl -X PATCH http://localhost:3001/api/portal/preferences \\"
puts "  -H 'Authorization: Bearer #{token}' \\"
puts "  -H 'Content-Type: application/json' \\"
puts "  -d '{\"preferences\": {\"email_opt_in\": true, \"sms_opt_in\": false, \"marketing_opt_in\": true}}'"
puts "\n"

puts "4️⃣  GET PREFERENCE HISTORY"
puts "curl -X GET http://localhost:3001/api/portal/preferences/history \\"
puts "  -H 'Authorization: Bearer #{token}' \\"
puts "  -H 'Content-Type: application/json'"
puts "\n"

puts "5️⃣  TRY TO DISABLE PORTAL (should fail)"
puts "curl -X PATCH http://localhost:3001/api/portal/preferences \\"
puts "  -H 'Authorization: Bearer #{token}' \\"
puts "  -H 'Content-Type: application/json' \\"
puts "  -d '{\"preferences\": {\"portal_enabled\": false}}'"
puts "\n"

puts "6️⃣  INVALID BOOLEAN VALUE (should fail)"
puts "curl -X PATCH http://localhost:3001/api/portal/preferences \\"
puts "  -H 'Authorization: Bearer #{token}' \\"
puts "  -H 'Content-Type: application/json' \\"
puts "  -d '{\"preferences\": {\"email_opt_in\": \"yes\"}}'"
puts "\n"

puts "=" * 80
puts "✨ Test data created successfully!"
puts "=" * 80
puts "\n"
puts "Credentials:"
puts "  Email: #{lead.email}"
puts "  Password: TestPassword123!"
puts "\n"
puts "Current Preferences:"
puts "  email_opt_in: #{portal_access.reload.email_opt_in}"
puts "  sms_opt_in: #{portal_access.sms_opt_in}"
puts "  marketing_opt_in: #{portal_access.marketing_opt_in}"
puts "  portal_enabled: #{portal_access.portal_enabled}"
puts "\n"
puts "History Entries: #{portal_access.preference_history.length}"
puts "\n"
