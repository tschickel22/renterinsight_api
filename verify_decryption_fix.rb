#!/usr/bin/env ruby
# Verify the decryption fix works
# Run with: bundle exec rails runner verify_decryption_fix.rb

puts "=" * 80
puts "VERIFYING DECRYPTION FIX"
puts "=" * 80
puts

# Test 1: CommunicationSettingsService
puts "Test 1: CommunicationSettingsService.platform.email_config..."
begin
  settings = CommunicationSettingsService.platform
  config = settings.email_config
  
  puts "   Provider: #{config[:provider]}"
  puts "   SMTP Host: #{config[:smtp_host]}"
  puts "   SMTP Port: #{config[:smtp_port]}"
  puts "   SMTP Username: #{config[:smtp_username]}"
  
  if config[:smtp_password].nil?
    puts "   SMTP Password: ❌ NIL (decryption still failing!)"
    puts
    puts "   Check that you restarted Rails console!"
  else
    puts "   SMTP Password: ✅ Decrypted successfully! (length: #{config[:smtp_password].length})"
  end
  
  puts
  puts "   Result: #{config[:smtp_password] ? '✅ SUCCESS' : '❌ FAILED'}"
rescue => e
  puts "   ❌ Error: #{e.message}"
  puts "   #{e.backtrace.first(3).join("\n   ")}"
end
puts

# Test 2: SMS config (should also decrypt)
puts "Test 2: CommunicationSettingsService.platform.sms_config..."
begin
  settings = CommunicationSettingsService.platform
  config = settings.sms_config
  
  puts "   Provider: #{config[:provider]}"
  puts "   From Number: #{config[:from_number]}"
  puts "   Twilio Account SID: #{config[:twilio_account_sid] ? '✅ SET' : '❌ NIL'}"
  puts "   Twilio Auth Token: #{config[:twilio_auth_token] ? '✅ SET' : '❌ NIL'}"
  puts
  puts "   Result: #{config[:twilio_auth_token] ? '✅ SUCCESS' : '❌ FAILED'}"
rescue => e
  puts "   ❌ Error: #{e.message}"
end
puts

# Test 3: Try sending an email
puts "Test 3: Attempting to send test email..."
begin
  quote = Quote.find(22)
  service = QuoteSendingService.new(quote)
  result = service.send(
    delivery_methods: ['email'], 
    to_email: 'tom@renterinsight.com'
  )
  
  puts "   Sent: #{result[:sent].inspect}"
  puts "   Failed: #{result[:failed].inspect}"
  puts "   Errors: #{result[:errors].inspect}"
  puts
  
  if result[:sent].any?
    puts "   Result: ✅ EMAIL SENT SUCCESSFULLY!"
    comm = Communication.last
    puts
    puts "   Communication record:"
    puts "      ID: #{comm.id}"
    puts "      Status: #{comm.status}"
    puts "      Channel: #{comm.channel}"
    puts "      To: #{comm.to_address}"
    puts "      Sent at: #{comm.sent_at}"
  else
    puts "   Result: ❌ EMAIL FAILED"
    puts "   Error: #{result[:errors].first}"
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
puts "If all tests passed ✅, the fix is working correctly!"
puts
puts "If tests failed ❌:"
puts "  1. Make sure you restarted Rails console (reload! doesn't reload service files)"
puts "  2. Check Rails logs for decryption errors"
puts "  3. Run: bundle exec rails runner check_existing_password.rb"
puts
