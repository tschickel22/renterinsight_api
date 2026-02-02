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
    body: nil,
    category: 'transactional',
    provider: nil,
    portal_visible: false,
    metadata: {},
    template: nil,
    template_context: {},
    attachments: [],
    scheduled_for: nil,
    send_async: false,
    skip_preference_check: false,
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
      template: template,
      template_context: template_context,
      attachments: attachments,
      scheduled_for: scheduled_for,
      send_async: send_async,
      skip_preference_check: skip_preference_check,
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
    body: nil,
    category: 'transactional',
    provider: nil,
    portal_visible: false,
    metadata: {},
    template: nil,
    template_context: {},
    attachments: [],
    scheduled_for: nil,
    send_async: false,
    skip_preference_check: false,
    **options
  )
    # Extract sending user from options (for user-level email settings)
    @sending_user = options[:user] || options[:sent_by]
    
    # Check communication preferences (opt-in/out)
    # For quotes, we check preferences on the contact/account, not the quote itself
    unless skip_preference_check
      recipient_for_check = determine_recipient_for_preference_check(communicable)
      
      if recipient_for_check && !can_send_to_recipient?(
        recipient: recipient_for_check,
        channel: channel,
        category: category
      )
        raise OptOutError, "Recipient has opted out of #{channel} communications"
      end
    end
    
    # Render template if provided
    if template
      template_obj = template.is_a?(CommunicationTemplate) ? template : CommunicationTemplate.find(template)
      
      # Build context from communicable
      context = TemplateRenderingService.build_context_from_record(communicable)
      context.merge!(template_context) if template_context.present?
      
      # Render template
      rendered = template_obj.render(context)
      subject ||= rendered[:subject]
      body ||= rendered[:body]
    end
    
    # Validate required fields
    raise Error, "Body is required" if body.blank?
    raise Error, "Subject is required for email" if channel == 'email' && subject.blank?
    
    # Set default provider if not specified
    # User email connection takes highest priority in waterfall
    provider ||= default_provider_for(channel, communicable, user: @sending_user)
    
    # Get default from address if not provided
    # User email connection takes highest priority in waterfall
    from ||= default_from_address(channel, communicable, user: @sending_user)
    
    # Log metadata before saving
    Rails.logger.info "[CommunicationService] Creating communication with metadata: #{metadata.merge(category: category).inspect}"
    
    # Create communication record (reply_to will be set after creation for tracking)
    @communication = Communication.create!(
      communicable: communicable,
      direction: direction,
      channel: channel,
      provider: provider,
      status: 'pending',
      subject: subject,
      body: body,
      from_address: from,
      to_address: to,
      cc_addresses: options[:cc],
      bcc_addresses: options[:bcc],
      reply_to: options[:reply_to],
      portal_visible: portal_visible,
      metadata: metadata.merge(category: category)
    )
    
    # Auto-generate reply-to address for tracking (if not already provided)
    if channel == 'email' && direction == 'outbound' && @communication.reply_to.blank?
      # Get the user who is sending (if available from options or context)
      sending_user = options[:user] || options[:sent_by]
      
      generated_reply_to = ReplyToAddressService.generate_for(@communication, user: sending_user)
      @communication.update_column(:reply_to, generated_reply_to)
      
      Rails.logger.info "[CommunicationService] Auto-generated reply_to: #{generated_reply_to} for communication #{@communication.id}"
    end
    
    # Log metadata after saving
    Rails.logger.info "[CommunicationService] Communication #{@communication.id} created with metadata: #{@communication.metadata.inspect}"
    
    # Attach files if provided
    if attachments.present?
      result = AttachmentService.attach_multiple_to_communication(@communication, attachments)
      unless result[:success]
        Rails.logger.error("Failed to attach files: #{result[:failed].inspect}")
      end
    end
    
    # Handle scheduling
    if scheduled_for.present?
      # Schedule for future delivery
      result = SchedulingService.schedule(@communication, send_at: scheduled_for)
      if result[:success]
        Rails.logger.info("Scheduled communication #{@communication.id} for #{scheduled_for}")
      else
        Rails.logger.error("Failed to schedule communication: #{result[:error]}")
      end
      return { success: true, communication: @communication, scheduled: true }
    end
    
    # Handle async sending
    if send_async
      SendCommunicationJob.perform_later(@communication.id)
      return { success: true, communication: @communication, async: true }
    end
    
    # Send via appropriate provider (synchronous)
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
      
      { success: true, communication: @communication, provider: provider, external_id: result[:external_id] }
    rescue => e
      @communication.mark_as_failed!(e.message)
      { success: false, communication: @communication, error: e.message }
    end
  end
  
  # Send an existing communication (used by background jobs)
  # Renamed to avoid conflict with the main send_communication method above
  def self.send_existing_communication(communication, options = {})
    return { success: false, error: "Communication already sent" } if communication.sent? || communication.delivered?
    
    begin
      result = new(communication).send_via_provider(
        provider: communication.provider,
        channel: communication.channel,
        communication: communication,
        options: options
      )
      
      # Update communication with external ID
      communication.update!(external_id: result[:external_id]) if result[:external_id]
      
      # Track send event
      communication.track_event('sent', result)
      
      { success: true, communication: communication, provider: communication.provider }
    rescue => e
      communication.mark_as_failed!(e.message)
      { success: false, communication: communication, error: e.message }
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
  
  # Determine the correct recipient to check preferences for
  # For quotes, this is the contact or account, not the quote itself
  def determine_recipient_for_preference_check(communicable)
    case communicable.class.name
    when 'Quote'
      # Check contact first, then account
      communicable.contact || communicable.account
    when 'Account', 'Contact'
      # These are already the right recipient
      communicable
    else
      # For other types, just use the communicable
      communicable
    end
  end
  
  private
  
  def send_via_provider(provider:, channel:, communication:, options:)
    # Extract company and location from communicable for settings lookup
    company = extract_company_from_communicable(communication.communicable)
    location = extract_location_from_communicable(communication.communicable)
    
    # Get sending user (for user-level email settings)
    sending_user = @sending_user || options[:user] || options[:sent_by]
    
    provider_class = get_provider_class(provider, channel)
    provider_instance = provider_class.new(company: company, location: location, user: sending_user)
    
    # Prepare attachments if present
    attachments_data = []
    if communication.attachments.attached?
      communication.attachments.each do |attachment|
        attachments_data << {
          filename: attachment.filename.to_s,
          content: attachment.download,
          content_type: attachment.content_type
        }
      end
    end
    
    provider_instance.send_message(
      to: communication.to_address,
      from: communication.from_address,
      subject: communication.subject,
      body: communication.body,
      cc: communication.cc_addresses,
      bcc: communication.bcc_addresses,
      reply_to: communication.reply_to,
      metadata: communication.metadata,
      attachments: attachments_data,
      **options
    )
  end
  
  def extract_company_from_communicable(communicable)
    return nil unless communicable
    
    case communicable.class.name
    when 'Quote'
      communicable.account&.company || communicable.contact&.company
    when 'Account', 'Contact'
      communicable.company
    when 'User'
      communicable.company if communicable.respond_to?(:company)
    when 'Invitation'
      communicable.company
    else
      # Try to get company if the object responds to it
      communicable.company if communicable.respond_to?(:company)
    end
  end
  
  def extract_location_from_communicable(communicable)
    return nil unless communicable
    
    # Try to get location directly
    return communicable.location if communicable.respond_to?(:location)
    
    # For nested entities (quotes, etc), try through associations
    case communicable.class.name
    when 'Quote'
      communicable.contact&.location || communicable.account&.location
    when 'Account', 'Contact', 'Lead'
      communicable.location
    else
      # Try generic location accessor
      communicable.location if communicable.respond_to?(:location)
    end
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
  
  def default_provider_for(channel, communicable = nil, user: nil)
    # Waterfall priority: User → Location → Company → Platform
    # Check if user has their own email connection configured
    if channel == 'email' && user&.has_email_connection?
      Rails.logger.info "[CommunicationService] Using user #{user.id} email connection for provider"
      return :smtp  # User connections always use SMTP
    end
    
    # Get provider from CommunicationSettingsService (respects Location → Company → Platform waterfall)
    company = extract_company_from_communicable(communicable)
    location = extract_location_from_communicable(communicable)
    
    settings_service = company ? 
      CommunicationSettingsService.for_company(company, location: location) : 
      CommunicationSettingsService.platform
    
    case channel
    when 'email'
      config = settings_service.email_config
      provider_from_settings = config[:provider]&.to_sym
      
      # Use provider from settings (waterfall), fall back to ENV, then :smtp
      provider_from_settings || ENV['DEFAULT_EMAIL_PROVIDER']&.to_sym || :smtp
    when 'sms'
      config = settings_service.sms_config
      provider_from_settings = config[:provider]&.to_sym
      
      provider_from_settings || :twilio
    else
      nil
    end
  end
  
  def default_from_address(channel, communicable = nil, user: nil)
    # Waterfall priority: User → Location → Company → Platform
    # Check if user has their own email connection configured
    if channel == 'email' && user&.has_email_connection?
      from_email = user.sending_email_address
      Rails.logger.info "[CommunicationService] Using user #{user.id} email address: #{from_email}"
      return from_email
    end
    
    # Get from CommunicationSettingsService based on company and location context for both email and SMS
    company = extract_company_from_communicable(communicable)
    location = extract_location_from_communicable(communicable)
    settings_service = company ? 
      CommunicationSettingsService.for_company(company, location: location) : 
      CommunicationSettingsService.platform
    
    case channel
    when 'email'
      email_config = settings_service.email_config
      email_config[:from_email]
    when 'sms'
      sms_config = settings_service.sms_config
      sms_config[:from_number]
    else
      nil
    end
  end
  
  def self.generate_quote_email_body(quote)
    # Placeholder - would use actual template
    "Please find your quote attached."
  end
end
