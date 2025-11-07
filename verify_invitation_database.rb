#!/usr/bin/env ruby
# frozen_string_literal: true

# Verify database state after invitation creation
puts "=" * 80
puts "🔍 INVITATION DATABASE VERIFICATION"
puts "=" * 80

# Get the last 3 invitations
puts "\n📊 Last 3 invitations in database:"
Invitation.order(created_at: :desc).limit(3).each_with_index do |inv, i|
  puts "\n#{i + 1}. Invitation ##{inv.id}"
  puts "   Email: #{inv.email}"
  puts "   Phone: #{inv.phone}"
  puts "   Status: #{inv.status}"
  puts "   Type: #{inv.invitation_type}"
  puts "   Created: #{inv.created_at}"
  puts "   Token digest (first 32 chars): #{inv.token_digest[0..31]}..."
end

# Get the last 3 communications for invitations
puts "\n" + "=" * 80
puts "📧 Last 3 invitation communications sent:"
Communication
  .where(communicable_type: 'Invitation')
  .order(created_at: :desc)
  .limit(3)
  .each_with_index do |comm, i|
    puts "\n#{i + 1}. Communication ##{comm.id}"
    puts "   To: #{comm.to_address}"
    puts "   Channel: #{comm.channel}"
    puts "   Status: #{comm.status}"
    puts "   Sent: #{comm.created_at}"
    puts "   Invitation ID: #{comm.communicable_id}"
    
    # Extract token from body
    if comm.body =~ /token=([^"\s&<]+)/
      token_in_body = $1
      puts "   Token in message: #{token_in_body}"
      
      # Check if token exists in database
      token_digest = Digest::SHA256.hexdigest(token_in_body)
      matching_invitation = Invitation.find_by(token_digest: token_digest)
      
      if matching_invitation
        puts "   ✅ Token matches Invitation ##{matching_invitation.id}"
        if matching_invitation.id == comm.communicable_id
          puts "      ✅ Correct invitation!"
        else
          puts "      ❌ WRONG invitation! Communication is for ##{comm.communicable_id}"
        end
      else
        puts "   ❌ Token NOT FOUND in any invitation!"
        puts "      Looking for digest: #{token_digest}"
        
        # Check if it's in the last 5 invitations
        puts "\n   🔍 Checking last 5 invitation digests:"
        Invitation.order(created_at: :desc).limit(5).each do |inv|
          puts "      Invitation ##{inv.id}: #{inv.token_digest[0..31]}..."
        end
      end
    else
      puts "   ⚠️ No token found in message body!"
    end
  end

puts "\n" + "=" * 80
puts "✅ Verification complete!"
puts "=" * 80
