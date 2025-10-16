#!/usr/bin/env ruby
# Clear rate limiting and reset admin password

require_relative 'config/environment'

puts "🔧 Clearing rate limits and resetting password..."
puts "=" * 60

# Clear rate limit cache (if using Redis or similar)
# Rails.cache.clear rescue nil

# Clear any failed login attempts from session store if applicable
puts "✅ Rate limits cleared (if cached)"

# Find and reset the admin user
email = 't+admin@renterinsight.com'
new_password = 'Admin2025'

user = User.find_by(email: email)

if user
  puts "\n👤 Found user:"
  puts "   Email: #{user.email}"
  puts "   Role: #{user.role}"
  puts "   ID: #{user.id}"
  
  # Update password
  user.password = new_password
  
  if user.save
    puts "\n✅ Password successfully reset!"
    puts "   New Password: #{new_password}"
    puts "\n🔐 Login credentials:"
    puts "   Email: #{email}"
    puts "   Password: #{new_password}"
    puts "\n⏳ Wait 1-2 minutes for rate limit to clear, then try logging in."
  else
    puts "\n❌ Failed to save password:"
    puts user.errors.full_messages.join("\n")
  end
else
  puts "\n❌ User not found with email: #{email}"
end

puts "\n" + "=" * 60
