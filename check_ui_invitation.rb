#!/usr/bin/env ruby
# frozen_string_literal: true

puts "=" * 80
puts "🔍 CHECKING UI-CREATED INVITATION"
puts "=" * 80

token = "OI8O_QSOFDROHXlj2Du5WFN8Rr7fRe4nGqijKAeYMVk"

puts "\n1️⃣ TOKEN FROM EMAIL/SMS:"
puts "   Token: #{token}"

# Calculate what the digest should be
token_digest = Digest::SHA256.hexdigest(token)
puts "   Expected digest: #{token_digest}"

# Try to find invitation with this token
puts "\n2️⃣ SEARCHING FOR INVITATION WITH THIS TOKEN:"
invitation = Invitation.find_by(token_digest: token_digest)

if invitation
  puts "   ✅ Found invitation with matching token!"
  puts "   Invitation ID: #{invitation.id}"
  puts "   Email: #{invitation.email}"
  puts "   Status: #{invitation.status}"
  puts "   Created: #{invitation.created_at}"
else
  puts "   ❌ No invitation found with this token digest"
end

# Get the most recent invitation
puts "\n3️⃣ MOST RECENT INVITATION:"
recent = Invitation.order(created_at: :desc).first
puts "   ID: #{recent.id}"
puts "   Email: #{recent.email}"
puts "   Status: #{recent.status}"
puts "   Created: #{recent.created_at}"
puts "   Token digest: #{recent.token_digest}"

# Check communications for this recent invitation
puts "\n4️⃣ COMMUNICATIONS FOR RECENT INVITATION:"
comms = Communication.where(communicable_type: 'Invitation', communicable_id: recent.id).order(created_at: :desc)

comms.each do |comm|
  puts "\n   📧 #{comm.channel.upcase} (ID: #{comm.id})"
  puts "   To: #{comm.to_address}"
  puts "   Created: #{comm.created_at}"
  
  if comm.body =~ /token=([^"\s&<]+)/
    comm_token = $1
    puts "   Token in message: #{comm_token}"
    
    if comm_token == token
      puts "   ✅ This matches the token from your email!"
    else
      puts "   ❌ This DOES NOT match the token from your email!"
      puts "      Expected: #{token}"
      puts "      Got: #{comm_token}"
    end
    
    # Check if this token exists
    comm_digest = Digest::SHA256.hexdigest(comm_token)
    if comm_digest == recent.token_digest
      puts "   ✅ Token in message matches invitation's token_digest"
    else
      puts "   ❌ Token in message DOES NOT match invitation's token_digest!"
    end
  end
end

puts "\n" + "=" * 80
puts "🎯 DIAGNOSIS:"

if invitation && invitation.id == recent.id
  puts "   The token from your email/SMS matches the most recent invitation."
  puts "   The invitation exists and should work."
  puts "   ⚠️  Check if invitation is expired or has wrong status."
elsif invitation
  puts "   The token matches invitation ##{invitation.id}, but most recent is ##{recent.id}"
  puts "   ❌ WRONG INVITATION was sent in email/SMS!"
else
  puts "   ❌ The token from your email/SMS doesn't exist in database!"
  puts "   The most recent invitation has a DIFFERENT token."
  puts "   🐛 BUG CONFIRMED: Wrong token sent in communications!"
end

puts "=" * 80
