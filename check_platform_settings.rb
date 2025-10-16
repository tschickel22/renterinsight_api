#!/usr/bin/env ruby
# frozen_string_literal: true

puts "🔍 Checking Current Platform Settings"
puts "=" * 60
puts ""

begin
  settings = Setting.get('Platform', 0, 'communications')
  
  if settings.present?
    puts "✅ Platform Settings Found!"
    puts ""
    
    if settings['email'].present?
      puts "📧 EMAIL SETTINGS:"
      email = settings['email']
      puts "  Provider: #{email['provider']}"
      puts "  From Email: #{email['fromEmail']}"
      puts "  From Name: #{email['fromName']}"
      puts "  SMTP Host: #{email['smtpHost']}"
      puts "  SMTP Port: #{email['smtpPort']}"
      puts "  SMTP Username: #{email['smtpUsername']}"
      puts "  SMTP Password: #{email['smtpPassword'] ? '[SET]' : '[NOT SET]'}"
      puts "  Enabled: #{email['isEnabled']}"
      puts ""
    else
      puts "❌ No email settings found"
      puts ""
    end
    
    if settings['sms'].present?
      puts "📱 SMS SETTINGS:"
      sms = settings['sms']
      puts "  Provider: #{sms['provider']}"
      puts "  From Number: #{sms['fromNumber']}"
      puts "  Twilio Account SID: #{sms['twilioAccountSid'] ? '[SET]' : '[NOT SET]'}"
      puts "  Twilio Auth Token: #{sms['twilioAuthToken'] ? '[SET]' : '[NOT SET]'}"
      puts "  Enabled: #{sms['isEnabled']}"
      puts ""
    else
      puts "❌ No SMS settings found"
      puts ""
    end
  else
    puts "❌ No Platform Settings Found"
    puts ""
    puts "To add settings, run in Rails console:"
    puts ""
    puts "Setting.set('Platform', 0, 'communications', {"
    puts "  email: { ... },"
    puts "  sms: { ... }"
    puts "})"
  end
rescue => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(3)
end

puts "=" * 60

exit
