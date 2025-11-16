#!/usr/bin/env ruby
# Debug script for Location issues
# Run: docker-compose exec api rails runner debug_location_issues.rb

puts "\n" + "="*80
puts "LOCATION DEBUGGING SCRIPT"
puts "="*80

# Check 1: Does LocationActivity model exist?
puts "\n[1] Checking LocationActivity model..."
begin
  LocationActivity
  puts "✅ LocationActivity model loaded"
rescue NameError => e
  puts "❌ LocationActivity model NOT found: #{e.message}"
  puts "   Action: Run migration: rails db:migrate"
  exit 1
end

# Check 2: Does table exist?
puts "\n[2] Checking location_activities table..."
begin
  LocationActivity.count
  puts "✅ location_activities table exists (#{LocationActivity.count} records)"
rescue => e
  puts "❌ Table error: #{e.message}"
  puts "   Action: Run migration: rails db:migrate"
  exit 1
end

# Check 3: Test PlatformDefaults.communication_settings
puts "\n[3] Testing PlatformDefaults.communication_settings..."
begin
  comms = PlatformDefaults.communication_settings
  puts "✅ PlatformDefaults loaded"
  puts "   smtp_provider: #{comms['smtp_provider']}"
  puts "   smtp_from_email: #{comms['smtp_from_email']}"
  puts "   smtp_from_name: #{comms['smtp_from_name']}"
rescue => e
  puts "❌ Error: #{e.message}"
  puts e.backtrace.first(5)
end

# Check 4: Test PlatformSetting.communications (source data)
puts "\n[4] Testing PlatformSetting.communications (source)..."
begin
  db_comms = PlatformSetting.communications
  puts "✅ PlatformSetting.communications loaded"
  puts "   Raw data: #{db_comms.inspect}"
  if db_comms['email']
    puts "   Email provider: #{db_comms['email']['provider']}"
    puts "   Email from: #{db_comms['email']['fromEmail']}"
  elsif db_comms[:email]
    puts "   Email provider: #{db_comms[:email][:provider]}"
    puts "   Email from: #{db_comms[:email][:fromEmail]}"
  end
rescue => e
  puts "❌ Error: #{e.message}"
end

# Check 5: Test Location.resolved_communication_settings
puts "\n[5] Testing Location resolution..."
location = Location.first
if location
  puts "✅ Found location: #{location.name}"
  
  # Test callback is registered
  puts "\n   Checking callbacks..."
  callbacks = Location._update_callbacks.select { |cb| cb.filter == :track_settings_changes }
  if callbacks.any?
    puts "   ✅ track_settings_changes callback is registered"
  else
    puts "   ❌ track_settings_changes callback NOT registered"
    puts "   Action: Restart Rails server to reload code"
  end
  
  # Test resolved settings
  puts "\n   Resolved communication settings:"
  resolved = location.resolved_communication_settings
  puts "   smtp_provider: #{resolved['smtp_provider']}"
  puts "   smtp_from_email: #{resolved['smtp_from_email']}"
  puts "   smtp_from_name: #{resolved['smtp_from_name']}"
  
  # Test making a change
  puts "\n[6] Testing activity tracking by making a change..."
  old_count = LocationActivity.where(location_id: location.id).count
  puts "   Current activities for location: #{old_count}"
  
  # Make a simple change
  location.branding_settings = (location.branding_settings || {}).merge({'primary_color' => '#FF0000'})
  location.updated_by = User.first&.id&.to_s
  location.save!
  
  new_count = LocationActivity.where(location_id: location.id).count
  puts "   Activities after save: #{new_count}"
  
  if new_count > old_count
    puts "   ✅ Activity was created!"
    activity = LocationActivity.where(location_id: location.id).last
    puts "   Latest activity: #{activity.action} - #{activity.description}"
  else
    puts "   ❌ NO activity was created"
    puts "   Action: Check if callback is firing. Try restarting Rails."
  end
else
  puts "❌ No locations found. Create a location first."
end

puts "\n" + "="*80
puts "DEBUG COMPLETE"
puts "="*80 + "\n"
