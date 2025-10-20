# Debug script to diagnose quote preference issue
# Run with: rails runner lib/debug_quote_preferences.rb <quote_id>

quote_id = ARGV[0] || 21  # Default to quote 21 from the error log

puts "=" * 80
puts "COMMUNICATION PREFERENCE DEBUG FOR QUOTE ##{quote_id}"
puts "=" * 80

quote = Quote.find_by(id: quote_id)

unless quote
  puts "\n❌ Quote ##{quote_id} not found!"
  exit 1
end

puts "\n📋 QUOTE DETAILS:"
puts "  ID: #{quote.id}"
puts "  Quote Number: #{quote.quote_number}"
puts "  Status: #{quote.status}"
puts "  Contact ID: #{quote.contact_id}"
puts "  Account ID: #{quote.account_id}"

if quote.contact
  puts "\n👤 CONTACT:"
  puts "  ID: #{quote.contact.id}"
  puts "  Name: #{quote.contact.first_name} #{quote.contact.last_name}"
  puts "  Email: #{quote.contact.email}"
  puts "  Phone: #{quote.contact.phone}"
end

if quote.account
  puts "\n🏢 ACCOUNT:"
  puts "  ID: #{quote.account.id}"
  puts "  Name: #{quote.account.name}"
  puts "  Email: #{quote.account.email}"
  puts "  Phone: #{quote.account.phone}"
end

puts "\n🔍 CHECKING PREFERENCE RECORDS:"

# Check for Quote-level preferences
quote_prefs = CommunicationPreference.where(recipient_type: 'Quote', recipient_id: quote.id)
if quote_prefs.any?
  puts "\n⚠️  FOUND QUOTE-LEVEL PREFERENCES (THESE ARE THE PROBLEM!):"
  quote_prefs.each do |pref|
    puts "  - #{pref.channel} / #{pref.category}: opted_in=#{pref.opted_in}"
    puts "    Opted out reason: #{pref.opted_out_reason}" if pref.opted_out_reason.present?
  end
else
  puts "\n✅ No Quote-level preferences found (good!)"
end

# Check for Contact-level preferences
if quote.contact
  contact_prefs = CommunicationPreference.where(recipient_type: 'Contact', recipient_id: quote.contact.id)
  if contact_prefs.any?
    puts "\n📧 CONTACT-LEVEL PREFERENCES:"
    contact_prefs.each do |pref|
      puts "  - #{pref.channel} / #{pref.category}: opted_in=#{pref.opted_in}"
    end
  else
    puts "\n✅ No Contact-level preferences (will default to opted-in)"
  end
end

# Check for Account-level preferences
if quote.account
  account_prefs = CommunicationPreference.where(recipient_type: 'Account', recipient_id: quote.account.id)
  if account_prefs.any?
    puts "\n🏢 ACCOUNT-LEVEL PREFERENCES:"
    account_prefs.each do |pref|
      puts "  - #{pref.channel} / #{pref.category}: opted_in=#{pref.opted_in}"
    end
  else
    puts "\n✅ No Account-level preferences (will default to opted-in)"
  end
end

puts "\n💡 WHAT SHOULD HAPPEN:"
recipient = quote.contact || quote.account
if recipient
  puts "  - CommunicationService should check preferences for #{recipient.class.name} ##{recipient.id}"
  puts "  - If no preference exists, default to opted-in for transactional/quotes"
else
  puts "  - ⚠️  Quote has no Contact or Account! Preference check will be skipped."
end

puts "\n🔧 RECOMMENDED ACTIONS:"
if quote_prefs.any?
  puts "  1. Run: rake fix:quote_preferences"
  puts "     This will migrate Quote-level preferences to Contact/Account level"
  puts "\n  2. Or run: rake fix:delete_quote_preferences"
  puts "     This will delete all Quote-level preferences (simpler, but loses history)"
end

if recipient
  puts "\n  3. Test sending after cleanup:"
  puts "     QuoteSendingService.new(Quote.find(#{quote_id})).send(delivery_methods: ['email'], to_email: '#{recipient.email}')"
else
  puts "\n  3. ⚠️  This quote needs a Contact or Account before it can be sent!"
end

puts "\n" + ("=" * 80)
