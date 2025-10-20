#!/usr/bin/env ruby
# Simple SMS Test - Tests SmsService directly
# Run with: bundle exec rails runner test_sms_simple.rb

require 'readline'

puts "=" * 80
puts "SIMPLE SMS TEST"
puts "=" * 80
puts

# Get test phone number
print "Enter your phone number to test (e.g., +17205752095): "
test_phone = Readline.readline.chomp

if test_phone.empty?
  puts "❌ No phone number provided"
  exit 1
end

puts
puts "Testing SMS to: #{test_phone}"
puts

# Step 1: Test platform-level SMS
puts "Step 1: Testing platform-level SMS (no company)..."
puts
begin
  result = SmsService.send_sms(
    to: test_phone,
    body: "Test SMS from RenterInsight platform settings. Time: #{Time.current}"
  )
  
  if result[:success]
    puts "   ✅ SMS SENT SUCCESSFULLY!"
    puts "   Message ID: #{result[:message_id]}"
    puts "   Response: #{result[:response]&.dig('status') || 'N/A'}"
  else
    puts "   ❌ SMS FAILED"
    puts "   Error: #{result[:error]}"
  end
rescue => e
  puts "   ❌ Exception: #{e.message}"
  puts "   #{e.backtrace.first(3).join("\n   ")}"
end
puts

# Step 2: Test company-level SMS (if company exists)
company = Company.first
if company
  puts "Step 2: Testing company-level SMS (Company: #{company.name})..."
  puts
  begin
    result = SmsService.send_sms(
      to: test_phone,
      body: "Test SMS from RenterInsight for #{company.name}. Time: #{Time.current}",
      company: company
    )
    
    if result[:success]
      puts "   ✅ SMS SENT SUCCESSFULLY!"
      puts "   Message ID: #{result[:message_id]}"
      puts "   Response: #{result[:response]&.dig('status') || 'N/A'}"
    else
      puts "   ❌ SMS FAILED"
      puts "   Error: #{result[:error]}"
    end
  rescue => e
    puts "   ❌ Exception: #{e.message}"
    puts "   #{e.backtrace.first(3).join("\n   ")}"
  end
else
  puts "Step 2: Skipped (no companies in database)"
end
puts

puts "=" * 80
puts "TEST COMPLETE"
puts "=" * 80
puts
puts "Check your phone for SMS messages!"
puts
