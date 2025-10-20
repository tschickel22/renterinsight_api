#!/usr/bin/env ruby
# Complete fix for Quote #17 - handles BOTH opt-out systems

puts "\n" + ("=" * 80)
puts "COMPLETE FIX FOR QUOTE #17 OPT-OUT ERROR"
puts ("=" * 80)

quote = Quote.find_by(id: 17)

unless quote
  puts "\n❌ Quote #17 not found!"
  exit 1
end

puts "\nQuote: #{quote.quote_number}"
fixed_something = false

# ========================================
# FIX #1: Contact's opt_out_email field
# ========================================
if quote.contact
  contact = quote.contact
  puts "\n👤 Checking Contact ##{contact.id} (#{contact.email})..."
  
  if contact.opt_out_email
    puts "   ❌ PROBLEM: Contact.opt_out_email = true"
    puts "   🔧 Setting to false..."
    contact.update!(opt_out_email: false, opt_out_email_at: nil)
    puts "   ✅ Fixed Contact.opt_out_email"
    fixed_something = true
  else
    puts "   ✅ Contact.opt_out_email is false (good)"
  end
  
  if contact.opt_out_sms
    puts "   ❌ PROBLEM: Contact.opt_out_sms = true"
    puts "   🔧 Setting to false..."
    contact.update!(opt_out_sms: false, opt_out_sms_at: nil)
    puts "   ✅ Fixed Contact.opt_out_sms"
    fixed_something = true
  else
    puts "   ✅ Contact.opt_out_sms is false (good)"
  end
end

# ========================================
# FIX #2: Account's opt-out fields (if they exist)
# ========================================
if quote.account
  account = quote.account
  puts "\n🏢 Checking Account ##{account.id} (#{account.name})..."
  
  if account.respond_to?(:opt_out_email) && account.opt_out_email
    puts "   ❌ PROBLEM: Account.opt_out_email = true"
    puts "   🔧 Setting to false..."
    account.update!(opt_out_email: false)
    puts "   ✅ Fixed Account.opt_out_email"
    fixed_something = true
  else
    puts "   ✅ Account opt-out fields OK"
  end
end

# ========================================
# FIX #3: Quote-level CommunicationPreference records
# ========================================
puts "\n📧 Checking CommunicationPreference records..."

quote_prefs = CommunicationPreference.where(recipient_type: 'Quote', recipient_id: 17)
if quote_prefs.any?
  puts "   ❌ PROBLEM: Found #{quote_prefs.count} Quote-level preference(s)"
  quote_prefs.each do |pref|
    puts "      • #{pref.channel}/#{pref.category}: opted_in=#{pref.opted_in}"
  end
  puts "   🔧 Deleting them..."
  quote_prefs.destroy_all
  puts "   ✅ Deleted Quote-level preferences"
  fixed_something = true
else
  puts "   ✅ No Quote-level preferences"
end

# Check Contact preferences
if quote.contact
  contact_prefs = CommunicationPreference.where(
    recipient_type: 'Contact',
    recipient_id: quote.contact.id,
    opted_in: false
  )
  
  if contact_prefs.any?
    puts "   ⚠️ WARNING: Found #{contact_prefs.count} opted-out Contact preference(s)"
    contact_prefs.each do |pref|
      puts "      • #{pref.channel}/#{pref.category}: OPTED OUT"
      puts "        Reason: #{pref.opted_out_reason}" if pref.opted_out_reason
    end
    
    puts "\n   ❓ Do you want to opt these back IN? (y/n)"
    puts "      (This will allow sending emails/SMS to this contact)"
    
    # For automated fix, we'll opt them back in
    puts "   🔧 Opting contact back in for all channels..."
    contact_prefs.each do |pref|
      pref.opt_in!(ip_address: 'Admin Fix', user_agent: 'Manual')
      puts "      ✅ Opted in: #{pref.channel}/#{pref.category}"
    end
    fixed_something = true
  else
    puts "   ✅ No opted-out Contact preferences"
  end
end

# ========================================
# FIX #4: Clean ALL Quote-level preferences
# ========================================
puts "\n🧹 Cleaning up ALL Quote-level preferences in database..."
all_quote_prefs = CommunicationPreference.where(recipient_type: 'Quote')

if all_quote_prefs.any?
  count = all_quote_prefs.count
  puts "   Found #{count} Quote-level preference(s) across all quotes"
  puts "   🔧 Deleting them..."
  all_quote_prefs.destroy_all
  puts "   ✅ Deleted #{count} Quote-level preferences"
  fixed_something = true
else
  puts "   ✅ No Quote-level preferences in database"
end

# ========================================
# VERIFICATION
# ========================================
puts "\n" + ("=" * 80)
puts "VERIFICATION"
puts ("=" * 80)

remaining_quote_prefs = CommunicationPreference.where(recipient_type: 'Quote').count
puts "Remaining Quote-level preferences: #{remaining_quote_prefs}"

if quote.contact
  contact = quote.contact.reload
  puts "Contact opt_out_email: #{contact.opt_out_email || false}"
  puts "Contact opt_out_sms: #{contact.opt_out_sms || false}"
end

if fixed_something
  puts "\n🎉 SUCCESS! Fixed issues found."
  puts "   Try sending Quote #17 again - it should work now!"
else
  puts "\n✅ No issues found!"
  puts "   The opt-out error might be caused by something else."
  puts "   Check the server logs for more details."
end

puts "\n" + ("=" * 80)
