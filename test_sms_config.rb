#!/usr/bin/env ruby
# Test SMS Configuration and Sending
# Run with: bundle exec rails runner test_sms_config.rb

puts "=" * 80
puts "TESTING SMS CONFIGURATION"
puts "=" * 80
puts

# Step 1: Check CommunicationSettingsService SMS config
puts "Step 1: Loading SMS configuration..."
begin
  settings = CommunicationSettingsService.platform
  sms_config = settings.sms_config
  
  puts "   Provider: #{sms_config[:provider]}"
  puts "   From Number: #{sms_config[:from_number]}"
  puts "   Twilio Account SID: #{sms_config[:twilio_account_sid] ? '✅ SET' : '❌ NIL'}"
  puts "   Twilio Auth Token: #{sms_config[:twilio_auth_token] ? '✅ SET' : '❌ NIL'}"
  puts "   Enabled: #{sms_config[:enabled]}"
  
  if sms_config[:twilio_account_sid].nil? || sms_config[:twilio_auth_token].nil?
    puts
    puts "   ❌ Missing Twilio credentials!"
    exit 1
  end
  
  puts "   ✅ SMS configuration loaded successfully"
rescue => e
  puts "   ❌ Error: #{e.message}"
  puts "   #{e.backtrace.first(3).join("\n   ")}"
  exit 1
end
puts

# Step 2: Test TwilioProvider initialization
puts "Step 2: Testing TwilioProvider..."
begin
  # Test platform-level provider (no company)
  provider = Providers::Sms::TwilioProvider.new
  puts "   ✅ Platform-level TwilioProvider initialized successfully"
  puts "   Configured: #{provider.configured?}"
  
  # Test company-level provider if we have a company
  company = Company.first
  if company
    provider_company = Providers::Sms::TwilioProvider.new(company: company)
    puts "   ✅ Company-level TwilioProvider initialized successfully"
    puts "   Configured: #{provider_company.configured?}"
  end
rescue => e
  puts "   ❌ Error initializing provider: #{e.message}"
  puts "   #{e.backtrace.first(3).join("\n   ")}"
  exit 1
end
puts

# Step 3: Find a quote to test with
puts "Step 3: Finding test quote..."
quote = Quote.find(22)
puts "   Quote: #{quote.quote_number}"
puts "   Status: #{quote.status}"

# Get phone number
test_phone = quote.contact&.phone || quote.account&.phone
if test_phone.nil?
  puts "   ⚠️  No phone number found for this quote"
  print "   Enter test phone number (e.g., +17205752095): "
  test_phone = STDIN.gets.chomp
end
puts "   Test phone: #{test_phone}"
puts

# Step 4: Test SMS sending
puts "Step 4: Attempting to send test SMS..."
begin
  service = QuoteSendingService.new(quote)
  result = service.send(
    delivery_methods: ['sms'],
    to_phone: test_phone
  )
  
  puts "   Result:"
  puts "     Sent: #{result[:sent].length} SMS"
  puts "     Failed: #{result[:failed].length}"
  puts "     Errors: #{result[:errors].inspect}"
  
  if result[:sent].any?
    comm = result[:sent].first[:communication]
    puts
    puts "   ✅ SMS SENT SUCCESSFULLY!"
    puts
    puts "   Communication record:"
    puts "      ID: #{comm.id}"
    puts "      Status: #{comm.status}"
    puts "      Channel: #{comm.channel}"
    puts "      To: #{comm.to_address}"
    puts "      Provider: #{comm.provider}"
    puts "      External ID: #{comm.external_id}"
    puts "      Sent at: #{comm.sent_at}"
  else
    puts
    puts "   ❌ SMS FAILED"
    puts "   Errors: #{result[:errors]}"
    puts "   Failed: #{result[:failed].inspect}"
  end
rescue => e
  puts "   ❌ Error: #{e.message}"
  puts "   #{e.backtrace.first(5).join("\n   ")}"
end
puts

puts "=" * 80
puts "SUMMARY"
puts "=" * 80
puts

if result && result[:sent].any?
  puts "✅ SMS is working correctly!"
  puts
  puts "Check your phone for the text message."
  puts
  puts "The SMS should contain:"
  puts "  - Quote number"
  puts "  - Total amount"
  puts "  - Link to view quote (if portal enabled)"
else
  puts "❌ SMS is not working"
  puts
  puts "Common issues:"
  puts "  1. Twilio credentials not set or incorrect"
  puts "  2. From number not verified in Twilio"
  puts "  3. Account doesn't have SMS enabled"
  puts "  4. Phone number format invalid"
  puts
  puts "Check Rails logs for more details."
end
puts
