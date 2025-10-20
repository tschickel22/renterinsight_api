#!/usr/bin/env ruby
# Fix the "from" email address in Platform settings
# Run with: bundle exec rails runner fix_from_email.rb

puts "=" * 80
puts "FIXING FROM EMAIL ADDRESS"
puts "=" * 80
puts

# Load current settings
config = Setting.get('Platform', 0, 'communications') || {}

puts "Current email settings:"
puts "  fromEmail: #{config.dig('email', 'fromEmail')}"
puts "  smtpUsername: #{config.dig('email', 'smtpUsername')}"
puts

# Check if they match
from_email = config.dig('email', 'fromEmail')
smtp_username = config.dig('email', 'smtpUsername')

if from_email != smtp_username
  puts "❌ MISMATCH DETECTED!"
  puts
  puts "   From: #{from_email}"
  puts "   SMTP Username: #{smtp_username}"
  puts
  puts "Gmail will silently drop emails when these don't match."
  puts
  puts "Fixing..."
  
  # Update to match
  config['email']['fromEmail'] = smtp_username
  
  # Save
  Setting.set('Platform', 0, 'communications', config)
  
  puts "✅ Fixed! fromEmail now set to: #{smtp_username}"
  puts
  puts "You can also update fromName if needed:"
  puts "  Current: #{config.dig('email', 'fromName')}"
else
  puts "✅ Email addresses already match!"
end
puts

# Verify CommunicationSettingsService picks it up
puts "Verifying CommunicationSettingsService..."
settings = CommunicationSettingsService.platform
email_config = settings.email_config

puts "  from_email: #{email_config[:from_email]}"
puts "  smtp_username: #{email_config[:smtp_username]}"

if email_config[:from_email] == email_config[:smtp_username]
  puts "  ✅ Match!"
else
  puts "  ⚠️  Still mismatched - restart Rails console!"
end
puts

puts "=" * 80
puts "ALTERNATIVE: Use Gmail Alias"
puts "=" * 80
puts
puts "If you want to send from a different address (like noreply@platformdms.com):"
puts
puts "Option 1: Add it as a Gmail alias"
puts "  1. Go to Gmail → Settings → Accounts and Import"
puts "  2. Click 'Add another email address'"
puts "  3. Add noreply@platformdms.com"
puts "  4. Verify ownership"
puts
puts "Option 2: Use a proper email service"
puts "  - Use AWS SES (supports custom from addresses)"
puts "  - Use SendGrid"
puts "  - Use Postmark"
puts
puts "Option 3: Just use renterinsight@gmail.com"
puts "  - Simplest solution"
puts "  - Already working"
puts "  - No additional setup needed"
puts
