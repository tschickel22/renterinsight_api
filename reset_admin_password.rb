#!/usr/bin/env ruby
# Reset admin password script

require_relative 'config/environment'

email = 't+admin@renterinsight.com'
new_password = 'Admin2025'

user = User.find_by(email: email)

if user
  puts "Found user: #{user.email}"
  puts "Current role: #{user.role}"
  
  user.password = new_password
  
  if user.save
    puts "✅ Password successfully reset!"
    puts "   Email: #{email}"
    puts "   New Password: #{new_password}"
    puts ""
    puts "You can now login with these credentials."
  else
    puts "❌ Failed to save password:"
    puts user.errors.full_messages.join(", ")
  end
else
  puts "❌ User not found with email: #{email}"
end
