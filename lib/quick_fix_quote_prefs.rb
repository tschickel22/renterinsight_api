#!/usr/bin/env ruby
# Quick fix script for Quote communication preferences issue
# Usage: rails runner lib/quick_fix_quote_prefs.rb

puts "\n" + ("=" * 80)
puts "QUICK FIX: Quote Communication Preferences"
puts ("=" * 80)

# Step 1: Check if problem exists
quote_pref_count = CommunicationPreference.where(recipient_type: 'Quote').count

if quote_pref_count == 0
  puts "\n✅ No Quote-level preferences found!"
  puts "   The issue has already been fixed or doesn't exist."
  puts "\n" + ("=" * 80)
  exit 0
end

puts "\n⚠️  Found #{quote_pref_count} Quote-level preference(s) - THIS IS THE PROBLEM"

# Step 2: Show what will be fixed
puts "\n📋 Details of preferences to be migrated:"
CommunicationPreference.where(recipient_type: 'Quote').limit(5).each do |pref|
  quote = Quote.find_by(id: pref.recipient_id)
  if quote
    recipient = quote.contact || quote.account
    puts "  • Quote ##{quote.id} (#{quote.quote_number})"
    puts "    #{pref.channel}/#{pref.category} - opted_in: #{pref.opted_in}"
    if recipient
      puts "    → Will migrate to #{recipient.class.name} ##{recipient.id}"
    else
      puts "    → Will DELETE (quote has no contact/account)"
    end
  else
    puts "  • Quote ##{pref.recipient_id} (NOT FOUND) - Will DELETE"
  end
end

if quote_pref_count > 5
  puts "  ... and #{quote_pref_count - 5} more"
end

# Step 3: Ask for confirmation
puts "\n❓ Do you want to migrate these preferences? (y/n)"
print "> "
response = STDIN.gets.chomp.downcase

unless response == 'y' || response == 'yes'
  puts "\n❌ Migration cancelled."
  puts "   Run 'rake fix:show_quote_preferences' to see all preferences"
  puts "   Run 'rake fix:quote_preferences' to migrate them"
  exit 0
end

# Step 4: Perform migration
puts "\n🔧 Migrating preferences..."

migrated = 0
deleted = 0
skipped = 0

CommunicationPreference.where(recipient_type: 'Quote').find_each do |quote_pref|
  quote = Quote.find_by(id: quote_pref.recipient_id)
  
  unless quote
    quote_pref.destroy
    deleted += 1
    next
  end
  
  actual_recipient = quote.contact || quote.account
  
  unless actual_recipient
    quote_pref.destroy
    deleted += 1
    next
  end
  
  existing_pref = CommunicationPreference.find_by(
    recipient: actual_recipient,
    channel: quote_pref.channel,
    category: quote_pref.category
  )
  
  if existing_pref
    if quote_pref.opted_in? && !existing_pref.opted_in?
      existing_pref.opt_in!(ip_address: 'System Migration', user_agent: 'DataMigration')
      migrated += 1
    else
      skipped += 1
    end
    quote_pref.destroy
  else
    CommunicationPreference.create!(
      recipient: actual_recipient,
      channel: quote_pref.channel,
      category: quote_pref.category,
      opted_in: quote_pref.opted_in,
      opted_in_at: quote_pref.opted_in_at,
      opted_out_at: quote_pref.opted_out_at,
      opted_out_reason: quote_pref.opted_out_reason,
      ip_address: quote_pref.ip_address,
      user_agent: quote_pref.user_agent,
      compliance_metadata: quote_pref.compliance_metadata
    )
    quote_pref.destroy
    migrated += 1
  end
end

# Step 5: Verify
remaining = CommunicationPreference.where(recipient_type: 'Quote').count

puts "\n✅ Migration complete!"
puts "   Migrated: #{migrated}"
puts "   Deleted: #{deleted}"
puts "   Skipped: #{skipped}"
puts "   Remaining Quote prefs: #{remaining}"

if remaining == 0
  puts "\n🎉 SUCCESS! All Quote-level preferences have been cleaned up."
  puts "   You can now send quotes without the 'opted out' error!"
else
  puts "\n⚠️  WARNING: #{remaining} Quote-level preference(s) still remain."
  puts "   Run this script again or contact support."
end

# Step 6: Test with the problematic quote
puts "\n📧 Testing with Quote #21 (from the error log)..."
test_quote = Quote.find_by(id: 21)
if test_quote
  recipient = test_quote.contact || test_quote.account
  if recipient
    quote_prefs = CommunicationPreference.where(recipient_type: 'Quote', recipient_id: 21).count
    recipient_prefs = CommunicationPreference.where(recipient: recipient).count
    
    puts "   Quote-level prefs for Quote #21: #{quote_prefs}"
    puts "   #{recipient.class.name}-level prefs: #{recipient_prefs}"
    
    if quote_prefs == 0
      puts "   ✅ Ready to send! Try sending Quote #21 again."
    else
      puts "   ❌ Still has Quote-level prefs. Something went wrong."
    end
  else
    puts "   ⚠️  Quote #21 has no contact or account assigned."
  end
else
  puts "   ℹ️  Quote #21 not found (maybe in a different environment)"
end

puts "\n" + ("=" * 80)
puts "For more details, see: COMMUNICATION_PREFERENCE_FIX.md"
puts ("=" * 80) + "\n"
