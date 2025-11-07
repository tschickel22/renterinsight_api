#!/usr/bin/env ruby
# frozen_string_literal: true

puts "=" * 80
puts "🔍 FINDING THE UI INVITATION"
puts "=" * 80

token = "OI8O_QSOFDROHXlj2Du5WFN8Rr7fRe4nGqijKAeYMVk"

# Check ALL invitations (last 10)
puts "\n📊 LAST 10 INVITATIONS:"
Invitation.order(created_at: :desc).limit(10).each_with_index do |inv, i|
  puts "\n#{i + 1}. Invitation ##{inv.id}"
  puts "   Email: #{inv.email}"
  puts "   Created: #{inv.created_at}"
  puts "   Token digest: #{inv.token_digest[0..31]}..."
end

# Check ALL communications with this token in the body
puts "\n" + "=" * 80
puts "🔍 SEARCHING ALL COMMUNICATIONS FOR THIS TOKEN:"
all_comms = Communication.where("body LIKE ?", "%#{token}%")

if all_comms.any?
  puts "   ✅ Found #{all_comms.count} communication(s) with this token!"
  
  all_comms.each do |comm|
    puts "\n   Communication ##{comm.id}"
    puts "   Channel: #{comm.channel}"
    puts "   To: #{comm.to_address}"
    puts "   Created: #{comm.created_at}"
    puts "   Invitation ID: #{comm.communicable_id}"
    puts "   Invitation Type: #{comm.communicable_type}"
    
    # Get the invitation this communication belongs to
    if comm.communicable_type == 'Invitation'
      inv = Invitation.find_by(id: comm.communicable_id)
      if inv
        puts "   📧 Invitation details:"
        puts "      Email: #{inv.email}"
        puts "      Status: #{inv.status}"
        puts "      Token digest: #{inv.token_digest}"
        
        # Check if token matches
        token_digest = Digest::SHA256.hexdigest(token)
        if token_digest == inv.token_digest
          puts "      ✅ Token MATCHES this invitation's digest!"
        else
          puts "      ❌ Token DOES NOT MATCH this invitation's digest!"
          puts "         Expected digest: #{inv.token_digest}"
          puts "         Actual digest: #{token_digest}"
        end
      end
    end
  end
else
  puts "   ❌ No communications found with this token in body!"
  puts "   This means the token was NEVER sent in any email/SMS!"
end

puts "\n" + "=" * 80
puts "🔍 CHECKING RECENT COMMUNICATIONS (last 10):"
Communication.where(communicable_type: 'Invitation').order(created_at: :desc).limit(10).each_with_index do |comm, i|
  puts "\n#{i + 1}. Communication ##{comm.id} (#{comm.channel})"
  puts "   To: #{comm.to_address}"
  puts "   Created: #{comm.created_at}"
  puts "   Invitation ID: #{comm.communicable_id}"
  
  if comm.body =~ /token=([^"\s&<]+)/
    puts "   Token: #{$1[0..20]}..."
  end
end

puts "\n" + "=" * 80
