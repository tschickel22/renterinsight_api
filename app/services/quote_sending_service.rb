# Service to handle sending quotes via email, SMS, or both
# 
# Usage:
#   QuoteSendingService.new(quote).send(
#     delivery_methods: ['email', 'sms'],
#     to_email: 'customer@example.com',
#     to_phone: '+1234567890',
#     custom_message: 'Here is your quote'
#   )

class QuoteSendingService
  class Error < StandardError; end
  
  attr_reader :quote, :results
  
  def initialize(quote)
    @quote = quote
    @results = { sent: [], failed: [], errors: [] }
  end
  
  # Main send method
  # @param delivery_methods [Array<String>] - array of 'email' and/or 'sms'
  # @param to_email [String] - recipient email (optional, defaults to quote's primary_email)
  # @param to_phone [String] - recipient phone (optional, defaults to quote's primary_phone)
  # @param custom_message [String] - custom message to include
  # @param template_id [Integer] - optional template ID to use
  # @param from_email [String] - optional from email
  # @param from_phone [String] - optional from phone
  # @param cc [String] - CC recipients for email
  # @param bcc [String] - BCC recipients for email
  # @param send_async [Boolean] - send asynchronously via background job
  # @return [Hash] - { sent: [], failed: [], errors: [] }
  def send(
    delivery_methods: ['email'],
    to_email: nil,
    to_phone: nil,
    custom_message: nil,
    template_id: nil,
    from_email: nil,
    from_phone: nil,
    cc: nil,
    bcc: nil,
    send_async: false,
    **options
  )
    # Validate delivery methods
    valid_methods = ['email', 'sms']
    invalid = delivery_methods - valid_methods
    raise ArgumentError, "Invalid delivery methods: #{invalid.join(', ')}" if invalid.any?
    
    # Send via each requested method
    delivery_methods.each do |method|
      case method
      when 'email'
        send_email(
          to: to_email,
          custom_message: custom_message,
          template_id: template_id,
          from: from_email,
          cc: cc,
          bcc: bcc,
          send_async: send_async,
          **options
        )
      when 'sms'
        send_sms(
          to: to_phone,
          custom_message: custom_message,
          template_id: template_id,
          from: from_phone,
          send_async: send_async,
          **options
        )
      end
    end
    
    @results
  end
  
  private
  
  def send_email(to:, custom_message:, template_id:, from:, cc:, bcc:, send_async:, **options)
    # Determine recipient
    recipient = to || quote.primary_email
    
    unless recipient.present?
      @results[:errors] << "No email address available for quote"
      @results[:failed] << { channel: 'email', reason: 'No email address' }
      return
    end
    
    # Build email content
    subject = build_email_subject
    body = build_email_body(custom_message: custom_message, template_id: template_id)
    
    # Send via CommunicationService
    begin
      result = CommunicationService.send_email(
        communicable: quote,
        to: recipient,
        subject: subject,
        body: body,
        from: from,
        cc: cc,
        bcc: bcc,
        category: 'quotes',
        metadata: { 
          quote_id: quote.id,
          quote_number: quote.quote_number 
        },
        portal_visible: true,
        send_async: send_async,
        **options
      )
      
      if result[:success]
        @results[:sent] << {
          channel: 'email',
          to: recipient,
          communication: result[:communication]
        }
      else
        @results[:errors] << result[:error]
        @results[:failed] << { 
          channel: 'email', 
          to: recipient,
          reason: result[:error] 
        }
      end
    rescue CommunicationService::OptOutError => e
      @results[:errors] << "Recipient has opted out of email communications"
      @results[:failed] << { 
        channel: 'email', 
        to: recipient,
        reason: 'Opted out' 
      }
    rescue => e
      Rails.logger.error "Error sending quote email: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      @results[:errors] << e.message
      @results[:failed] << { 
        channel: 'email', 
        to: recipient,
        reason: e.message 
      }
    end
  end
  
  def send_sms(to:, custom_message:, template_id:, from:, send_async:, **options)
    # Determine recipient
    recipient = to || quote.primary_phone
    
    unless recipient.present?
      @results[:errors] << "No phone number available for quote"
      @results[:failed] << { channel: 'sms', reason: 'No phone number' }
      return
    end
    
    # Build SMS content
    body = build_sms_body(custom_message: custom_message, template_id: template_id)
    
    # Send via CommunicationService
    begin
      result = CommunicationService.send_sms(
        communicable: quote,
        to: recipient,
        body: body,
        from: from,
        category: 'quotes',
        metadata: { 
          quote_id: quote.id,
          quote_number: quote.quote_number 
        },
        portal_visible: true,
        send_async: send_async,
        **options
      )
      
      if result[:success]
        @results[:sent] << {
          channel: 'sms',
          to: recipient,
          communication: result[:communication]
        }
      else
        @results[:errors] << result[:error]
        @results[:failed] << { 
          channel: 'sms', 
          to: recipient,
          reason: result[:error] 
        }
      end
    rescue CommunicationService::OptOutError => e
      @results[:errors] << "Recipient has opted out of SMS communications"
      @results[:failed] << { 
        channel: 'sms', 
        to: recipient,
        reason: 'Opted out' 
      }
    rescue => e
      Rails.logger.error "Error sending quote SMS: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      @results[:errors] << e.message
      @results[:failed] << { 
        channel: 'sms', 
        to: recipient,
        reason: e.message 
      }
    end
  end
  
  def build_email_subject
    "Quote #{quote.quote_number} from #{company_name}"
  end
  
  def build_email_body(custom_message:, template_id:)
    # If template provided, use it
    if template_id.present?
      template = CommunicationTemplate.find_by(id: template_id)
      if template
        context = build_template_context
        rendered = template.render(context)
        return rendered[:body]
      end
    end
    
    # Otherwise build default email body
    parts = []
    
    # Custom message if provided
    parts << custom_message if custom_message.present?
    
    # Quote details
    parts << <<~TEXT
      Hello,
      
      Please find your quote details below:
      
      Quote Number: #{quote.quote_number}
      Total Amount: $#{format_currency(quote.total)}
      Valid Until: #{quote.valid_until&.strftime('%B %d, %Y') || 'N/A'}
    TEXT
    
    # Line items
    if quote.items.present?
      parts << "\nQuote Items:"
      quote.items.each_with_index do |item, index|
        quantity = item['quantity'] || item[:quantity]
        description = item['description'] || item[:description]
        unit_price = item['unitPrice'] || item['unit_price'] || item[:unitPrice] || item[:unit_price]
        total = quantity.to_f * unit_price.to_f
        
        parts << "#{index + 1}. #{description} - Qty: #{quantity} @ $#{format_currency(unit_price)} = $#{format_currency(total)}"
      end
    end
    
    # Notes if present
    parts << "\nNotes:\n#{quote.notes}" if quote.notes.present?
    
    # Portal link if available
    if ENV['BUYER_PORTAL_URL'].present?
      portal_url = "#{ENV['BUYER_PORTAL_URL']}/quotes/#{quote.id}"
      parts << "\nView and accept this quote online: #{portal_url}"
    end
    
    parts << "\nThank you for your business!"
    
    parts.join("\n\n")
  end
  
  def build_sms_body(custom_message:, template_id:)
    # If template provided, use it
    if template_id.present?
      template = CommunicationTemplate.find_by(id: template_id)
      if template
        context = build_template_context
        rendered = template.render(context)
        return rendered[:body]
      end
    end
    
    # Otherwise build default SMS body
    parts = []
    
    # Custom message if provided
    parts << custom_message if custom_message.present?
    
    # Quote summary
    parts << "Quote #{quote.quote_number}: $#{format_currency(quote.total)}"
    
    # Portal link if available
    if ENV['BUYER_PORTAL_URL'].present?
      portal_url = "#{ENV['BUYER_PORTAL_URL']}/quotes/#{quote.id}"
      parts << "View: #{portal_url}"
    end
    
    parts.join("\n")
  end
  
  def build_template_context
    {
      quote: quote,
      quote_number: quote.quote_number,
      total: quote.total,
      subtotal: quote.subtotal,
      tax: quote.tax,
      valid_until: quote.valid_until,
      items: quote.items,
      notes: quote.notes,
      account: quote.account,
      contact: quote.contact,
      company_name: company_name
    }
  end
  
  def format_currency(amount)
    sprintf('%.2f', amount.to_f)
  end
  
  def company_name
    ENV['COMPANY_NAME'] || 'Platform DMS'
  end
end
