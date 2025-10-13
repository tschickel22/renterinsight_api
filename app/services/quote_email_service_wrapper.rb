# Wrapper for existing QuoteEmailService
# Maintains 100% backward compatibility while using unified communication system
# This allows gradual migration without breaking existing code

class QuoteEmailServiceWrapper
  attr_reader :quote, :original_service
  
  def initialize(quote)
    @quote = quote
    # @original_service = QuoteEmailService.new(quote) # Uncomment when original exists
  end
  
  # Main send method - wraps in unified system
  def send_email(to:, subject: nil, body: nil, **options)
    # Use unified communication system
    communication = CommunicationService.send_quote_email(
      quote: quote,
      to: to,
      subject: subject || default_subject,
      body: body || default_body,
      from: options[:from] || default_from_address,
      category: 'quotes',
      provider: options[:provider],
      cc: options[:cc],
      bcc: options[:bcc],
      reply_to: options[:reply_to],
      metadata: {
        quote_id: quote.id,
        legacy_wrapper: true
      }.merge(options[:metadata] || {})
    )
    
    # Call original service for any legacy processing if needed
    # @original_service.send_email(to: to, subject: subject, body: body, **options)
    
    communication
  end
  
  # Alias for backward compatibility
  def deliver(to:, **options)
    send_email(to: to, **options)
  end
  
  # Resend quote email
  def resend(to:, **options)
    send_email(to: to, **options.merge(metadata: { resend: true }))
  end
  
  # Send to multiple recipients
  def send_to_multiple(recipients, **options)
    recipients.map do |recipient|
      send_email(to: recipient, **options)
    end
  end
  
  # Check if recipient can receive emails
  def can_send_to?(recipient)
    recipient_model = find_recipient_model(recipient)
    return true unless recipient_model
    
    CommunicationPreferenceService.can_send_to?(
      recipient: recipient_model,
      channel: 'email',
      category: 'quotes'
    )
  end
  
  # Get send history
  def send_history
    Communication.where(
      communicable: quote,
      channel: 'email',
      direction: 'outbound'
    ).or(
      Communication.where(
        "metadata->>'quote_id' = ?",
        quote.id.to_s
      )
    ).order(created_at: :desc)
  end
  
  # Get last sent communication
  def last_sent
    send_history.first
  end
  
  # Check if quote email was sent
  def sent?
    send_history.exists?
  end
  
  # Check if quote email was delivered
  def delivered?
    send_history.delivered.exists?
  end
  
  # Check if quote email was opened
  def opened?
    send_history.any? { |comm| comm.opened? }
  end
  
  private
  
  def default_subject
    "Quote ##{quote.id} from #{company_name}"
  end
  
  def default_body
    # Generate from template or use existing logic
    <<~BODY
      Hello,

      Please find your quote attached.

      Quote Details:
      Quote #: #{quote.id}
      Date: #{quote.created_at.strftime('%m/%d/%Y')}
      
      #{quote_details}

      If you have any questions, please don't hesitate to contact us.

      Best regards,
      #{company_name}
    BODY
  end
  
  def quote_details
    # Format quote line items or details
    # This would use your existing quote formatting logic
    ""
  end
  
  def default_from_address
    ENV['QUOTE_FROM_EMAIL'] || ENV['DEFAULT_FROM_EMAIL'] || 'quotes@platformdms.com'
  end
  
  def company_name
    ENV['COMPANY_NAME'] || 'Platform DMS'
  end
  
  def find_recipient_model(email)
    # Try to find Lead or Account by email
    Lead.find_by(email: email) || 
    Account.joins(:contacts).find_by(contacts: { email: email })
  end
end

# ============================================================================
# Original QuoteEmailService - update to use wrapper
# ============================================================================
# If you have an existing QuoteEmailService, update it like this:

# class QuoteEmailService
#   def initialize(quote)
#     @wrapper = QuoteEmailServiceWrapper.new(quote)
#   end
#   
#   def send_email(to:, **options)
#     @wrapper.send_email(to: to, **options)
#   end
#   
#   # Delegate other methods
#   delegate :deliver, :resend, :send_to_multiple, :can_send_to?, 
#            :send_history, :last_sent, :sent?, :delivered?, :opened?,
#            to: :@wrapper
# end

# ============================================================================
# Usage Examples (100% backward compatible)
# ============================================================================

# Original usage still works:
# service = QuoteEmailService.new(quote)
# service.send_email(to: 'customer@example.com')

# New usage through wrapper:
# wrapper = QuoteEmailServiceWrapper.new(quote)
# wrapper.send_email(to: 'customer@example.com')

# Direct unified system usage:
# CommunicationService.send_quote_email(
#   quote: quote,
#   to: 'customer@example.com'
# )
