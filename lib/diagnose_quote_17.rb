#!/usr/bin/env ruby
# Comprehensive diagnosis for Quote #17

puts "\n" + ("=" * 80)
puts "COMPREHENSIVE DIAGNOSIS FOR QUOTE #17"
puts ("=" * 80)

quote = Quote.find_by(id: 17)

unless quote
  puts "\n❌ Quote #17 not found!"
  exit 1
end

puts "\n📋 QUOTE #17:"
puts "  Quote Number: #{quote.quote_number}"
puts "  Status: #{quote.status}"
puts "  To Email: tom@renterinsight.com"
puts "  To Phone: 3035709810"

# Check contact
if quote.contact
  contact = quote.contact
  puts "\n👤 CONTACT ##{contact.id}:"
  puts "  Name: #{contact.full_name}"
  puts "  Email: #{contact.email}"
  puts "  Phone: #{contact.phone}"
  
  # OLD SYSTEM - Check Contact's own opt-out fields
  puts "\n  📧 OLD SYSTEM (Contact.opt_out_email):"
  puts "     opt_out_email: #{contact.opt_out_email || false}"
  puts "     opt_out_sms: #{contact.opt_out_sms || false}"
  
  if contact.opt_out_email
    puts "     ⚠️ FOUND IT! Contact has opt_out_email=true"
    puts "     This is why emails are failing!"
  end
  
  if contact.opt_out_sms
    puts "     ⚠️ FOUND IT! Contact has opt_out_sms=true"
    puts "     This is why SMS are failing!"
  end
end

if quote.account
  account = quote.account
  puts "\n🏢 ACCOUNT ##{account.id}:"
  puts "  Name: #{account.name}"
  puts "  Email: #{account.email}"
end

# NEW SYSTEM - Check CommunicationPreference records
puts "\n🔍 NEW SYSTEM (CommunicationPreference table):"

# Check for Quote-level preferences
quote_prefs = CommunicationPreference.where(recipient_type: 'Quote', recipient_id: 17)
if quote_prefs.any?
  puts "  ⚠️ Quote-level preferences (WRONG):"
  quote_prefs.each do |pref|
    puts "     • #{pref.channel} / #{pref.category}: opted_in=#{pref.opted_in}"
  end
else
  puts "  ✅ No Quote-level preferences"
end

# Check for Contact-level preferences
if quote.contact
  contact_prefs = CommunicationPreference.where(recipient_type: 'Contact', recipient_id: quote.contact.id)
  if contact_prefs.any?
    puts "  📧 Contact-level preferences:"
    contact_prefs.each do |pref|
      status = pref.opted_in ? "✅ OPTED IN" : "❌ OPTED OUT"
      puts "     • #{pref.channel} / #{pref.category}: #{status}"
    end
  else
    puts "  ✅ No Contact-level preferences (defaults to opted-in)"
  end
end

# Check for Account-level preferences
if quote.account
  account_prefs = CommunicationPreference.where(recipient_type: 'Account', recipient_id: quote.account.id)
  if account_prefs.any?
    puts "  🏢 Account-level preferences:"
    account_prefs.each do |pref|
      status = pref.opted_in ? "✅ OPTED IN" : "❌ OPTED OUT"
      puts "     • #{pref.channel} / #{pref.category}: #{status}"
    end
  else
    puts "  ✅ No Account-level preferences (defaults to opted-in)"
  end
end

puts "\n🔧 RECOMMENDED FIXES:"

# Check old system
if quote.contact && (quote.contact.opt_out_email || quote.contact.opt_out_sms)
  puts "\n  FIX #1: Update Contact opt-out flags"
  puts "  Run this in Rails console:"
  puts "  ---"
  puts "  contact = Contact.find(#{quote.contact.id})"
  if quote.contact.opt_out_email
    puts "  contact.update(opt_out_email: false, opt_out_email_at: nil)"
  end
  if quote.contact.opt_out_sms
    puts "  contact.update(opt_out_sms: false, opt_out_sms_at: nil)"
  end
  puts "  ---"
end

# Check new system
all_quote_prefs = CommunicationPreference.where(recipient_type: 'Quote')
if all_quote_prefs.any?
  puts "\n  FIX #2: Clean up Quote-level preferences"
  puts "  Run: rails runner lib/immediate_fix.rb"
end

puts "\n" + ("=" * 80)
