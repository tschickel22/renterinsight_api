#!/usr/bin/env ruby
# frozen_string_literal: true

# Debug and fix test users
puts "🔍 Checking Test Users..."
puts "=" * 60

# Check Admin User
admin = User.find_by(email: 't+admin@renterinsight.com')
if admin
  puts "✅ Admin User EXISTS"
  puts "   Email: #{admin.email}"
  puts "   Phone: #{admin.phone.inspect}"
  puts "   Role: #{admin.role}"
  
  # Fix phone if missing
  if admin.phone.blank?
    admin.update!(phone: '303-570-9810')
    puts "   ✅ Phone added: 303-570-9810"
  end
else
  puts "❌ Admin User NOT FOUND"
  admin = User.create!(
    email: 't+admin@renterinsight.com',
    first_name: 'Tom',
    last_name: 'Admin',
    phone: '303-570-9810',
    role: 'admin',
    password: 'password123',
    password_confirmation: 'password123',
    status: 'active'
  )
  puts "✅ Admin User CREATED"
end

puts ""

# Check Client User
client = BuyerPortalAccess.find_by(email: 't+client@renterinsight.com')
if client
  puts "✅ Client User EXISTS"
  puts "   Email: #{client.email}"
  puts "   Buyer Type: #{client.buyer_type}"
  puts "   Buyer ID: #{client.buyer_id}"
  
  # Check associated Contact
  if client.buyer_type == 'Contact'
    contact = Contact.find_by(id: client.buyer_id)
    if contact
      puts "   Contact Email: #{contact.email}"
      puts "   Contact Phone: #{contact.phone.inspect}"
      
      # Fix phone if missing or wrong format
      if contact.phone != '+13035709810'
        contact.update!(phone: '+13035709810')
        puts "   ✅ Phone updated to: +13035709810"
      end
    else
      puts "   ❌ Associated Contact NOT FOUND"
    end
  end
else
  puts "❌ Client User NOT FOUND"
  
  # Create Contact first
  contact = Contact.find_or_create_by!(
    email: 't+client@renterinsight.com'
  ) do |c|
    c.first_name = 'Tom'
    c.last_name = 'Client'
    c.phone = '+13035709810'
  end
  
  # Ensure phone is correct
  contact.update!(phone: '+13035709810') if contact.phone != '+13035709810'
  
  # Create BuyerPortalAccess
  client = BuyerPortalAccess.create!(
    email: 't+client@renterinsight.com',
    buyer_type: 'Contact',
    buyer_id: contact.id,
    password: 'password123',
    password_confirmation: 'password123',
    portal_enabled: true,
    email_opt_in: true,
    sms_opt_in: true
  )
  puts "✅ Client User CREATED"
end

puts ""
puts "=" * 60
puts "📋 FINAL STATUS:"
puts "=" * 60

admin = User.find_by(email: 't+admin@renterinsight.com')
puts "ADMIN:"
puts "  Email: #{admin.email}"
puts "  Phone: #{admin.phone}"
puts ""

client = BuyerPortalAccess.find_by(email: 't+client@renterinsight.com')
contact = Contact.find_by(id: client.buyer_id) if client
puts "CLIENT:"
puts "  Email: #{client.email}"
puts "  Contact Phone: #{contact&.phone}"
puts ""

puts "=" * 60
puts "✅ Users fixed and ready for testing!"
puts ""
puts "🧪 Test Commands:"
puts ""
puts "# Admin Email:"
puts "curl -X POST http://localhost:3001/api/auth/request_password_reset -H 'Content-Type: application/json' -d '{\"email\":\"t+admin@renterinsight.com\",\"delivery_method\":\"email\",\"user_type\":\"admin\"}'"
puts ""
puts "# Client SMS (phone):"
puts "curl -X POST http://localhost:3001/api/auth/request_password_reset -H 'Content-Type: application/json' -d '{\"phone\":\"+13035709810\",\"delivery_method\":\"sms\",\"user_type\":\"client\"}'"

exit
