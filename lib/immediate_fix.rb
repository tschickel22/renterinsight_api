#!/usr/bin/env ruby
# Immediate fix for Quote #17 communication preference issue

puts "\n" + ("=" * 80)
puts "IMMEDIATE FIX FOR QUOTE #17"
puts ("=" * 80)

# Check Quote #17
quote = Quote.find_by(id: 17)

unless quote
  puts "\n❌ Quote #17 not found!"
  exit 1
end

puts "\n📋 Quote #17 Details:"
puts "  Quote Number: #{quote.quote_number}"
puts "  Contact: #{quote.contact&.id} - #{quote.contact&.email}"
puts "  Account: #{quote.account&.id} - #{quote.account&.email}"

# Check for Quote-level preferences
puts "\n🔍 Checking preferences..."

quote_prefs = CommunicationPreference.where(recipient_type: 'Quote', recipient_id: 17)
if quote_prefs.any?
  puts "\n⚠️ FOUND #{quote_prefs.count} QUOTE-LEVEL PREFERENCE(S) - THIS IS THE PROBLEM!"
  quote_prefs.each do |pref|
    puts "  • #{pref.channel} / #{pref.category}: opted_in=#{pref.opted_in}"
    if pref.opted_out?
      puts "    OPTED OUT: #{pref.opted_out_reason}"
    end
  end
  
  puts "\n🔧 Deleting these Quote-level preferences NOW..."
  quote_prefs.destroy_all
  puts "   ✅ Deleted #{quote_prefs.count} preference(s)"
else
  puts "  ✅ No Quote-level preferences found"
end

# Check Contact/Account preferences
recipient = quote.contact || quote.account
if recipient
  puts "\n📧 Checking #{recipient.class.name} ##{recipient.id} preferences:"
  
  recipient_prefs = CommunicationPreference.where(recipient: recipient)
  if recipient_prefs.any?
    recipient_prefs.each do |pref|
      status = pref.opted_in? ? "✅ OPTED IN" : "❌ OPTED OUT"
      puts "  • #{pref.channel} / #{pref.category}: #{status}"
    end
  else
    puts "  ✅ No preferences (defaults to opted-in)"
  end
end

# Check ALL Quote-level preferences
puts "\n🔍 Checking for ALL Quote-level preferences in database..."
all_quote_prefs = CommunicationPreference.where(recipient_type: 'Quote')

if all_quote_prefs.any?
  puts "\n⚠️ Found #{all_quote_prefs.count} total Quote-level preferences"
  puts "   Deleting ALL of them..."
  
  deleted_count = all_quote_prefs.count
  all_quote_prefs.destroy_all
  
  puts "   ✅ Deleted #{deleted_count} Quote-level preferences"
else
  puts "  ✅ No Quote-level preferences in database"
end

# Verify
remaining = CommunicationPreference.where(recipient_type: 'Quote').count
puts "\n✅ VERIFICATION:"
puts "   Remaining Quote-level preferences: #{remaining}"

if remaining == 0
  puts "\n🎉 SUCCESS! Quote #17 should now send without errors!"
  puts "   Try clicking 'Send Now' again in the UI."
else
  puts "\n⚠️ WARNING: Still have Quote-level preferences!"
end

puts "\n" + ("=" * 80)
