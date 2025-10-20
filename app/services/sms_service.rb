# frozen_string_literal: true

# SmsService - Unified SMS sending service
# Uses provider pattern with CommunicationSettingsService for configuration
# Supports company-specific and platform-level settings
class SmsService
  class DeliveryError < StandardError; end

  attr_reader :company, :provider

  # Initialize SMS service
  # @param company [Company, nil] Company for company-specific settings, nil for platform settings
  # @param provider [String] SMS provider name (default: 'twilio')
  def initialize(company: nil, provider: nil)
    @company = company
    @provider_name = provider || ENV['SMS_PROVIDER'] || 'twilio'
    @provider = initialize_provider
  end

  # Send an SMS message
  # @param to [String] Recipient phone number
  # @param body [String] Message body
  # @param from [String, nil] Sender phone number (optional, uses provider default if nil)
  # @param metadata [Hash] Additional metadata for tracking
  # @return [Boolean] true if sent successfully
  def send_message(to:, body:, from: nil, metadata: {})
    raise DeliveryError, "SMS provider not configured" unless @provider&.configured?

    result = @provider.send_message(
      to: to,
      from: from,
      body: body,
      metadata: metadata.merge(company_id: @company&.id)
    )

    if result[:success]
      Rails.logger.info("📱 SMS sent successfully via #{@provider_name}: #{result[:message_id]}")
      true
    else
      Rails.logger.error("📱 SMS failed: #{result[:error]}")
      raise DeliveryError, result[:error]
    end
  rescue => e
    Rails.logger.error("📱 SMS error: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
    raise DeliveryError, "Failed to send SMS: #{e.message}"
  end

  # Check if SMS service is configured
  # @return [Boolean]
  def configured?
    @provider&.configured? || false
  end

  # Get SMS configuration details (for debugging)
  # @return [Hash]
  def configuration_info
    if @provider&.configured?
      config = @provider.instance_variable_get(:@config)
      {
        provider: @provider_name,
        company_id: @company&.id,
        configured: true,
        account_sid: config[:account_sid]&.slice(0, 10) + "..." if config[:account_sid],
        from_number: config[:phone_number]
      }
    else
      {
        provider: @provider_name,
        company_id: @company&.id,
        configured: false,
        error: "Provider not configured"
      }
    end
  end

  private

  def initialize_provider
    case @provider_name
    when 'twilio'
      Providers::Sms::TwilioProvider.new(company: @company)
    else
      Rails.logger.warn("Unknown SMS provider: #{@provider_name}, defaulting to Twilio")
      Providers::Sms::TwilioProvider.new(company: @company)
    end
  end
end
