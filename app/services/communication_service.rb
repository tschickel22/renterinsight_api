# Main orchestrator for all communications
# Wraps existing services like QuoteEmailService while providing unified interface
#
# Usage:
#   CommunicationService.send_email(
#     communicable: quote,
#     to: "customer@example.com",
#     subject: "Your Quote",
#     body: "...",
#     category: 'quotes',
#     provider: :aws_ses
#   )

class CommunicationService
  class Error < StandardError; end
  class OptOutError < Error; end
  class ProviderError < Error; end
  
  attr_reader :communication
  
  def initialize(communication = nil)
    @communication = communication
  end
  
  # Main entry point for sending communications
  def self.send_communication(
    communicable:,
    channel:,
    direction: 'outbound',
    to:,
    from: nil,
    subject: nil,
    body:,
    category: 'transactional',
    provider: nil,
    portal_visible: false,
    metadata: {},
    **options
  )
    new.send_communication(
      communicable: communicable,
      channel: channel,
      direction: direction,
      to: to,
      from: from,
      subject: subject,
      body: body,
      category: category,
      provider: provider,
      portal_visible: portal_visible,
      metadata: metadata,
      **options
    )
  end
  
  # Convenience methods for specific channels
  def self.send_email(communicable:, to:, subject:, body:, **options)
    send_communication(
      communicable: communicable,
      channel: 'email',
      to: to,
      subject: subject,
      body: body,
      **options
    )
  end
  
  def self.send_sms(communicable:, to:, body:, **options)
    send_communication(
      communicable: communicable,
      channel: 'sms',
      to: to,
      body: body,
      **options
    )
  end
  
  def self.send_portal_message(communicable:, to:, body:, **options)
    send_communication(
      communicable: communicable,
      channel: 'portal_message',
      to: to,
      body: body,
      portal_visible: true,
      **options
    )
  end
  
  def send_communication(
    communicable:,
    channel:,
    direction: 'outbound',
    to:,
    from: nil,
    subject: nil,
    body:,
    category: 'transactional',
    provider: nil,
    portal_visible: false,
    metadata: {},
    **options
  )
    # Check communication preferences (opt-in/out)
    unless can_send_to_recipient?(
      recipient: communicable,
      channel: channel,
      category: category
    )
      raise OptOutError, "Recipient has opted out of #{channel} communications"
    end
    
    # Set default provider if not specified
    provider ||= default_provider_for(channel)
    
    # Create communication record
    @communication = Communication.create!(
      communicable: communicable,
      direction: direction,
      channel: channel,
      provider: provider,
      status: 'pending',
      subject: subject,
      body: body,
      from_address: from || default_from_address(channel),
      to_address: to,
      cc_addresses: options[:cc],
      bcc_addresses: options[:bcc],
      reply_to: options[:reply_to],
      portal_visible: portal_visible,
      metadata: metadata.merge(category: category)
    )
    
    # Send via appropriate provider
    begin
      result = send_via_provider(
        provider: provider,
        channel: channel,
        communication: @communication,
        options: options
      )
      
      # Update communication with external ID
      @communication.update!(external_id: result[:external_id]) if result[:external_id]
      
      # Track send event
      @communication.track_event('sent', result)
      
      @communication
    rescue => e
      @communication.mark_as_failed!(e.message)
      raise ProviderError, "Failed to send #{channel}: #{e.message}"
    end
  end
  
  # Wrapper for existing QuoteEmailService to maintain backward compatibility
  def self.send_quote_email(quote:, to:, **options)
    # Use existing QuoteEmailService but wrap in unified system
    communication = send_email(
      communicable: quote,
      to: to,
      subject: options[:subject] || "Quote ##{quote.id}",
      body: options[:body] || generate_quote_email_body(quote),
      category: 'quotes',
      from: options[:from],
      metadata: { quote_id: quote.id, via: 'quote_email_service' },
      **options
    )
    
    # Call legacy service for any additional processing
    # QuoteEmailService.new(quote).send_email(to: to, **options)
    
    communication
  end
  
  # Check if we can send to recipient based on preferences
  def can_send_to_recipient?(recipient:, channel:, category:)
    CommunicationPreferenceService.can_send_to?(
      recipient: recipient,
      channel: channel,
      category: category
    )
  end
  
  private
  
  def send_via_provider(provider:, channel:, communication:, options:)
    provider_class = get_provider_class(provider, channel)
    provider_instance = provider_class.new
    
    provider_instance.send_message(
      to: communication.to_address,
      from: communication.from_address,
      subject: communication.subject,
      body: communication.body,
      cc: communication.cc_addresses,
      bcc: communication.bcc_addresses,
      reply_to: communication.reply_to,
      metadata: communication.metadata,
      **options
    )
  end
  
  def get_provider_class(provider, channel)
    case channel
    when 'email'
      case provider.to_sym
      when :smtp
        Providers::Email::SmtpProvider
      when :gmail_relay
        Providers::Email::GmailRelayProvider
      when :aws_ses
        Providers::Email::AwsSesProvider
      else
        raise ProviderError, "Unknown email provider: #{provider}"
      end
    when 'sms'
      case provider.to_sym
      when :twilio
        Providers::Sms::TwilioProvider
      else
        raise ProviderError, "Unknown SMS provider: #{provider}"
      end
    else
      raise ProviderError, "Unsupported channel: #{channel}"
    end
  end
  
  def default_provider_for(channel)
    case channel
    when 'email'
      ENV['DEFAULT_EMAIL_PROVIDER']&.to_sym || :smtp
    when 'sms'
      :twilio
    else
      nil
    end
  end
  
  def default_from_address(channel)
    case channel
    when 'email'
      ENV['DEFAULT_FROM_EMAIL'] || 'noreply@platformdms.com'
    when 'sms'
      ENV['TWILIO_PHONE_NUMBER']
    else
      nil
    end
  end
  
  def self.generate_quote_email_body(quote)
    # Placeholder - would use actual template
    "Please find your quote attached."
  end
end
