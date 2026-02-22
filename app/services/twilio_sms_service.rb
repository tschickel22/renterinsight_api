# frozen_string_literal: true

# TwilioSmsService — single shared SMS sending primitive.
#
# All outbound SMS in the system routes through here so that:
#   1. MessagingServiceSid + From are always sent together (A2P compliance)
#   2. Logging is consistent
#   3. There's one place to change Twilio HTTP behavior
#
module TwilioSmsService
  def self.send(to:, body:, from_number:, account_sid:, auth_token:, messaging_service_sid: nil)
    require 'net/http'
    require 'uri'
    require 'json'

    unless account_sid.present? && auth_token.present?
      Rails.logger.error "[TwilioSmsService] Missing credentials (account_sid or auth_token)"
      return { success: false, error: 'Twilio credentials not configured' }
    end

    unless from_number.present? || messaging_service_sid.present?
      Rails.logger.error "[TwilioSmsService] Neither from_number nor messaging_service_sid provided"
      return { success: false, error: 'SMS from number not configured' }
    end

    to_normalized = normalize_phone(to)

    if messaging_service_sid.present? && from_number.present?
      Rails.logger.info "[TwilioSmsService] Sending to #{to_normalized} via MessagingService #{messaging_service_sid} from #{from_number}"
    elsif messaging_service_sid.present?
      Rails.logger.info "[TwilioSmsService] Sending to #{to_normalized} via MessagingService #{messaging_service_sid}"
    else
      Rails.logger.info "[TwilioSmsService] Sending to #{to_normalized} from #{from_number}"
    end

    uri = URI.parse("https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json")
    request = Net::HTTP::Post.new(uri)
    request.basic_auth(account_sid, auth_token)

    form_data = { 'To' => to_normalized, 'Body' => body }
    if messaging_service_sid.present? && from_number.present?
      form_data['MessagingServiceSid'] = messaging_service_sid
      form_data['From'] = from_number
    elsif messaging_service_sid.present?
      form_data['MessagingServiceSid'] = messaging_service_sid
    else
      form_data['From'] = from_number
    end

    request.set_form_data(form_data)

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    result   = JSON.parse(response.body)

    if response.code.to_i == 201
      Rails.logger.info "[TwilioSmsService] Success: #{result['sid']}"
      { success: true, message_sid: result['sid'], status: result['status'] }
    else
      error_msg = result['message'] || 'Twilio API error'
      Rails.logger.error "[TwilioSmsService] Error #{result['code']}: #{error_msg}"
      { success: false, error: error_msg, twilio_code: result['code'] }
    end
  rescue => e
    Rails.logger.error "[TwilioSmsService] Exception: #{e.message}"
    { success: false, error: e.message }
  end

  # Convenience: send using master account credentials from env/platform settings
  def self.send_via_master(to:, body:, from_number: nil, messaging_service_sid: nil)
    sid, token = master_credentials
    msid = messaging_service_sid || master_messaging_service_sid
    from = from_number || ENV['TWILIO_PHONE_NUMBER']

    send(
      to:                    to,
      body:                  body,
      from_number:           from,
      account_sid:           sid,
      auth_token:            token,
      messaging_service_sid: msid
    )
  end

  def self.master_credentials
    sid   = ENV['TWILIO_ACCOUNT_SID'].presence
    token = ENV['TWILIO_AUTH_TOKEN'].presence
    return [sid, token] if sid && token

    begin
      sms = Setting.find_by(scope_type: 'Platform', scope_id: 0, key: 'communications')
              &.then { |s| s.value.is_a?(Hash) ? s.value : JSON.parse(s.value.to_s) }
              &.dig('sms') || {}
      sid   ||= sms['twilioAccountSid'].presence
      raw     = sms['twilioAuthToken'].presence
      if raw.present?
        secret = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
        key    = ActiveSupport::KeyGenerator.new(secret).generate_key('', 32)
        enc    = raw.to_s.sub('encrypted:', '')
        token ||= ActiveSupport::MessageEncryptor.new(key).decrypt_and_verify(enc) rescue raw
      end
    rescue StandardError => e
      Rails.logger.warn "[TwilioSmsService] Could not load master credentials from DB: #{e.message}"
    end

    [sid, token]
  end

  def self.master_messaging_service_sid
    ENV['TWILIO_MESSAGING_SERVICE_SID'].presence ||
      begin
        sms = Setting.find_by(scope_type: 'Platform', scope_id: 0, key: 'communications')
                &.then { |s| s.value.is_a?(Hash) ? s.value : JSON.parse(s.value.to_s) }
                &.dig('sms') || {}
        sms['twilioMessagingServiceSid'].presence
      rescue StandardError
        nil
      end
  end

  def self.normalize_phone(phone)
    digits = phone.to_s.gsub(/\D/, '')
    if digits.length == 10
      "+1#{digits}"
    elsif digits.length == 11 && digits.start_with?('1')
      "+#{digits}"
    else
      "+#{digits}"
    end
  end
  private_class_method :normalize_phone
end
