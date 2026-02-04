# frozen_string_literal: true

module InboundEmail
  class ProcessorService
    attr_reader :parsed_email
    
    def initialize(parsed_email)
      @parsed_email = parsed_email
    end
    
    # Process the parsed email and create Communication record
    def process
      token = parsed_email[:token]
      
      unless token
        return { success: false, error: 'No token found in email address' }
      end
      
      case token[:prefix]
      when 'reply'
        process_reply_tracking(token[:token])
      when 'crm'
        process_bcc_capture(token[:token])
      else
        { success: false, error: "Unknown token prefix: #{token[:prefix]}" }
      end
    rescue => e
      Rails.logger.error "[ProcessorService] Error: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      { success: false, error: e.message }
    end
    
    private
    
    # Process reply tracking token: reply+lead-123@mail.renterinsight.com
    def process_reply_tracking(token)
      # Parse token: "lead-123" → entity_type: "Lead", entity_id: 123
      parts = token.split('-')
      
      unless parts.length == 2
        return { success: false, error: "Invalid token format: #{token}" }
      end
      
      entity_type = parts[0].capitalize  # "lead" → "Lead"
      entity_id = parts[1].to_i
      
      # Find the entity
      entity = find_entity(entity_type, entity_id)
      
      unless entity
        return { success: false, error: "#{entity_type} ##{entity_id} not found" }
      end
      
      # Create Communication record
      # Use body_html if available (contains HTML), otherwise fall back to body_text
      body_content = parsed_email[:body_html].presence || parsed_email[:body_text]
      
      communication = Communication.create!(
        communicable: entity,
        channel: 'email',
        direction: 'inbound',
        from_address: parsed_email[:from],
        to_address: parsed_email[:to],
        subject: parsed_email[:subject],
        body: body_content,
        sent_at: parsed_email[:timestamp],
        status: 'delivered',
        metadata: {
          message_id: parsed_email[:message_id],
          reply_tracking_token: token,
          source: 'aws_ses_inbound'
        }
      )
      
      Rails.logger.info "[ProcessorService] Created Communication ##{communication.id} for #{entity_type} ##{entity_id}"
      
      { success: true, communication_id: communication.id }
    end
    
    # Process BCC capture token: crm+bcc-5@mail.renterinsight.com
    def process_bcc_capture(token)
      # TODO: Implement BCC capture in Phase 2
      # Will match sender email to Contact/Lead in company
      { success: false, error: 'BCC capture not yet implemented' }
    end
    
    # Find entity by type and ID
    def find_entity(entity_type, entity_id)
      case entity_type
      when 'Lead'
        Lead.find_by(id: entity_id)
      when 'Contact'
        Contact.find_by(id: entity_id)
      when 'Deal'
        Deal.find_by(id: entity_id)
      when 'Account'
        Account.find_by(id: entity_id)
      else
        nil
      end
    end
  end
end
