#!/usr/bin/env ruby
# Check what's actually in the database and why password is nil
# Run with: bundle exec rails runner check_existing_password.rb

puts "=" * 80
puts "CHECKING EXISTING PASSWORD IN DATABASE"
puts "=" * 80
puts

# Step 1: Check what's in the database
puts "Step 1: Raw database value..."
setting = Setting.find_by(key: 'communications', scope_type: 'Platform', scope_id: 0)

if setting.nil?
  puts "❌ No Platform setting found with scope_id: 0"
  puts
  puts "Trying with scope_type: 'Platform' OR nil, scope_id: nil..."
  setting = Setting.where(key: 'communications')
    .where("scope_type = ? OR scope_type IS ?", 'Platform', nil)
    .where("scope_id = ? OR scope_id IS ?", 0, nil)
    .first
end

if setting.nil?
  puts "❌ No Platform communications setting found at all!"
  puts
  puts "Available settings:"
  Setting.where(key: 'communications').each do |s|
    puts "  - scope_type: #{s.scope_type.inspect}, scope_id: #{s.scope_id.inspect}"
  end
  exit 1
end

puts "✅ Found setting:"
puts "   ID: #{setting.id}"
puts "   scope_type: #{setting.scope_type.inspect}"
puts "   scope_id: #{setting.scope_id.inspect}"
puts

# Step 2: Check raw value
puts "Step 2: Raw stored value..."
raw_value = setting.read_attribute(:value)
puts "   Type: #{raw_value.class}"
puts "   Value (first 200 chars): #{raw_value.to_s[0..200]}"
puts

# Step 3: Parse as JSON
puts "Step 3: Parsed JSON value..."
begin
  parsed = JSON.parse(setting.value)
  email_config = parsed['email'] || parsed[:email]
  
  if email_config.nil?
    puts "❌ No 'email' key in config!"
    puts "   Available keys: #{parsed.keys.inspect}"
  else
    puts "✅ Email config found:"
    email_config.each do |key, value|
      if key.to_s.downcase.include?('password')
        if value.nil?
          puts "   #{key}: nil ❌"
        elsif value.to_s.start_with?('encrypted:')
          puts "   #{key}: encrypted:... (length: #{value.length}) 🔒"
          puts "      First 50 chars: #{value[0..50]}"
        else
          puts "   #{key}: *** (length: #{value.length})"
        end
      else
        puts "   #{key}: #{value}"
      end
    end
  end
  
  stored_password = email_config['smtpPassword'] || email_config[:smtpPassword]
  puts
  
  # Step 4: Try to decrypt with CommunicationSettingsService method
  puts "Step 4: Testing CommunicationSettingsService decryption..."
  if stored_password && stored_password.start_with?('encrypted:')
    puts "   Password is encrypted, testing decryption..."
    
    # Method 1: CommunicationSettingsService's decrypt_value
    puts
    puts "   Method 1: CommunicationSettingsService.decrypt_value() method:"
    begin
      encrypted_data = stored_password.sub('encrypted:', '')
      encryptor = ActiveSupport::MessageEncryptor.new(
        Rails.application.secret_key_base[0..31],
        cipher: 'aes-256-gcm'
      )
      decrypted1 = encryptor.decrypt_and_verify(encrypted_data)
      puts "      ✅ SUCCESS: Decrypted (length: #{decrypted1.length})"
    rescue => e
      puts "      ❌ FAILED: #{e.message}"
      decrypted1 = nil
    end
    
    # Method 2: password_reset_service.rb method
    puts
    puts "   Method 2: password_reset_service.rb method:"
    begin
      encrypted_data = stored_password.sub('encrypted:', '')
      secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
      key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
      crypt = ActiveSupport::MessageEncryptor.new(key)
      decrypted2 = crypt.decrypt_and_verify(encrypted_data)
      puts "      ✅ SUCCESS: Decrypted (length: #{decrypted2.length})"
    rescue => e
      puts "      ❌ FAILED: #{e.message}"
      decrypted2 = nil
    end
    
    puts
    puts "   Comparison:"
    puts "      Method 1 result: #{decrypted1 ? 'SUCCESS ✅' : 'FAILED ❌'}"
    puts "      Method 2 result: #{decrypted2 ? 'SUCCESS ✅' : 'FAILED ❌'}"
    
    if decrypted1 && decrypted2
      puts "      Match: #{decrypted1 == decrypted2 ? 'YES ✅' : 'NO ❌'}"
    end
  elsif stored_password
    puts "   Password is NOT encrypted (plain text)"
    puts "   Value: #{stored_password[0..10]}..."
  else
    puts "   ❌ Password is nil or empty!"
  end
rescue => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
end
puts

# Step 5: Test CommunicationSettingsService
puts "Step 5: Testing CommunicationSettingsService.platform..."
begin
  service = CommunicationSettingsService.platform
  config = service.email_config
  
  puts "   Result:"
  puts "      smtp_host: #{config[:smtp_host]}"
  puts "      smtp_port: #{config[:smtp_port]}"
  puts "      smtp_username: #{config[:smtp_username]}"
  puts "      smtp_password: #{config[:smtp_password].nil? ? 'nil ❌' : "SET (length: #{config[:smtp_password].length}) ✅"}"
rescue => e
  puts "   ❌ Error: #{e.message}"
  puts "   #{e.backtrace.first(3).join("\n   ")}"
end
puts

puts "=" * 80
puts "DIAGNOSIS"
puts "=" * 80

if stored_password && stored_password.start_with?('encrypted:')
  puts
  puts "The password IS stored in the database as encrypted."
  puts
  if decrypted1.nil? && decrypted2.nil?
    puts "❌ PROBLEM: Neither decryption method works!"
    puts
    puts "Possible causes:"
    puts "  1. Wrong encryption key"
    puts "  2. Password encrypted with different method"
    puts "  3. Corrupted encrypted data"
    puts
    puts "Solution: Re-encrypt the password with correct method"
  elsif decrypted1 && decrypted2.nil?
    puts "✅ CommunicationSettingsService method works!"
    puts "   The password should be decrypting correctly."
    puts
    puts "If CommunicationSettingsService.email_config[:smtp_password] is still nil,"
    puts "the issue is elsewhere (maybe in how the service loads settings)."
  elsif decrypted1.nil? && decrypted2
    puts "❌ MISMATCH: Password encrypted with password_reset method!"
    puts
    puts "CommunicationSettingsService uses different encryption than password_reset_service."
    puts
    puts "Solution: Update CommunicationSettingsService.decrypt_value() to match"
    puts "password_reset_service.rb encryption method."
  end
elsif stored_password
  puts
  puts "⚠️  Password is stored as PLAIN TEXT (not encrypted)"
  puts
  puts "This is a security issue. The password should be encrypted."
else
  puts
  puts "❌ Password is nil or missing from the database"
  puts
  puts "You need to add a password."
end
puts
