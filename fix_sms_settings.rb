#!/usr/bin/env ruby
# Fix SMS settings - ensure phone number is properly formatted
# Run with: bundle exec rails runner fix_sms_settings.rb

puts "=" * 80
puts "SMS SETTINGS FIX"
puts "=" * 80
puts

# Check current platform settings
puts "Current Platform Settings:"
puts "-" * 80

settings_service = CommunicationSettingsService.platform
sms_config = settings_service.sms_config

puts "from_number: #{sms_config[:from_number].inspect}"
puts "twilio_account_sid: #{sms_config[:twilio_account_sid].present? ? '[SET]' : '[NOT SET]'}"
puts "twilio_auth_token: #{sms_config[:twilio_auth_token].present? ? '[SET]' : '[NOT SET]'}"
puts

# Check if from_number needs fixing
from_number = sms_config[:from_number]

if from_number.present?
  # Remove all non-numeric characters except +
  cleaned = from_number.gsub(/[^0-9+]/, '')
  
  # Add + if not present
  formatted = cleaned.start_with?('+') ? cleaned : "+#{cleaned}"
  
  if from_number != formatted
    puts "⚠️  Phone number needs formatting!"
    puts "   Current:  #{from_number.inspect}"
    puts "   Should be: #{formatted.inspect}"
    puts
    puts "Fixing now..."
    
    # Update the setting
    setting = Setting.find_by(key: 'communications', scope_type: ['Platform', nil])
    
    if setting
      value = JSON.parse(setting.value)
      value['sms'] ||= {}
      value['sms']['fromNumber'] = formatted
      setting.update!(value: value.to_json)
      
      puts "✅ Fixed! Platform SMS from_number updated to: #{formatted}"
    else
      puts "❌ Could not find platform settings record"
      puts "   Creating new one..."
      
      Setting.create!(
        key: 'communications',
        scope_type: 'Platform',
        value: {
          sms: {
            fromNumber: formatted,
            twilioAccountSid: sms_config[:twilio_account_sid],
            twilioAuthToken: sms_config[:twilio_auth_token],
            provider: 'twilio'
          }
        }.to_json
      )
      
      puts "✅ Created platform settings with formatted number: #{formatted}"
    end
  else
    puts "✅ Phone number is already properly formatted: #{formatted}"
  end
else
  puts "❌ No from_number set in platform settings!"
  puts
  print "Enter your Twilio phone number (e.g., +17205752095): "
  phone = gets.chomp
  
  if phone.present?
    # Format it
    cleaned = phone.gsub(/[^0-9+]/, '')
    formatted = cleaned.start_with?('+') ? cleaned : "+#{cleaned}"
    
    # Update or create setting
    setting = Setting.find_by(key: 'communications', scope_type: ['Platform', nil])
    
    if setting
      value = JSON.parse(setting.value)
      value['sms'] ||= {}
      value['sms']['fromNumber'] = formatted
      setting.update!(value: value.to_json)
      
      puts "✅ Set platform SMS from_number to: #{formatted}"
    else
      Setting.create!(
        key: 'communications',
        scope_type: 'Platform',
        value: {
          sms: {
            fromNumber: formatted,
            provider: 'twilio'
          }
        }.to_json
      )
      
      puts "✅ Created platform settings with number: #{formatted}"
    end
  else
    puts "❌ No phone number provided, skipping"
  end
end

puts
puts "=" * 80
puts "Verifying settings after fix..."
puts "=" * 80
puts

# Re-check settings
settings_service = CommunicationSettingsService.platform
sms_config = settings_service.sms_config

puts "from_number: #{sms_config[:from_number].inspect}"
puts "twilio_account_sid: #{sms_config[:twilio_account_sid].present? ? '[SET]' : '[NOT SET]'}"
puts "twilio_auth_token: #{sms_config[:twilio_auth_token].present? ? '[SET]' : '[NOT SET]'}"
puts

if sms_config[:from_number].present? && sms_config[:twilio_account_sid].present? && sms_config[:twilio_auth_token].present?
  puts "✅ All SMS settings are configured!"
  puts
  puts "Ready to send SMS! Try:"
  puts "  bundle exec rails runner test_sms_simple.rb"
else
  puts "⚠️  Some settings are missing:"
  puts "  - from_number: #{sms_config[:from_number].present? ? '✅' : '❌'}"
  puts "  - twilio_account_sid: #{sms_config[:twilio_account_sid].present? ? '✅' : '❌'}"
  puts "  - twilio_auth_token: #{sms_config[:twilio_auth_token].present? ? '✅' : '❌'}"
end

puts
puts "=" * 80
puts "DONE"
puts "=" * 80
