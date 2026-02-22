# frozen_string_literal: true

# Handles tokenized SMS reply links sent to CRM users.
#
# Flow:
#   1. Contact replies to company SMS number
#   2. Inbound webhook creates Communication record, generates SmsReplyToken, forwards
#      a link to the CRM user's cell: "Reply here: https://app.../sms-reply/:token"
#   3. User taps link → GET /r/:token (show) → redirect to frontend with context
#   4. Frontend POSTs reply body → POST /r/:token/reply → sends SMS to contact
#
class SmsRepliesController < ActionController::API
  # GET /r/:token
  # Returns token metadata so the frontend can render a reply UI.
  def show
    token_record = SmsReplyToken.valid.find_by(token: params[:token])

    unless token_record
      return render json: { error: 'Reply link has expired or is invalid' }, status: :gone
    end

    original = Communication.find_by(id: token_record.communication_id)
    company  = token_record.company

    # Build the full SMS thread for this communicable entity
    messages = []
    if original&.communicable
      thread = Communication.where(
        channel: 'sms',
        communicable_type: original.communicable_type,
        communicable_id: original.communicable_id
      ).order(:created_at)

      messages = thread.map do |comm|
        {
          direction: comm.direction,
          body: comm.body,
          sent_at: (comm.sent_at || comm.created_at).iso8601,
          sender_name: comm.direction == 'outbound' ? 'You' : nil
        }
      end
    end

    # Resolve contact name from the communicable
    entity = original&.communicable
    contact_name = if entity.respond_to?(:first_name)
                     [entity.first_name, entity.last_name].compact.join(' ')
                   elsif entity.respond_to?(:name)
                     entity.name
                   else
                     nil
                   end

    render json: {
      contact_name:  contact_name || 'Customer',
      contact_phone: token_record.contact_phone,
      messages:      messages,
      expires_at:    token_record.expires_at.iso8601
    }
  end

  # POST /r/:token/reply
  # Sends the user's reply SMS to the contact.
  def reply
    token_record = SmsReplyToken.valid.find_by(token: params[:token])

    unless token_record
      return render json: { error: 'Reply link has expired or is invalid' }, status: :gone
    end

    body = params[:body].to_s.strip

    if body.blank?
      return render json: { error: 'Message body cannot be blank' }, status: :unprocessable_entity
    end

    company = token_record.company

    # Get SMS config for the company so we use the right dedicated number
    sms_cfg = CommunicationSettingsService.for_company(company).sms_config

    result = TwilioSmsService.send(
      to:                    token_record.contact_phone,
      body:                  body,
      from_number:           sms_cfg[:from_number],
      account_sid:           sms_cfg[:twilio_account_sid],
      auth_token:            sms_cfg[:twilio_auth_token],
      messaging_service_sid: sms_cfg[:twilio_messaging_service_sid]
    )

    unless result[:success]
      Rails.logger.error "[SmsRepliesController] Send failed: #{result[:error]}"
      return render json: { error: result[:error] }, status: :unprocessable_entity
    end

    # Log the reply in the communication thread
    original     = Communication.find_by(id: token_record.communication_id)
    communicable = original&.communicable

    Communication.create!(
      company_id:   company&.id,
      communicable: communicable,
      channel:      'sms',
      direction:    'outbound',
      body:         body,
      to_address:   token_record.contact_phone,
      from_address: sms_cfg[:from_number],
      status:       'sent',
      sent_at:      Time.current,
      metadata: {
        'message_sid'          => result[:message_sid],
        'sender_user_id'       => token_record.sender_user_id,
        'reply_token'          => token_record.token,
        'matched_outbound_id'  => token_record.communication_id,
        'source'               => 'magic_link_reply'
      }.compact
    )

    token_record.mark_used!

    Rails.logger.info "[SmsRepliesController] Reply sent to #{token_record.contact_phone}, SID: #{result[:message_sid]}"

    render json: {
      success:    true,
      messageSid: result[:message_sid]
    }
  rescue => e
    Rails.logger.error "[SmsRepliesController] Error: #{e.message}"
    render json: { error: e.message }, status: :internal_server_error
  end
end
