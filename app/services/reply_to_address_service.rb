# frozen_string_literal: true

# Generates reply-to addresses for tracking email replies
# Format: reply+{communication_id}@{mail_domain}
#
# Usage:
#   ReplyToAddressService.generate_for(communication)
#   # => "reply+abc123@mail.renterinsight.com"
#
#   ReplyToAddressService.parse("reply+abc123@mail.renterinsight.com")
#   # => { communication_id: "abc123" }
#
# Environment Setup:
#   - INBOUND_MAIL_DOMAIN: The domain configured to receive inbound emails
#   - This should be DIFFERENT from your outbound sending domain
#   - Example: Outbound = notifications.renterinsight.com, Inbound = mail.renterinsight.com
#
# DNS Requirements for inbound domain:
#   - MX record pointing to your inbound processor (SendGrid, AWS SES, Mailgun)
#   - Example: mail.renterinsight.com MX 10 mx.sendgrid.net
#
class ReplyToAddressService
  # Default mail domain for receiving replies
  # IMPORTANT: This must have MX records configured for inbound email processing
  # In development, replies won't actually arrive - test inbound in staging
  MAIL_DOMAIN = ENV.fetch('INBOUND_MAIL_DOMAIN', 'mail.renterinsight.com')
  
  # Prefix for reply tracking
  REPLY_PREFIX = 'reply'
  
  # Prefix for BCC capture (user sends from external client, BCCs to capture)
  BCC_PREFIX = 'crm'
  
  class << self
    # Generate a routable reply-to address for a communication
    # @param communication [Communication] The communication record
    # @param user [User, nil] Optional user to route replies to
    # @return [String] The generated reply-to address
    def generate_for(communication, user: nil)
      # If user has a personal email configured, use that
      if user&.respond_to?(:default_email_connection) && user.default_email_connection&.verified?
        return user.default_email_connection.email_address
      end
      
      # Generate platform-tracked reply address
      generate_tracked_address(communication)
    end
    
    # Generate a BCC address for a user to capture external emails
    # @param user [User] The user
    # @return [String] The BCC address for capturing emails
    def generate_bcc_address(user)
      "#{BCC_PREFIX}+#{user.id}@#{mail_domain}"
    end
    
    # Parse an incoming reply-to address to extract the communication ID
    # @param address [String] The incoming email address
    # @return [Hash, nil] Parsed data or nil if invalid
    def parse(address)
      return nil if address.blank?
      
      # Extract local part (before @)
      local_part = address.to_s.split('@').first&.downcase
      return nil if local_part.blank?
      
      # Check for reply format: reply+{communication_id}
      if local_part.start_with?("#{REPLY_PREFIX}+")
        communication_id = local_part.sub("#{REPLY_PREFIX}+", '')
        return nil if communication_id.blank?
        
        return {
          type: :reply,
          communication_id: communication_id
        }
      end
      
      # Check for BCC format: crm+{user_id}
      if local_part.start_with?("#{BCC_PREFIX}+")
        user_id = local_part.sub("#{BCC_PREFIX}+", '')
        return nil if user_id.blank?
        
        return {
          type: :bcc_capture,
          user_id: user_id.to_i
        }
      end
      
      nil
    end
    
    # Check if an address is a valid platform reply address
    def platform_reply_address?(address)
      return false if address.blank?
      
      domain = address.to_s.split('@').last&.downcase
      domain == mail_domain.downcase
    end
    
    # Get the configured mail domain
    def mail_domain
      MAIL_DOMAIN
    end
    
    private
    
    def generate_tracked_address(communication)
      # Use a short, unique identifier based on communication ID
      # We use the communication ID directly for simplicity
      # Could also use a hash for obfuscation: 
      #   Digest::SHA256.hexdigest("#{communication.id}-#{communication.created_at}")[0..10]
      
      "#{REPLY_PREFIX}+#{communication.id}@#{mail_domain}"
    end
  end
end
