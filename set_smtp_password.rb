#!/usr/bin/env ruby
# Set Encrypted SMTP Password
# Run with: bundle exec rails runner set_smtp_password.rb
#
# This follows the same encryption pattern used in password_reset_service.rb

puts "=" * 80
puts "SMTP PASSWORD SETUP"
puts "=" * 80
puts

# Encryption helper (same as password_reset_service.rb)
def encrypt_value(plain_text)
  return nil if plain_text.blank?
  
  secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
  key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
  crypt = ActiveSupport::MessageEncryptor.new(key)
  
  encrypted = crypt.encrypt_and_sign(plain_text)
  "encrypted:#{encrypted}"
end

# Decryption helper for testing
def decrypt_value(encrypted_value)
  return encrypted_value unless encrypted_value.start_with?('encrypted:')
  
  encrypted_data = encrypted_value.sub('encrypted:', '')
  secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
  key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
  crypt = ActiveSupport::MessageEncryptor.new(key)
  
  crypt.decrypt_and_verify(encrypted_data)
rescue StandardError => e
  Rails.logger.error("Failed to decrypt: #{e.message}")
  nil
end

puts "Step 1: Finding or creating platform communications setting..."
setting = Setting.find_by(key: 'communications', scope_type: 'Platform', scope_id: 0)

unless setting
  puts "   No platform setting found, creating new one..."
  setting = Setting.new(
    key: 'communications',
    scope_type: 'Platform',
    scope_id: 0
  )
end

puts "   ✅ Setting ready (ID: #{setting.id})" if setting.persisted?
puts

puts "Step 2: Current configuration..."
if setting.persisted?
  begin
    current_config = Setting.get('Platform', 0, 'communications') || {}
    email_settings = current_config['email'] || {}
    
    puts "   Current email settings:"
    puts "     Provider: #{email_settings['provider']}"
    puts "     SMTP Host: #{email_settings['smtpHost']}"
    puts "     SMTP Port: #{email_settings['smtpPort']}"
    puts "     SMTP Username: #{email_settings['smtpUsername']}"
    puts "     From Email: #{email_settings['fromEmail']}"
    
    stored_password = email_settings['smtpPassword']
    if stored_password.nil? || stored_password.empty?
      puts "     SMTP Password: ❌ NOT SET"
    elsif stored_password.start_with?('encrypted:')
      decrypted = decrypt_value(stored_password)
      if decrypted
        puts "     SMTP Password: ✅ Encrypted (#{stored_password[0..25]}...)"
      else
        puts "     SMTP Password: ⚠️  Encrypted but decryption failed"
      end
    else
      puts "     SMTP Password: ⚠️  Plain text (length: #{stored_password.length})"
    end
  rescue => e
    puts "   ⚠️  Error reading current config: #{e.message}"
  end
else
  puts "   No existing configuration"
end
puts

puts "Step 3: Gmail App Password setup"
puts "-" * 80
puts
puts "You need a Gmail App Password (NOT your regular Gmail password)."
puts "Get one at: https://myaccount.google.com/apppasswords"
puts
puts "Make sure:"
puts "  • 2-Factor Authentication is enabled on your Google account"
puts "  • You create an App Password specifically for 'Mail'"
puts "  • You copy the 16-character password (no spaces)"
puts
print "Enter Gmail App Password (or press Enter to skip): "
password_input = STDIN.gets.chomp

if password_input.blank?
  puts
  puts "⏭️  Skipped. Configuration not saved."
  puts
  puts "To set password manually in Rails console:"
  puts
  puts "  # Encrypt password"
  puts "  secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base"
  puts "  key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)"
  puts "  crypt = ActiveSupport::MessageEncryptor.new(key)"
  puts "  encrypted = 'encrypted:' + crypt.encrypt_and_sign('YOUR_PASSWORD')"
  puts
  puts "  # Save settings"
  puts "  config = Setting.get('Platform', 0, 'communications') || {}"
  puts "  config['email'] ||= {}"
  puts "  config['email']['smtpPassword'] = encrypted"
  puts "  Setting.set('Platform', 0, 'communications', config)"
  puts
  exit 0
end

puts
puts "Step 4: Encrypting password..."
encrypted_password = encrypt_value(password_input)
puts "   ✅ Password encrypted: #{encrypted_password[0..35]}..."
puts

puts "Step 5: Testing encryption/decryption..."
decrypted_test = decrypt_value(encrypted_password)
if decrypted_test == password_input
  puts "   ✅ Encryption/decryption test PASSED"
else
  puts "   ❌ Encryption/decryption test FAILED!"
  puts "   This is a critical error - do not proceed!"
  exit 1
end
puts

puts "Step 6: Saving configuration..."
begin
  # Get existing config or create new
  config = Setting.get('Platform', 0, 'communications') || {}
  
  # Ensure email section exists
  config['email'] ||= {}
  
  # Set email configuration
  config['email']['provider'] = 'smtp'
  config['email']['smtpHost'] = 'smtp.gmail.com'
  config['email']['smtpPort'] = 587
  config['email']['smtpUsername'] = 'renterinsight@gmail.com'
  config['email']['smtpPassword'] = encrypted_password  # Encrypted!
  config['email']['smtpAuthentication'] = 'plain'
  config['email']['smtpEnableStarttls'] = true
  config['email']['fromEmail'] = 'renterinsight@gmail.com'
  config['email']['fromName'] = 'Platform DMS'
  config['email']['isEnabled'] = true
  
  # Save using Setting.set (handles JSON serialization)
  Setting.set('Platform', 0, 'communications', config)
  
  puts "   ✅ Configuration saved successfully"
rescue => e
  puts "   ❌ Error saving configuration: #{e.message}"
  puts "   #{e.backtrace.first(3).join("\n   ")}"
  exit 1
end
puts

puts "Step 7: Verifying with CommunicationSettingsService..."
begin
  service = CommunicationSettingsService.platform
  email_config = service.email_config
  
  puts "   CommunicationSettingsService returned:"
  puts "     Provider: #{email_config[:provider]}"
  puts "     SMTP Host: #{email_config[:smtp_host]}"
  puts "     SMTP Port: #{email_config[:smtp_port]}"
  puts "     SMTP Username: #{email_config[:smtp_username]}"
  
  if email_config[:smtp_password].nil?
    puts "     SMTP Password: ❌ NIL (decryption failed!)"
    puts
    puts "   ⚠️  WARNING: Password was saved but isn't being decrypted properly!"
    puts "   Check that CommunicationSettingsService.decrypt_value() uses the same encryption key."
  elsif email_config[:smtp_password] == password_input
    puts "     SMTP Password: ✅ Correctly decrypted!"
  else
    puts "     SMTP Password: ⚠️  Set but doesn't match input (length: #{email_config[:smtp_password]&.length})"
  end
rescue => e
  puts "   ❌ Error testing service: #{e.message}"
  puts "   #{e.backtrace.first(3).join("\n   ")}"
  exit 1
end
puts

puts "=" * 80
puts "✅ SUCCESS!"
puts "=" * 80
puts
puts "SMTP credentials have been configured with Company → Platform → ENV hierarchy."
puts
puts "Testing:"
puts "  1. Make sure CommunicationService.rb and SmtpProvider.rb have been updated (already done!)"
puts "  2. Restart Rails server"
puts "  3. Test sending an email:"
puts
puts "     quote = Quote.find(22)"
puts "     service = QuoteSendingService.new(quote)"
puts "     result = service.send(delivery_methods: ['email'], to_email: 'tom@renterinsight.com')"
puts "     puts result.inspect"
puts
puts "Expected result:"
puts "  {:sent=>[{:channel=>\"email\", :to=>\"tom@renterinsight.com\"}], :failed=>[], :errors=>[]}"
puts
