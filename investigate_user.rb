#!/usr/bin/env ruby
# frozen_string_literal: true

puts "=" * 80
puts "🔍 INVESTIGATING USER #46"
puts "=" * 80

user = User.find_by(id: 46)

if user
  puts "\n✅ User #46 found:"
  puts "   Email: #{user.email}"
  puts "   Name: #{user.name}"
  puts "   Status: #{user.status}"
  puts "   Created: #{user.created_at}"
  puts "   Invitation ID: #{user.invitation_id}"
  
  if user.invitation_id
    inv = Invitation.find_by(id: user.invitation_id)
    if inv
      puts "\n   ✅ Linked to Invitation ##{inv.id}:"
      puts "      Email: #{inv.email}"
      puts "      Status: #{inv.status}"
      puts "      Token digest: #{inv.token_digest}"
      
      # Check if the token matches
      token = "OI8O_QSOFDROHXlj2Du5WFN8Rr7fRe4nGqijKAeYMVk"
      token_digest = Digest::SHA256.hexdigest(token)
      
      if token_digest == inv.token_digest
        puts "      ✅ TOKEN MATCHES THIS INVITATION!"
      else
        puts "      ❌ Token doesn't match"
      end
    else
      puts "   ❌ Invitation ##{user.invitation_id} not found"
    end
  else
    puts "   ⚠️  User has no linked invitation_id"
  end
else
  puts "\n❌ User #46 not found"
end

puts "\n" + "=" * 80
puts "🐛 ROOT CAUSE:"
puts "=" * 80
puts "When creating invitations via UI, the CommunicationService is being"
puts "called with the USER as the communicable object instead of the INVITATION."
puts ""
puts "This means:"
puts "  1. Invitation is created correctly in invitations table"
puts "  2. User placeholder is created with invitation_id link"
puts "  3. ❌ BUG: Communications are sent with communicable = User (should be Invitation!)"
puts "  4. The token in the communication belongs to the invitation, but"
puts "     the communication is linked to the wrong record type"
puts ""
puts "The fix needs to be in InvitationService where it calls"
puts "CommunicationService - it must pass the INVITATION object, not the USER."
puts "=" * 80
