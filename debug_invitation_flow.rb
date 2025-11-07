#!/usr/bin/env ruby
# frozen_string_literal: true

# Debug script to trace raw_token through entire invitation creation flow
# This will help us find where the token gets lost or changed

puts "=" * 80
puts "🔍 INVITATION TOKEN FLOW DEBUGGER"
puts "=" * 80
puts ""

# Monkey patch to intercept invitation creation
module InvitationDebugger
  def create_for_user(params)
    puts "\n📍 STEP 1: Invitation.create_for_user called"
    puts "   Params: #{params.inspect}"
    
    # Call original method
    invitation, raw_token = super
    
    puts "\n✅ STEP 1 RESULT:"
    puts "   Invitation ID: #{invitation.id}"
    puts "   Raw Token: #{raw_token}"
    puts "   Token Digest in DB: #{invitation.token_digest}"
    
    # Verify the token immediately
    token_digest = Digest::SHA256.hexdigest(raw_token)
    if token_digest == invitation.token_digest
      puts "   ✅ Token digest matches! (Raw token hashes to stored digest)"
    else
      puts "   ❌ MISMATCH! Raw token doesn't match stored digest!"
      puts "      Calculated digest: #{token_digest}"
      puts "      Stored digest: #{invitation.token_digest}"
    end
    
    [invitation, raw_token]
  end
end

# Monkey patch to intercept InvitationService
module InvitationServiceDebugger
  def create_invitation(params)
    puts "\n📍 STEP 2: InvitationService.create_invitation called"
    puts "   Params: #{params.inspect}"
    
    # Intercept the invitation creation
    original_create = Invitation.method(:create_for_user)
    Invitation.define_singleton_method(:create_for_user) do |*args|
      puts "\n   📍 STEP 2a: About to call Invitation.create_for_user"
      invitation, raw_token = original_create.call(*args)
      puts "   ✅ STEP 2a RESULT: Raw token = #{raw_token}"
      [invitation, raw_token]
    end
    
    result = super
    
    puts "\n✅ STEP 2 RESULT:"
    if result[:success]
      puts "   Success: #{result[:success]}"
      puts "   Invitation ID: #{result[:invitation]&.id}"
      puts "   Raw Token in service result: #{result[:raw_token]}"
    else
      puts "   Error: #{result[:error]}"
    end
    
    result
  end
  
  def build_invitation_context(invitation, raw_token)
    puts "\n📍 STEP 3: Building invitation context for email/SMS"
    puts "   Invitation ID: #{invitation.id}"
    puts "   Raw Token received: #{raw_token}"
    
    context = super
    
    puts "✅ STEP 3 RESULT: Context built"
    puts "   Invitation URL: #{context[:invitation_url]}"
    
    # Extract token from URL
    if context[:invitation_url] =~ /token=([^&]+)/
      url_token = $1
      puts "   Token in URL: #{url_token}"
      
      if url_token == raw_token
        puts "   ✅ URL token matches raw_token"
      else
        puts "   ❌ MISMATCH! URL token != raw_token"
        puts "      Expected: #{raw_token}"
        puts "      Got: #{url_token}"
      end
    end
    
    context
  end
  
  def send_invitation_communications(invitation, raw_token)
    puts "\n📍 STEP 4: Sending communications"
    puts "   Invitation ID: #{invitation.id}"
    puts "   Raw Token: #{raw_token}"
    
    result = super
    
    puts "✅ STEP 4 RESULT: Communications sent"
    result
  end
end

# Monkey patch to intercept CommunicationService
class CommunicationService
  alias_method :original_send_communication, :send_communication
  
  def send_communication(template:, recipient:, context: {}, force_send: false)
    puts "\n📍 STEP 5: CommunicationService.send_communication"
    puts "   Template: #{template.name}"
    puts "   Recipient: #{recipient}"
    puts "   Context keys: #{context.keys}"
    
    if context[:invitation_url]
      puts "   Invitation URL in context: #{context[:invitation_url]}"
      if context[:invitation_url] =~ /token=([^&]+)/
        puts "   Token in invitation_url: #{$1}"
      end
    end
    
    if context[:invitation_token]
      puts "   Raw token in context: #{context[:invitation_token]}"
    end
    
    result = original_send_communication(
      template: template,
      recipient: recipient,
      context: context,
      force_send: force_send
    )
    
    puts "✅ STEP 5 RESULT: Communication #{result[:communication_id]}"
    
    # Show what was actually sent
    if result[:communication_id]
      comm = Communication.find(result[:communication_id])
      puts "\n📧 ACTUAL MESSAGE SENT:"
      puts "   To: #{comm.to}"
      puts "   Channel: #{comm.channel}"
      if comm.body =~ /token=([^"\s&<]+)/
        token_in_message = $1
        puts "   Token in message body: #{token_in_message}"
        
        # Check if this token exists in database
        token_digest = Digest::SHA256.hexdigest(token_in_message)
        db_invitation = Invitation.find_by(token_digest: token_digest)
        
        if db_invitation
          puts "   ✅ Token EXISTS in database! (Invitation ##{db_invitation.id})"
        else
          puts "   ❌ Token NOT FOUND in database!"
          puts "      Token digest: #{token_digest}"
        end
      end
    end
    
    result
  end
end

# Apply the patches
Invitation.singleton_class.prepend(InvitationDebugger)
InvitationService.prepend(InvitationServiceDebugger)

puts "\n✅ Debug patches applied!"
puts "━" * 80
puts "\n📝 NOW CREATE AN INVITATION VIA THE UI"
puts "This script will trace the entire flow and show you where the token goes wrong."
puts "\nWhen done, press Ctrl+C to exit Rails console."
puts "\n━" * 80
