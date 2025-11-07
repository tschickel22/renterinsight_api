#!/usr/bin/env ruby
# Check if Rails is using the correct ENV variables

require_relative 'config/environment'

puts "\n" + "="*70
puts "🔍 RAILS ENVIRONMENT CHECK"
puts "="*70

puts "\n1️⃣ ENV Variables in Rails:"
puts "   FRONTEND_URL = '#{ENV['FRONTEND_URL']}'"
puts "   PORTAL_URL = '#{ENV['PORTAL_URL']}'"

puts "\n2️⃣ Rails Environment:"
puts "   #{Rails.env}"

puts "\n3️⃣ Test URL Generation:"
test_invitation = Invitation.new(
  invitation_type: 'company_user',
  email: 'test@example.com',
  invited_by: User.first,
  company: Company.first,
  expires_at: 7.days.from_now,
  token_digest: 'test'
)
test_invitation.instance_variable_set(:@raw_token, 'TEST_TOKEN')

url = test_invitation.invitation_url
puts "   Generated URL: #{url}"

if url.start_with?('http://')
  puts "   ❌ PROBLEM: Generated URL is HTTP!"
elsif url.start_with?('https://')
  puts "   ✅ Generated URL is HTTPS"
end

puts "\n4️⃣ InvitationService Context Test:"
service = InvitationService.new(invited_by: User.first, company: Company.first)
context = service.send(:build_invitation_context, test_invitation, 'TEST_TOKEN')

puts "   invitation_url from context: #{context['invitation_url']}"

if context['invitation_url'].start_with?('http://')
  puts "   ❌ PROBLEM: Context URL is HTTP!"
elsif context['invitation_url'].start_with?('https://')
  puts "   ✅ Context URL is HTTPS"
end

puts "\n" + "="*70
puts "💡 RECOMMENDATIONS:"
puts "="*70

if url.start_with?('http://') || context['invitation_url'].start_with?('http://')
  puts "\n❌ Rails is NOT picking up FRONTEND_URL from .env!"
  puts "\n📋 To fix:"
  puts "   1. Stop Rails server (Ctrl+C)"
  puts "   2. Verify .env has: FRONTEND_URL=https://localhost:5173"
  puts "   3. Start Rails: rails s"
  puts "   4. Run this script again to verify"
elsif ENV['FRONTEND_URL'] != 'https://localhost:5173'
  puts "\n⚠️  FRONTEND_URL is not set to https://localhost:5173"
  puts "   Current value: #{ENV['FRONTEND_URL']}"
else
  puts "\n✅ Environment looks correct!"
  puts "   The issue must be in the database templates or sent communications"
end

puts "\n"
