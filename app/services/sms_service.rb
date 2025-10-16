# frozen_string_literal: true

class SmsService
  class DeliveryError < StandardError; end

  def initialize(settings = {})
    @settings = settings || {}
    @provider = @settings['provider'] || ENV['SMS_PROVIDER'] || 'twilio'
  end

  def send_message(to:, body:)
    case @provider
    when 'twilio'
      send_via_twilio(to, body)
    else
      # Fallback or log
      Rails.logger.info("SMS would be sent to #{to}: #{body}")
      true
    end
  end

  private

  def send_via_twilio(to, body)
    # Get credentials from settings or ENV
    account_sid = @settings['twilioAccountSid'] || ENV['TWILIO_ACCOUNT_SID']
    auth_token = decrypt_if_needed(@settings['twilioAuthToken']) || ENV['TWILIO_AUTH_TOKEN']
    from_number = @settings['fromNumber'] || ENV['TWILIO_PHONE_NUMBER']

    # Log what we're using (without exposing sensitive data)
    Rails.logger.info("📱 SMS Configuration:")
    Rails.logger.info("   Provider: twilio")
    Rails.logger.info("   Account SID: #{account_sid&.slice(0, 10)}...")
    Rails.logger.info("   Auth Token: #{auth_token ? '[SET]' : '[NOT SET]'}")
    Rails.logger.info("   From Number: #{from_number}")
    Rails.logger.info("   To Number: #{to}")

    # Check if Twilio is configured
    unless account_sid.present? && auth_token.present? && from_number.present?
      Rails.logger.warn("Twilio not configured. SMS not sent to #{to}")
      Rails.logger.warn("Missing: " + [
        account_sid.blank? ? 'Account SID' : nil,
        auth_token.blank? ? 'Auth Token' : nil,
        from_number.blank? ? 'Phone Number' : nil
      ].compact.join(', '))
      return false
    end

    require 'twilio-ruby'

    client = Twilio::REST::Client.new(account_sid, auth_token)

    message = client.messages.create(
      from: from_number,
      to: to,
      body: body
    )

    Rails.logger.info("SMS sent successfully: #{message.sid}")
    true
  rescue Twilio::REST::RestError => e
    Rails.logger.error("Twilio error: #{e.message}")
    raise DeliveryError, "Failed to send SMS: #{e.message}"
  rescue LoadError => e
    Rails.logger.error("Twilio gem not installed. Add 'twilio-ruby' to Gemfile")
    raise DeliveryError, "SMS service not configured"
  rescue StandardError => e
    Rails.logger.error("SMS send error: #{e.message}")
    Rails.logger.error(e.backtrace.first(3).join("\n"))
    raise DeliveryError, "Failed to send SMS: #{e.message}"
  end

  def decrypt_if_needed(value)
    return nil unless value
    return value unless value.is_a?(String) && value.start_with?('encrypted:')

    encrypted_data = value.sub('encrypted:', '')
    secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
    key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
    crypt = ActiveSupport::MessageEncryptor.new(key)

    crypt.decrypt_and_verify(encrypted_data)
  rescue StandardError => e
    Rails.logger.error("Failed to decrypt SMS token: #{e.message}")
    nil
  end
end
