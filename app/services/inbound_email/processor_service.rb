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
      
      # Broadcast notification to user (leverages existing notification system)
      broadcast_reply_notification(entity, communication)
      
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
      
      # Create communication record associated with the user
      communication = Communication.create!(
        communicable_type: 'User',
        communicable_id: user.id,
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
    
    # Broadcast reply notification to entity owner
    def broadcast_reply_notification(entity, communication)
      # Determine entity owner (user to notify)
      user = case entity
             when Lead
               entity.owner || entity.company.users.where(is_active: true).first
             when Contact
               entity.account&.owner || entity.company.users.where(is_active: true).first
             when Deal
               entity.owner || entity.company.users.where(is_active: true).first
             when Account
               entity.owner || entity.company.users.where(is_active: true).first
             else
               nil
             end
      
      return unless user
      
      # Entity name for notification
      entity_name = case entity
                    when Lead
                      "#{entity.first_name} #{entity.last_name}".strip
                    when Contact
                      "#{entity.first_name} #{entity.last_name}".strip
                    when Deal
                      entity.name
                    when Account
                      entity.name
                    else
                      'Unknown'
                    end
      
      # Broadcast to user's channel
      broadcast_data = {
        type: 'email_reply',
        communication: {
          id: communication.id,
          from: communication.from_address,
          subject: communication.subject,
          preview: communication.body&.truncate(100)
        },
        entity: {
          type: entity.class.name.downcase,
          id: entity.id,
          name: entity_name
        },
        timestamp: Time.current.iso8601
      }
      
      ActionCable.server.broadcast(
        "user_notifications_#{user.id}",
        broadcast_data
      )
      
      Rails.logger.info "[ProcessorService] Broadcasted reply notification to User ##{user.id} for #{entity.class.name} ##{entity.id}"
    rescue => e
      Rails.logger.error "[ProcessorService] Failed to broadcast notification: #{e.message}"
      # Don't fail the whole process if notification fails
    end
  end
end
