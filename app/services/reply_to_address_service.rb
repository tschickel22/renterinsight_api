# frozen_string_literal: true

# Generates reply-to addresses for tracking email replies
# Format: reply+{entity_type}-{entity_id}@{mail_domain}
# Example: reply+lead-38@mail.renterinsight.com
#
# Usage:
#   ReplyToAddressService.generate_for(communication)
#   # => "reply+lead-38@mail.renterinsight.com"
#
class ReplyToAddressService
  # Default mail domain for receiving replies
  # IMPORTANT: This must have MX records configured for inbound email processing
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
    
    # Generate a BCC address for a company to capture external emails
    # @param company [Company] The company
    # @return [String] The BCC address for capturing emails
    def generate_bcc_address(company)
      "#{BCC_PREFIX}+bcc-#{company.id}@#{mail_domain}"
    end
    
    # Parse an incoming reply-to address to extract entity info
    # @param address [String] The incoming email address
    # @return [Hash, nil] Parsed data or nil if invalid
    def parse(address)
      return nil if address.blank?
      
      # Extract local part (before @)
      local_part = address.to_s.split('@').first&.downcase
      return nil if local_part.blank?
      
      # Check for reply format: reply+{entity_type}-{entity_id}
      # Example: reply+lead-38 → { type: :reply, entity_type: "Lead", entity_id: 38 }
      if local_part.start_with?("#{REPLY_PREFIX}+")
        token = local_part.sub("#{REPLY_PREFIX}+", '')
        parts = token.split('-')
        
        if parts.length == 2
          return {
            type: :reply,
            entity_type: parts[0].capitalize,  # "lead" → "Lead"
            entity_id: parts[1].to_i
          }
        end
      end
      
      # Check for BCC format: crm+bcc-{company_id}
      if local_part.start_with?("#{BCC_PREFIX}+")
        token = local_part.sub("#{BCC_PREFIX}+", '')
        
        if token.start_with?('bcc-')
          company_id = token.sub('bcc-', '').to_i
          return {
            type: :bcc_capture,
            company_id: company_id
          }
        end
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
    
    # Generate tracked address using entity type and ID
    # reply+lead-38@mail.renterinsight.com (for Lead #38)
    # reply+contact-456@mail.renterinsight.com (for Contact #456)
    def generate_tracked_address(communication)
      return nil unless communication.communicable
      
      # Get entity type and ID
      entity_type = communication.communicable_type.downcase  # "Lead" → "lead"
      entity_id = communication.communicable_id
      
      "#{REPLY_PREFIX}+#{entity_type}-#{entity_id}@#{mail_domain}"
    end
  end
end
