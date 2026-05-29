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
        if token[:token].to_s.start_with?('campaign-')
          # First, attempt classification as bounce or auto-reply.
          bounce_result = Campaigns::BounceHandler.process(token: token[:token], parsed_email: parsed_email)

          if bounce_result.handled
            { success: true, source: 'campaign_bounce_handler', classification: bounce_result.classification, enrollment_id: bounce_result.enrollment_id, send_id: bounce_result.send_id }
          else
            # Not a bounce/OOO — pass through to ReplyHandler.
            reply_result = Campaigns::ReplyHandler.process(token: token[:token], parsed_email: parsed_email)
            if reply_result.handled
              { success: true, source: 'campaign_reply_handler', enrollment_id: reply_result.enrollment_id, send_id: reply_result.send_id, is_ooo: reply_result.is_ooo }
            else
              { success: false, error: 'Campaign send not found for reply token' }
            end
          end
        else
          process_reply_tracking(token[:token])
        end
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
      
      # Strip HTML tags before saving to database (fix for displaying clean text)
      clean_body = strip_html_tags(body_content)
      
      communication = Communication.create!(
        communicable: entity,
        channel: 'email',
        direction: 'inbound',
        from_address: parsed_email[:from],
        to_address: parsed_email[:to],
        subject: parsed_email[:subject],
        body: clean_body,
        sent_at: parsed_email[:timestamp],
        status: 'delivered',
        metadata: {
          message_id: parsed_email[:message_id],
          reply_tracking_token: token,
          source: 'aws_ses_inbound'
        }
      )
      
      Rails.logger.info "[ProcessorService] Created Communication ##{communication.id} for #{entity_type} ##{entity_id}"

      # Notify the sender of the original email (falls back to owner): bell, email, SMS, toast.
      InboundEmail::ReplyNotifier.notify(entity: entity, communication: communication)

      { success: true, communication_id: communication.id }
    end
    
    # Process BCC capture token: crm+bcc-54@mail.renterinsight.com
    def process_bcc_capture(token)
      # Extract user ID from "bcc-54" format
      unless token =~ /^bcc-(\d+)$/
        Rails.logger.error "[ProcessorService] Invalid BCC token format: #{token}"
        return { success: false, error: "Invalid BCC token format: #{token}" }
      end
      
      user_id = $1.to_i
      
      # Find the user
      user = User.find_by(id: user_id)
      
      unless user
        Rails.logger.error "[ProcessorService] User ##{user_id} not found for BCC token"
        return { success: false, error: "User ##{user_id} not found" }
      end
      
      Rails.logger.info "[ProcessorService] Processing BCC capture for User ##{user_id} (#{user.email})"
      
      # Use body_html if available (contains HTML), otherwise fall back to body_text
      body_content = parsed_email[:body_html].presence || parsed_email[:body_text]
      
      # Strip HTML tags before saving to database (fix for displaying clean text)
      clean_body = strip_html_tags(body_content)
      
      # Create communication record associated with the user
      communication = Communication.create!(
        communicable_type: 'User',
        communicable_id: user.id,
        channel: 'email',
        direction: 'inbound',
        from_address: parsed_email[:from],
        to_address: parsed_email[:to],
        subject: parsed_email[:subject],
        body: clean_body,
        sent_at: parsed_email[:timestamp],
        status: 'delivered',
        metadata: {
          message_id: parsed_email[:message_id],
          bcc_capture: true,
          original_to: parsed_email[:to],
          captured_via: "crm+bcc-#{user_id}@mail.renterinsight.com",
          source: 'aws_ses_inbound'
        }
      )
      
      Rails.logger.info "[ProcessorService] BCC Capture: Created Communication ##{communication.id} for User ##{user_id}"
      
      { success: true, communication_id: communication.id, user_id: user_id }
    rescue => e
      Rails.logger.error "[ProcessorService] BCC capture error: #{e.message}"
      { success: false, error: e.message }
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
    
    
    # Strip HTML tags AND decode HTML entities (matches Platform::CommunicationsController)
    def strip_html_tags(html)
      return nil if html.blank?
      
      # Use Rails sanitizer to remove ALL HTML/VML tags (handles Outlook VML)
      text = ActionView::Base.full_sanitizer.sanitize(html)
      
      # Decode HTML entities (CRITICAL - Rails sanitizer doesn't do this!)
      text = text.gsub('&nbsp;', ' ')
                 .gsub('&amp;', '&')
                 .gsub('&lt;', '<')
                 .gsub('&gt;', '>')
                 .gsub('&quot;', '"')
                 .gsub('&#39;', "'")
                 .gsub('&apos;', "'")
      
      # Clean up whitespace
      text.gsub(/\s+/, ' ').strip
    end
  end
end
