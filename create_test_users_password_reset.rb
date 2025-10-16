#!/usr/bin/env ruby
# frozen_string_literal: true

# Create test users for password reset testing
puts "🚀 Creating Test Users for Password Reset..."
puts "=" * 60

# Create Admin User
admin = User.find_or_initialize_by(email: 't+admin@renterinsight.com')
admin.assign_attributes(
  first_name: 'Tom',
  last_name: 'Admin',
  phone: '303-570-9810',
  role: 'admin',
  password: 'password123',
  password_confirmation: 'password123',
  status: 'active'
)
admin.save!
puts "✅ Admin User Created: ID=#{admin.id}, Email=#{admin.email}, Phone=#{admin.phone}"

# Create Client User (BuyerPortalAccess)
# First, we need a buyer record (using Contact as the buyer)
buyer_contact = Contact.find_or_create_by!(
  email: 't+client@renterinsight.com'
) do |contact|
  contact.first_name = 'Tom'
  contact.last_name = 'Client'
  contact.phone = '303-570-9810'
end

# Update phone if contact already exists
buyer_contact.update!(phone: '303-570-9810') if buyer_contact.phone != '303-570-9810'

client = BuyerPortalAccess.find_or_initialize_by(email: 't+client@renterinsight.com')
client.assign_attributes(
  buyer_type: 'Contact',
  buyer_id: buyer_contact.id,
  password: 'password123',
  password_confirmation: 'password123',
  portal_enabled: true,
  email_opt_in: true,
  sms_opt_in: true
)
client.save!
puts "✅ Client User Created: ID=#{client.id}, Email=#{client.email}"

# Display summary
puts "\n📋 USER SUMMARY:"
puts "=" * 60
puts "ADMIN USER:"
puts "  Email: #{admin.email}"
puts "  Phone: #{admin.phone}"
puts "  Name: #{admin.first_name} #{admin.last_name}"
puts "  Role: #{admin.role}"
puts "  Status: #{admin.status}"
puts "\nCLIENT USER:"
puts "  Email: #{client.email}"
puts "  Name: #{buyer_contact.first_name} #{buyer_contact.last_name}"
puts "  Phone: #{buyer_contact.phone}"
puts "  Portal Enabled: #{client.portal_enabled}"
puts "  Email Opt-in: #{client.email_opt_in}"
puts "  SMS Opt-in: #{client.sms_opt_in}"
puts "=" * 60
puts "\n✅ Test users created successfully!"
puts "🧪 You can now test password reset with:"
puts "   - Email: t+admin@renterinsight.com (Admin)"
puts "   - Email: t+client@renterinsight.com (Client)"
puts "   - Phone: 303-570-9810 (Both users)"

exit
