#!/usr/bin/env ruby
# Test phone number formatting
# Run with: bundle exec rails runner test_phone_format.rb

puts "=" * 80
puts "PHONE NUMBER FORMATTING TEST"
puts "=" * 80
puts

# Test the TwilioProvider format_phone_number method
provider = Providers::Sms::TwilioProvider.new

test_numbers = [
  '303-570-9810',        # US with dashes
  '3035709810',          # US 10 digits
  '13035709810',         # US with country code
  '+13035709810',        # US with + and country code
  '(303) 570-9810',      # US with parens
  '1 720 575 2095',      # US with spaces and 1
  '+1 720 575 2095',     # US with + and spaces
  '303 570 9810',        # US with spaces
]

puts "Testing phone number formatting:"
puts "-" * 80

test_numbers.each do |number|
  formatted = provider.send(:format_phone_number, number)
  status = formatted&.match?(/^\+1\d{10}$/) ? '✅' : '❌'
  puts "#{status} #{number.ljust(25)} → #{formatted}"
end

puts
puts "=" * 80
puts "Expected format: +1XXXXXXXXXX (11 characters total)"
puts "=" * 80
puts

# Test via CommunicationService
puts "Testing via CommunicationService:"
puts "-" * 80

quote = Quote.first
contact = Contact.first

if quote && contact && contact.phone.present?
  puts "Contact phone: #{contact.phone}"
  
  # Don't actually send, just check what would be used
  service = CommunicationService.new
  company = contact.company
  
  settings_service = company ? 
    CommunicationSettingsService.for_company(company) : 
    CommunicationSettingsService.platform
  
  sms_config = settings_service.sms_config
  from_number = sms_config[:from_number]
  
  # Format the numbers
  provider_instance = Providers::Sms::TwilioProvider.new(company: company)
  to_formatted = provider_instance.send(:format_phone_number, contact.phone)
  from_formatted = provider_instance.send(:format_phone_number, from_number)
  
  puts "To (formatted):   #{to_formatted}"
  puts "From (formatted): #{from_formatted}"
  
  if to_formatted&.match?(/^\+1\d{10}$/) && from_formatted&.match?(/^\+1\d{10}$/)
    puts "✅ Both numbers properly formatted!"
  else
    puts "❌ Warning: Numbers may not be properly formatted"
  end
else
  puts "Skipped (no quote/contact with phone)"
end

puts
puts "=" * 80
puts "TEST COMPLETE"
puts "=" * 80
