#!/usr/bin/env ruby
# Clean up old invitations and prepare for fresh test

require_relative 'config/environment'

puts "\n" + "="*60
puts "🧹 CLEANING UP OLD INVITATIONS"
puts "="*60

# Count invitations
invitation_count = Invitation.count
puts "\n📊 Found #{invitation_count} old invitation(s)"

if invitation_count > 0
  puts "\n🗑️  Deleting all old invitations..."
  Invitation.destroy_all
  puts "✅ Deleted #{invitation_count} invitation(s)"
else
  puts "✅ No old invitations to delete"
end

# Also clean up old invited users (status: 'invited')
invited_users = User.where(status: 'invited')
puts "\n👥 Found #{invited_users.count} placeholder user(s) with 'invited' status"

if invited_users.count > 0
  puts "🗑️  Deleting placeholder users..."
  invited_users.destroy_all
  puts "✅ Deleted #{invited_users.count} placeholder user(s)"
end

puts "\n" + "="*60
puts "✨ CLEANUP COMPLETE!"
puts "="*60
puts "\nNext steps:"
puts "1. Go to your UI → Company Settings → Users"
puts "2. Click 'Invite User'"
puts "3. Fill in the details"
puts "4. Send invitation"
puts "5. Check your email - should have HTTPS URL"
puts "6. Click the link - should work now!"
puts "\n"
