#!/usr/bin/env ruby
# frozen_string_literal: true

puts "🔧 Fixing Platform Settings"
puts "=" * 70
puts ""

# Get current settings
current = Setting.get('Platform', 0, 'communications')

if current
  puts "Current Settings:"
  puts "  Email Enabled: #{current.dig('email', 'isEnabled')}"
  puts "  SMS Enabled: #{current.dig('sms', 'isEnabled')}"
  puts ""
  
  # Enable email if not enabled
  if current.dig('email', 'isEnabled') != true
    puts "⚠️  Email is not enabled. Let's enable it..."
    puts ""
    puts "Please configure email in Rails console:"
    puts ""
    puts "Setting.set('Platform', 0, 'communications', {"
    puts "  email: {"
    puts "    isEnabled: true,"
    puts "    provider: 'smtp',"
    puts "    smtpHost: 'smtp.gmail.com',"
    puts "    smtpPort: 587,"
    puts "    smtpUsername: 'your_email@gmail.com',"
    puts "    smtpPassword: 'your_app_password',"
    puts "    smtpAuthentication: 'plain',"
    puts "    smtpEnableStarttls: true,"
    puts "    fromEmail: 'noreply@renterinsight.com',"
    puts "    fromName: 'RenterInsight'"
    puts "  },"
    puts "  sms: current.dig('sms') || {}"
    puts "})"
    puts ""
  else
    puts "✅ Email is already enabled!"
  end
  
  # Check SMS
  if current.dig('sms', 'isEnabled') == true
    puts "✅ SMS is enabled"
    puts ""
    puts "SMS Settings:"
    sms = current['sms']
    puts "  Provider: #{sms['provider']}"
    puts "  From Number: #{sms['fromNumber']}"
    puts "  Twilio SID: #{sms['twilioAccountSid']&.slice(0, 10)}..."
    puts "  Twilio Token: #{sms['twilioAuthToken'] ? '[SET]' : '[NOT SET]'}"
    puts ""
    
    # Test Twilio connection
    puts "Testing Twilio credentials..."
    require 'net/http'
    require 'json'
    
    begin
      uri = URI("https://api.twilio.com/2010-04-01/Accounts/#{sms['twilioAccountSid']}.json")
      request = Net::HTTP::Get.new(uri)
      request.basic_auth(sms['twilioAccountSid'], sms['twilioAuthToken'])
      
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end
      
      if response.code == '200'
        puts "✅ Twilio credentials are valid!"
        account = JSON.parse(response.body)
        puts "   Account: #{account['friendly_name']}"
        puts "   Status: #{account['status']}"
      else
        puts "❌ Twilio credentials invalid (#{response.code})"
        puts "   Response: #{response.body}"
      end
    rescue => e
      puts "❌ Error testing Twilio: #{e.message}"
    end
  end
  
else
  puts "❌ No Platform Settings found!"
end

puts ""
puts "=" * 70
puts ""

# Check what happened with the recent SMS attempt
puts "🔍 Checking Recent Password Reset Attempts"
puts "-" * 70
puts ""

recent_tokens = PasswordResetToken.order(created_at: :desc).limit(5)
recent_tokens.each do |token|
  puts "Token ##{token.id}:"
  puts "  User: #{token.user_type} ##{token.user_id}"
  puts "  Identifier: #{token.identifier}"
  puts "  Method: #{token.delivery_method}"
  puts "  Created: #{token.created_at}"
  puts "  Used: #{token.used}"
  puts ""
end

puts "=" * 70
puts ""

# Check the SmsService
puts "📱 Checking SmsService Configuration"
puts "-" * 70
puts ""

sms_settings = current&.dig('sms')
if sms_settings
  puts "Creating SmsService with Platform settings..."
  
  # Decrypt if needed
  if sms_settings['twilioAuthToken']&.start_with?('encrypted:')
    puts "⚠️  Auth token is encrypted, will be decrypted by service"
  end
  
  begin
    service = SmsService.new(sms_settings)
    puts "✅ SmsService created successfully"
    puts ""
    
    # Try to send a test SMS
    puts "🧪 Testing SMS send to +13035709810..."
    result = service.send_message(
      to: '+13035709810',
      body: 'Test message from RenterInsight'
    )
    puts "✅ SMS sent successfully!"
    puts "   Result: #{result.inspect}"
  rescue => e
    puts "❌ SMS send failed: #{e.message}"
    puts "   #{e.class}"
    if e.respond_to?(:response)
      puts "   Response: #{e.response.body}" rescue nil
    end
  end
end

puts ""
puts "=" * 70
puts "💡 Summary"
puts ""
puts "If SMS is still failing, check:"
puts "  1. Twilio account is active and funded"
puts "  2. From number #{sms_settings&.dig('fromNumber')} is valid"
puts "  3. To number +13035709810 is in correct format"
puts "  4. Twilio credentials are correct"
puts ""
puts "To test manually:"
puts "  bundle exec rails console"
puts "  SmsService.new(Setting.get('Platform', 0, 'communications')['sms']).send_message(to: '+13035709810', body: 'Test')"

exit
