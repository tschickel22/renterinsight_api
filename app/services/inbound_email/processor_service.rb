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
      # Parse token: "bcc-5" → company_id: 5
      parts = token.split('-')
      
      unless parts.length == 2 && parts[0] == 'bcc'
        return { success: false, error: "Invalid BCC token format: #{token}" }
      end
      
      company_id = parts[1].to_i
      
      # Find the company
      company = Company.find_by(id: company_id)
      unless company
        return { success: false, error: "Company ##{company_id} not found" }
      end
      
      # Extract recipient email (the Lead/Contact who received the email)
      recipient_email = parsed_email[:to]
      
      # Search for Contact or Lead by email in this company
      entity = find_entity_by_email(company, recipient_email)
      
      unless entity
        Rails.logger.warn "[ProcessorService] No Contact/Lead found for #{recipient_email} in company #{company.name}"
        return { success: false, error: "No Contact or Lead found with email #{recipient_email}" }
      end
      
      # Create Communication record
      body_content = parsed_email[:body_html].presence || parsed_email[:body_text]
      
      communication = Communication.create!(
        communicable: entity,
        channel: 'email',
        direction: 'outbound',  # BCC capture is outbound from user's perspective
        from_address: parsed_email[:from],
        to_address: parsed_email[:to],
        subject: parsed_email[:subject],
        body: body_content,
        sent_at: parsed_email[:timestamp],
        status: 'delivered',
        metadata: {
          message_id: parsed_email[:message_id],
          bcc_capture_token: token,
          source: 'bcc_capture',
          company_id: company_id,
          captured_via: 'bcc'
        }
      )
      
      Rails.logger.info "[ProcessorService] BCC captured: Communication ##{communication.id} for #{entity.class.name} ##{entity.id} (#{recipient_email}) in company #{company.name}"
      
      { success: true, communication_id: communication.id, entity_type: entity.class.name, entity_id: entity.id }
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
    
    # Find Contact or Lead by email in a company
    def find_entity_by_email(company, email)
      # Normalize email for case-insensitive search
      normalized_email = email.to_s.strip.downcase
      
      # Search Contacts first (more specific)
      contact = company.contacts.where('LOWER(email) = ?', normalized_email).first
      return contact if contact
      
      # Then search Leads
      lead = company.leads.where('LOWER(email) = ?', normalized_email).first
      return lead if lead
      
      nil
    end
  end
end
