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
    
    # Send via CommunicationService (no attachments - we include PDF link in body)
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
    
    # Build HTML email body with clickable links
    # Use public quote link (no login required) instead of PDF
    quote_url = quote.public_link
    
    portal_link_html = ''
    if ENV['BUYER_PORTAL_URL'].present?
      portal_url = "#{ENV['BUYER_PORTAL_URL']}/quotes/#{quote.id}"
      portal_link_html = "<p><a href=\"#{portal_url}\" style=\"color: #2563eb; text-decoration: none;\">Accept Online</a></p>"
    end
    
    # Build line items HTML
    items_html = ''
    if quote.items.present?
      items_html = '<h3 style="margin-top: 20px; margin-bottom: 10px; color: #374151;">Quote Items:</h3>'
      items_html += '<ul style="list-style: none; padding: 0;">'
      quote.items.each_with_index do |item, index|
        quantity = item['quantity'] || item[:quantity]
        description = item['description'] || item[:description]
        unit_price = item['unitPrice'] || item['unit_price'] || item[:unitPrice] || item[:unit_price]
        total = quantity.to_f * unit_price.to_f
        
        items_html += "<li style=\"margin-bottom: 8px;\">#{index + 1}. #{description} - Qty: #{quantity} @ $#{format_currency(unit_price)} = <strong>$#{format_currency(total)}</strong></li>"
      end
      items_html += '</ul>'
    end
    
    # Notes HTML
    notes_html = ''
    if quote.notes.present?
      notes_html = "<div style=\"margin-top: 20px; padding: 15px; background-color: #f9fafb; border-left: 4px solid #d1d5db;\"><strong>Notes:</strong><br/>#{quote.notes}</div>"
    end
    
    # Custom message HTML
    custom_message_html = ''
    if custom_message.present?
      custom_message_html = "<p style=\"margin-bottom: 20px; color: #374151;\">#{custom_message}</p>"
    end
    
    # Build complete HTML email
    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
      </head>
      <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #1f2937; max-width: 600px; margin: 0 auto; padding: 20px;">
        #{custom_message_html}
        
        <p style="color: #374151;">Please find your quote details below:</p>
        
        <div style="background-color: #f3f4f6; padding: 20px; border-radius: 8px; margin: 20px 0;">
          <table style="width: 100%; border-collapse: collapse;">
            <tr>
              <td style="padding: 8px 0; color: #6b7280; font-size: 14px;">Quote Number:</td>
              <td style="padding: 8px 0; text-align: right; font-weight: bold;">#{quote.quote_number}</td>
            </tr>
            <tr>
              <td style="padding: 8px 0; color: #6b7280; font-size: 14px;">Total Amount:</td>
              <td style="padding: 8px 0; text-align: right; font-weight: bold; color: #059669; font-size: 18px;">$#{format_currency(quote.total)}</td>
            </tr>
            <tr>
              <td style="padding: 8px 0; color: #6b7280; font-size: 14px;">Valid Until:</td>
              <td style="padding: 8px 0; text-align: right; font-weight: bold;">#{quote.valid_until&.strftime('%B %d, %Y') || 'N/A'}</td>
            </tr>
          </table>
        </div>
        
        #{items_html}
        
        #{notes_html}
        
        <div style="margin: 30px 0; text-align: center;">
          <a href="#{quote_url}" style="display: inline-block; padding: 12px 30px; background-color: #2563eb; color: white; text-decoration: none; border-radius: 6px; font-weight: bold;">View Quote</a>
        </div>
        
        #{portal_link_html}
        
        <p style="margin-top: 30px; color: #6b7280; font-size: 14px;">Thank you for your business!</p>
      </body>
      </html>
    HTML
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
    
    # Public quote link
    parts << "View Quote: #{quote.public_link}"
    
    # Portal link if available
    if ENV['BUYER_PORTAL_URL'].present?
      portal_url = "#{ENV['BUYER_PORTAL_URL']}/quotes/#{quote.id}"
      parts << "Accept Online: #{portal_url}"
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
