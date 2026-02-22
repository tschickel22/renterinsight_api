# frozen_string_literal: true

module Webhooks
  class TwilioController < ActionController::API
    before_action :verify_twilio_signature, only: [:sms_status, :sms_inbound]

    # POST /webhooks/twilio/sms/status
    def sms_status
      message_sid = params['MessageSid']
      status = params['MessageStatus']
      
      Rails.logger.info "[Twilio] Webhook received: SID=#{message_sid}, Status=#{status}"
      
      communication = Communication.find_by(external_id: message_sid)
      
      unless communication
        Rails.logger.warn "[Twilio] Communication not found for SID: #{message_sid}"
        return head :ok
      end
      
      case status
      when 'sent'
        unless communication.sent_at
          communication.update!(sent_at: Time.current)
          CommunicationEvent.track_send(communication, details: twilio_params)
        end
        
      when 'delivered'
        communication.update!(
          status: 'delivered',
          delivered_at: Time.current
        )
        CommunicationEvent.track_delivery(communication, details: twilio_params)
        Rails.logger.info "[Twilio] SMS #{communication.id} delivered to #{communication.to_address}"
        
      when 'undelivered', 'failed'
        error_code = params['ErrorCode']
        error_message = params['ErrorMessage'] || 'Unknown error'
        
        communication.mark_as_failed!("Twilio Error #{error_code}: #{error_message}")
        CommunicationEvent.track_failure(
          communication,
          error: error_message,
          details: twilio_params
        )
        Rails.logger.error "[Twilio] SMS #{communication.id} failed: #{error_message}"
      end
      
      head :ok
    rescue => e
      Rails.logger.error "[Twilio] Webhook error: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      head :ok
    end

    # POST /webhooks/twilio/sms/inbound
    # Handles inbound SMS replies from contacts/leads
    def sms_inbound
      from_number = params['From']     # Contact's phone number
      to_number   = params['To']       # Our Twilio number that received the reply
      body        = params['Body']
      message_sid = params['MessageSid']

      Rails.logger.info "[TwilioWebhook] Inbound SMS from #{from_number} to #{to_number}: #{body&.truncate(100)}"

      # Handle STOP/START keyword opt-out/opt-in (A2P compliance)
      stripped_body = body.to_s.strip.upcase
      stop_keywords  = %w[STOP STOPALL UNSUBSCRIBE CANCEL END QUIT].freeze
      start_keywords = %w[START YES UNSTOP SUBSCRIBE].freeze

      if stop_keywords.include?(stripped_body) || start_keywords.include?(stripped_body)
        recipient = Contact.find_by(phone: from_number) || Lead.find_by(phone: from_number)

        if recipient
          pref = CommunicationPreference.find_or_create_for(recipient: recipient, channel: 'sms')

          if stop_keywords.include?(stripped_body)
            pref.opt_out!('SMS STOP keyword received')
            Rails.logger.info "[TwilioWebhook] STOP received from #{from_number} — opted out"
          else
            pref.opt_in!
            Rails.logger.info "[TwilioWebhook] START received from #{from_number} — opted back in"
          end
        else
          Rails.logger.warn "[TwilioWebhook] #{stripped_body} keyword from #{from_number} but no Contact/Lead found"
        end
      end

      # Match receiving number to a dedicated TwilioAccount
      twilio_account = TwilioAccount.active.find_by(phone_number: to_number)
      company = twilio_account&.company

      unless company
        platform_number = ENV['TWILIO_PHONE_NUMBER']
        if to_number == platform_number
          Rails.logger.info "[TwilioWebhook] Inbound to platform number #{to_number}"
        else
          Rails.logger.warn "[TwilioWebhook] No TwilioAccount or platform match for number #{to_number}"
          head :ok and return
        end
      end

      # Find most recent outbound SMS to this contact to link the reply to the correct
      # conversation, communicable entity, and the user who originally sent the message
      original_communication = Communication.where(
        channel: 'sms',
        direction: 'outbound',
        to_address: from_number
      ).order(created_at: :desc).first

      if original_communication
        communicable     = original_communication.communicable
        company        ||= original_communication.company
        # sender_user_id is who pressed send — this is who should receive the forwarded reply
        sender_user_id   = original_communication.metadata&.dig('sender_user_id')
        assigned_user_id = original_communication.metadata&.dig('assigned_user_id')

        Rails.logger.info "[TwilioWebhook] Matched reply to Communication ##{original_communication.id}, " \
                          "entity: #{communicable&.class&.name} ##{communicable&.id}, " \
                          "sender_user: #{sender_user_id}, assigned_user: #{assigned_user_id}"

        # Log inbound message to conversation thread
        inbound_comm = Communication.create!(
          company_id:    company&.id,
          communicable:  communicable,
          channel:       'sms',
          direction:     'inbound',
          from_address:  from_number,
          to_address:    to_number,
          body:          body,
          status:        'delivered',
          sent_at:       Time.current,
          delivered_at:  Time.current,
          metadata: {
            message_sid:          message_sid,
            sender_user_id:       sender_user_id,
            assigned_user_id:     assigned_user_id,
            matched_outbound_id:  original_communication.id,
            source:               twilio_account ? 'dedicated' : 'platform'
          }.compact
        )

        # Log inbound usage
        SmsUsageLog.log!(
          company:          company,
          direction:        'inbound',
          source:           'inbound',
          communication_id: inbound_comm&.id
        )

        # Notify the assigned user in-app that a reply arrived
        notify_user_id = sender_user_id || assigned_user_id
        if notify_user_id
          notify_user = User.find_by(id: notify_user_id)
          if notify_user
            contact_label = communicable&.respond_to?(:display_name) ? communicable.display_name : from_number
            NotificationService.create(
              recipient:         notify_user,
              notification_type: :sms_reply_received,
              notifiable:        inbound_comm,
              message:           "SMS reply from #{contact_label}: #{body&.truncate(120)}",
              company_id:        company&.id,
              action_url:        communicable ? "/contacts/#{communicable.id}?tab=communications" : nil,
              action_text:       'View Conversation'
            )
          end
        end

        # Forward reply to the user who originally sent the SMS
        # Generates a tokenized reply link so they can respond without logging in
        forward_to_id = sender_user_id || assigned_user_id
        if forward_to_id
          forward_user = User.find_by(id: forward_to_id)
          # User model has no phone field — try is safe and returns nil if method absent
          user_cell = forward_user&.try(:phone).presence || forward_user&.try(:mobile_phone).presence

          if forward_user && user_cell.present?
            # Generate or reuse a valid reply token
            sender_user = forward_user
            reply_token = SmsReplyToken.generate_for(
              communication: original_communication,
              sender_user:   sender_user,
              company:       company,
              contact_phone: from_number
            )

            forward_sms_to_sender(
              to_cell:      user_cell,
              from_number:  from_number,
              body:         body,
              communicable: communicable,
              reply_token:  reply_token.token
            )
          else
            Rails.logger.info "[TwilioWebhook] Sender user #{forward_to_id} has no cell number — skipping forward"
          end
        end

      else
        Rails.logger.warn "[TwilioWebhook] No matching outbound SMS found for #{from_number}. Logging as unmatched."

        if company
          Communication.create!(
            company_id:   company.id,
            communicable: nil,
            channel:      'sms',
            direction:    'inbound',
            from_address: from_number,
            to_address:   to_number,
            body:         body,
            status:       'delivered',
            sent_at:      Time.current,
            delivered_at: Time.current,
            metadata: {
              message_sid: message_sid,
              unmatched:   true,
              source:      twilio_account ? 'dedicated' : 'platform'
            }
          )

          SmsUsageLog.log!(
            company:          company,
            direction:        'inbound',
            source:           'inbound',
            communication_id: nil
          )
        end
      end

      # Return empty TwiML — no auto-reply to contact
      render xml: '<Response></Response>', content_type: 'text/xml'
    end

    private
    
    def verify_twilio_signature
      auth_token = ENV['TWILIO_AUTH_TOKEN']
      
      unless auth_token.present?
        Rails.logger.warn "[Twilio] Auth token not configured - skipping signature verification"
        return true
      end
      
      signature = request.headers['X-Twilio-Signature']
      
      unless signature.present?
        Rails.logger.error "[Twilio] Missing X-Twilio-Signature header"
        head :forbidden
        return false
      end
      
      validator = Twilio::Security::RequestValidator.new(auth_token)
      url = request.original_url
      post_params = request.request_parameters
      
      is_valid = validator.validate(url, post_params, signature)

      # No sub-account fallback needed — all numbers are on master account now

      unless is_valid
        Rails.logger.error "[Twilio] Invalid signature - possible spoofed request"
        head :forbidden
        return false
      end

      true
    rescue NameError => e
      Rails.logger.warn "[Twilio] Twilio gem not loaded - skipping signature verification: #{e.message}"
      true
    rescue => e
      Rails.logger.error "[Twilio] Signature verification error: #{e.message}"
      head :internal_server_error
      false
    end
    
    # Forward an inbound contact reply to the CRM user who originally sent the SMS
    # Appends a tokenized reply link so the user can respond without logging in
    def forward_sms_to_sender(to_cell:, from_number:, body:, communicable:, reply_token: nil)
      entity_label = communicable ? "#{communicable.class.name} ##{communicable.id}" : 'Unknown contact'
      base_body    = "DMS Reply from #{from_number} (#{entity_label}): #{body}"

      if reply_token.present?
        app_base     = ENV.fetch('FRONTEND_URL', 'https://staging-dms.renterinsight.com')
        reply_url    = "#{app_base}/reply/#{reply_token}"
        forward_body = "#{base_body}\nReply here: #{reply_url}"
      else
        forward_body = base_body
      end

      # Send the forward via master account through the Messaging Service
      TwilioSmsService.send_via_master(
        to:   to_cell,
        body: forward_body.truncate(320)
      )

      Rails.logger.info "[TwilioWebhook] Forwarded reply with token to sender cell #{to_cell}"
    rescue => e
      Rails.logger.error "[TwilioWebhook] Failed to forward SMS to #{to_cell}: #{e.message}"
      # Never re-raise — forward failure must not break inbound logging
    end

    def twilio_params
      {
        message_sid: params['MessageSid'],
        from: params['From'],
        to: params['To'],
        status: params['MessageStatus'],
        error_code: params['ErrorCode'],
        error_message: params['ErrorMessage'],
        price: params['Price'],
        price_unit: params['PriceUnit']
      }.compact
    end
  end
end
