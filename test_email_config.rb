#!/usr/bin/env ruby
# frozen_string_literal: true

puts "📧 Configuring Email Delivery for Development"
puts "=" * 60
puts ""

# Check current ActionMailer configuration
puts "Current Configuration:"
puts "  Delivery Method: #{ActionMailer::Base.delivery_method}"
puts "  Raise Errors: #{Rails.application.config.action_mailer.raise_delivery_errors}"
puts "  Perform Deliveries: #{ActionMailer::Base.perform_deliveries}"
puts ""

# Configure to use letter_opener for development (opens emails in browser)
# OR configure SMTP if you want real delivery
puts "Available options:"
puts ""
puts "OPTION 1: View emails in logs (current - emails logged but not sent)"
puts "OPTION 2: Use letter_opener gem (opens emails in browser)"
puts "OPTION 3: Configure real SMTP (Gmail, etc)"
puts ""

# For now, let's just enable logging and see what's being sent
ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = true
Rails.application.config.action_mailer.raise_delivery_errors = true

puts "✅ Configured to TEST mode (emails captured, not sent)"
puts ""
puts "To see captured emails:"
puts "  ActionMailer::Base.deliveries.last"
puts ""

# Test sending an email
puts "🧪 Testing Email Delivery..."
puts ""

begin
  admin = User.find_by(email: 't+admin@renterinsight.com')
  if admin
    # Clear previous deliveries
    ActionMailer::Base.deliveries.clear
    
    # Try to send a test email
    PasswordResetMailer.reset_instructions(
      email: admin.email,
      token: 'TEST123',
      reset_url: 'http://localhost:5173/reset-password?token=TEST123',
      user_name: admin.first_name,
      email_settings: {
        'fromEmail' => 'noreply@renterinsight.com',
        'fromName' => 'RenterInsight'
      }
    ).deliver_now
    
    puts "✅ Test email sent successfully!"
    puts ""
    puts "Captured email:"
    mail = ActionMailer::Base.deliveries.last
    if mail
      puts "  From: #{mail.from}"
      puts "  To: #{mail.to}"
      puts "  Subject: #{mail.subject}"
      puts ""
      puts "Email count: #{ActionMailer::Base.deliveries.count}"
    end
  else
    puts "❌ Admin user not found. Run fix_test_users.rb first."
  end
rescue => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(5)
end

puts ""
puts "=" * 60
puts "📧 Email Configuration Complete!"
puts ""
puts "CURRENT MODE: TEST (emails captured in memory)"
puts ""
puts "To check delivered emails in console:"
puts "  ActionMailer::Base.deliveries.count"
puts "  ActionMailer::Base.deliveries.last"
puts ""
puts "To enable REAL email delivery, add to .env:"
puts "  SMTP_ADDRESS=smtp.gmail.com"
puts "  SMTP_PORT=587"
puts "  SMTP_USERNAME=your_email@gmail.com"
puts "  SMTP_PASSWORD=your_app_password"
puts ""

exit
