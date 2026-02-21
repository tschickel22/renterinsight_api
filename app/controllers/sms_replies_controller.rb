# frozen_string_literal: true

# Public controller — no authentication required
# Handles tokenized reply links sent to CRM users via SMS forward
class SmsRepliesController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  skip_before_action :authenticate_request!, raise: false
  skip_before_action :authenticate, raise: false
  skip_before_action :set_current_attributes, raise: false

  before_action :load_and_validate_token

  # GET /r/:token
  # Returns conversation context for the reply UI
  def show
    original = Communication.find_by(id: @reply_token.communication_id)
    communicable = original&.communicable

    # Recent thread: last 10 messages between this contact phone and this company
    thread = Communication.where(
      company_id: @reply_token.company_id,
      channel:    'sms'
    ).where(
      'from_address = ? OR to_address = ?',
      @reply_token.contact_phone,
      @reply_token.contact_phone
    ).order(created_at: :desc).limit(10).map do |msg|
      {
        id:         msg.id,
        direction:  msg.direction,
        body:       msg.body,
        sent_at:    msg.sent_at,
        from:       msg.from_address,
        to:         msg.to_address
      }
    end

    render json: {
      valid:         true,
      contact_phone: @reply_token.contact_phone,
      sender_name:   @reply_token.sender_user&.full_name,
      communicable:  communicable ? { type: communicable.class.name, id: communicable.id } : nil,
      thread:        thread.reverse,
      expires_at:    @reply_token.expires_at
    }
  end

  # POST /r/:token/reply
  # Sends the reply via Twilio and logs it
  def reply
    body = params[:body].to_s.strip

    if body.blank?
      render json: { error: 'Message body cannot be blank' }, status: :unprocessable_entity
      return
    end

    sender_user = @reply_token.sender_user
    company     = @reply_token.company
    twilio_acct = company.twilio_account

    unless twilio_acct&.active?
      render json: { error: 'SMS is not active for this account' }, status: :unprocessable_entity
      return
    end

    original = Communication.find_by(id: @reply_token.communication_id)

    begin
      # Send via the company's dedicated Twilio number
      client = Twilio::REST::Client.new(twilio_acct.sub_account_sid, twilio_acct.auth_token)
      message = client.messages.create(
        from: twilio_acct.phone_number,
        to:   @reply_token.contact_phone,
        body: body
      )

      # Log the outbound reply as a Communication
      comm = Communication.create!(
        company_id:   company.id,
        communicable: original&.communicable,
        channel:      'sms',
        direction:    'outbound',
        from_address: twilio_acct.phone_number,
        to_address:   @reply_token.contact_phone,
        body:         body,
        status:       'sent',
        sent_at:      Time.current,
        metadata: {
          message_sid:     message.sid,
          sender_user_id:  sender_user.id,
          source:          'manual',
          reply_token:     params[:token],
          via:             'tokenized_reply'
        }
      )

      # Log usage
      SmsUsageLog.log!(
        company:          company,
        direction:        'outbound',
        source:           'manual',
        communication_id: comm.id
      )

      # Mark token as used (non-exclusive — token remains valid until expiry for conversation continuity)
      @reply_token.mark_used!

      render json: { success: true, message_sid: message.sid }

    rescue Twilio::REST::RestError => e
      Rails.logger.error "[SmsReply] Twilio error sending reply: #{e.message}"
      render json: { error: "Failed to send: #{e.message}" }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error "[SmsReply] Unexpected error: #{e.message}"
      render json: { error: 'An unexpected error occurred' }, status: :internal_server_error
    end
  end

  private

  def load_and_validate_token
    @reply_token = SmsReplyToken.valid.find_by(token: params[:token])

    unless @reply_token
      render json: {
        valid:   false,
        error:   'This reply link has expired or is invalid. Please log in to DMS to continue the conversation.'
      }, status: :gone
    end
  end
end
