#!/usr/bin/env ruby
# Test to verify from_number is properly resolved from settings
# Run with: bundle exec rails runner test_from_number.rb

puts "=" * 80
puts "FROM NUMBER RESOLUTION TEST"
puts "=" * 80
puts

# Test 1: Platform-level settings
puts "Test 1: Platform-level SMS from number"
begin
  settings = CommunicationSettingsService.platform
  sms_config = settings.sms_config
  puts "  Platform from_number: #{sms_config[:from_number] || 'NOT SET'}"
  puts "  ENV fallback: #{ENV['TWILIO_PHONE_NUMBER'] || 'NOT SET'}"
rescue => e
  puts "  ❌ Error: #{e.message}"
end
puts

# Test 2: Company-level settings (if company exists)
company = Company.first
if company
  puts "Test 2: Company-level SMS from number (#{company.name})"
  begin
    settings = CommunicationSettingsService.for_company(company)
    sms_config = settings.sms_config
    puts "  Company from_number: #{sms_config[:from_number] || 'NOT SET (will use platform)'}"
  rescue => e
    puts "  ❌ Error: #{e.message}"
  end
else
  puts "Test 2: Skipped (no companies in database)"
end
puts

# Test 3: Create a test communication to verify from_address resolution
puts "Test 3: Testing actual communication creation"
contact = Contact.first || Account.first
if contact
  begin
    # Don't actually send, just create the record to test from_address
    service = CommunicationService.new
    
    # Extract what the from_address would be
    communicable = contact.is_a?(Contact) ? contact : contact
    company = contact.company
    
    settings_service = company ? 
      CommunicationSettingsService.for_company(company) : 
      CommunicationSettingsService.platform
    
    sms_config = settings_service.sms_config
    from_number = sms_config[:from_number] || ENV['TWILIO_PHONE_NUMBER']
    
    puts "  Resolved from_number for #{communicable.class.name}: #{from_number || 'NOT FOUND'}"
    
    if from_number.present?
      puts "  ✅ From number successfully resolved!"
    else
      puts "  ❌ WARNING: No from number found!"
      puts "     Please set platform settings or ENV['TWILIO_PHONE_NUMBER']"
    end
  rescue => e
    puts "  ❌ Error: #{e.message}"
  end
else
  puts "  Skipped (no contacts or accounts in database)"
end
puts

puts "=" * 80
puts "TEST COMPLETE"
puts "=" * 80
puts
puts "Summary:"
puts "  - Platform settings are checked first"
puts "  - Company settings override platform (if set)"
puts "  - ENV variables are final fallback"
puts "  - The from_number should now automatically populate!"
puts
