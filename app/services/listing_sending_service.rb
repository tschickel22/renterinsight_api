# frozen_string_literal: true

# Service to handle sending listings via email, SMS, or both
# Integrates with company communication settings and falls back to platform settings
# 
# Usage:
#   ListingSendingService.new(listing).send(
#     delivery_methods: ['email', 'sms'],
#     to_email: 'customer@example.com',
#     to_phone: '+1234567890',
#     custom_message: 'Check out this property'
#   )

class ListingSendingService
  class Error < StandardError; end
  
  attr_reader :listing, :results
  
  def initialize(listing)
    @listing = listing
    @results = { sent: [], failed: [], errors: [] }
  end
  
  # Main send method
  # @param delivery_methods [Array<String>] - array of 'email' and/or 'sms'
  # @param to_email [String] - recipient email
  # @param to_phone [String] - recipient phone
  # @param custom_message [String] - custom message to include
  # @param from_email [String] - optional from email
  # @param from_phone [String] - optional from phone
  # @param cc [String] - CC recipients for email
  # @param bcc [String] - BCC recipients for email
  # @return [Hash] - { sent: [], failed: [], errors: [] }
  def send(
    delivery_methods: ['email'],
    to_email: nil,
    to_phone: nil,
    custom_message: nil,
    from_email: nil,
    from_phone: nil,
    cc: nil,
    bcc: nil,
    **options
  )
    # Validate delivery methods
    valid_methods = ['email', 'sms']
    invalid = delivery_methods - valid_methods
    raise ArgumentError, "Invalid delivery methods: #{invalid.join(', ')}" if invalid.any?
    
    # Validate recipients
    if delivery_methods.include?('email') && to_email.blank?
      raise ArgumentError, "Email address is required when sending via email"
    end
    
    if delivery_methods.include?('sms') && to_phone.blank?
      raise ArgumentError, "Phone number is required when sending via SMS"
    end
    
    # Send via each requested method
    delivery_methods.each do |method|
      case method
      when 'email'
        send_email(
          to: to_email,
          custom_message: custom_message,
          from: from_email,
          cc: cc,
          bcc: bcc,
          **options
        )
      when 'sms'
        send_sms(
          to: to_phone,
          custom_message: custom_message,
          from: from_phone,
          **options
        )
      end
    end
    
    @results
  end
  
  private
  
  def send_email(to:, custom_message:, from:, cc:, bcc:, **options)
    subject = build_email_subject
    body = build_email_body(custom_message: custom_message)
    
    begin
      result = CommunicationService.send_email(
        communicable: listing,
        to: to,
        subject: subject,
        body: body,
        from: from,
        cc: cc,
        bcc: bcc,
        category: 'listings',
        metadata: { 
          listing_id: listing.id,
          listing_type: listing.listing_type,
          year: listing.year,
          make: listing.make,
          model: listing.model,
          price: listing.sale_price || listing.rent_price
        },
        portal_visible: false,
        send_async: false,
        **options
      )
      
      if result[:success]
        @results[:sent] << {
          channel: 'email',
          to: to,
          communication: result[:communication]
        }
      else
        @results[:errors] << result[:error]
        @results[:failed] << { 
          channel: 'email', 
          to: to,
          reason: result[:error] 
        }
      end
    rescue CommunicationService::OptOutError => e
      @results[:errors] << "Recipient has opted out of email communications"
      @results[:failed] << { 
        channel: 'email', 
        to: to,
        reason: 'Opted out' 
      }
    rescue => e
      Rails.logger.error "Error sending listing email: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      @results[:errors] << e.message
      @results[:failed] << { 
        channel: 'email', 
        to: to,
        reason: e.message 
      }
    end
  end
  
  def send_sms(to:, custom_message:, from:, **options)
    body = build_sms_body(custom_message: custom_message)
    
    begin
      result = CommunicationService.send_sms(
        communicable: listing,
        to: to,
        body: body,
        from: from,
        category: 'listings',
        metadata: { 
          listing_id: listing.id,
          listing_type: listing.listing_type,
          year: listing.year,
          make: listing.make,
          model: listing.model,
          price: listing.sale_price || listing.rent_price
        },
        portal_visible: false,
        send_async: false,
        **options
      )
      
      if result[:success]
        @results[:sent] << {
          channel: 'sms',
          to: to,
          communication: result[:communication]
        }
      else
        @results[:errors] << result[:error]
        @results[:failed] << { 
          channel: 'sms', 
          to: to,
          reason: result[:error] 
        }
      end
    rescue CommunicationService::OptOutError => e
      @results[:errors] << "Recipient has opted out of SMS communications"
      @results[:failed] << { 
        channel: 'sms', 
        to: to,
        reason: 'Opted out' 
      }
    rescue => e
      Rails.logger.error "Error sending listing SMS: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      @results[:errors] << e.message
      @results[:failed] << { 
        channel: 'sms', 
        to: to,
        reason: e.message 
      }
    end
  end
  
  def build_email_subject
    listing_title = [listing.year, listing.make, listing.model].compact.join(' ')
    "#{listing_title} - Property Listing from #{company_name}"
  end
  
  def build_email_body(custom_message:)
    # Get public URL for the listing
    base_url = ENV['FRONTEND_URL'] || ENV['API_BASE_URL'] || 'http://localhost:3000'
    company_subdomain = listing.company.subdomain || 'demo'
    listing_url = "#{base_url}/#{company_subdomain}/listing/#{listing.id}"
    
    # Listing details
    listing_title = [listing.year, listing.make, listing.model].compact.join(' ')
    price = listing.sale_price || listing.rent_price
    price_display = price ? "$#{format_currency(price)}#{listing.rent_price ? '/mo' : ''}" : 'Contact for pricing'
    location = [listing.location_city, listing.location_state].compact.join(', ')
    
    # Get first image
    image_url = nil
    if listing.images&.any?
      first_image = listing.images.first
      image_url = first_image.start_with?('http') ? first_image : "#{base_url}#{first_image}"
    end
    
    # Custom message HTML
    custom_message_html = ''
    if custom_message.present?
      custom_message_html = "<p style=\"margin-bottom: 20px; color: #374151; line-height: 1.6;\">#{custom_message}</p>"
    end
    
    # Image HTML
    image_html = ''
    if image_url
      image_html = <<~IMAGE
        <div style=\"margin: 20px 0; text-align: center;\">
          <img src=\"#{image_url}\" alt=\"#{listing_title}\" style=\"max-width: 100%; height: auto; border-radius: 8px; max-height: 400px;\"/>
        </div>
      IMAGE
    end
    
    # Features HTML
    features_html = ''
    if listing.features&.any?
      features_html = '<h3 style=\"margin-top: 20px; margin-bottom: 10px; color: #374151;\">Features:</h3>'
      features_html += '<ul style=\"margin-bottom: 20px; color: #6b7280; line-height: 1.8;\">'
      listing.features.first(5).each do |feature|
        features_html += "<li>#{feature}</li>"
      end
      features_html += '</ul>'
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
        
        <p style="color: #374151; font-size: 16px;">I wanted to share this property listing with you.</p>
        
        #{image_html}
        
        <div style="background-color: #f3f4f6; padding: 20px; border-radius: 8px; margin: 20px 0;">
          <h2 style="margin: 0 0 10px 0; color: #1f2937; font-size: 24px;">#{listing_title}</h2>
          <p style="margin: 5px 0; color: #6b7280; font-size: 16px;">#{location}</p>
          <p style="margin: 15px 0 0 0; color: #059669; font-weight: bold; font-size: 28px;">#{price_display}</p>
        </div>
        
        #{features_html}
        
        #{listing.description.present? ? "<div style=\"margin: 20px 0; color: #374151; line-height: 1.8;\">#{listing.description}</div>" : ''}
        
        <div style="margin: 30px 0; text-align: center;\">
          <a href="#{listing_url}" style="display: inline-block; padding: 15px 40px; background-color: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; font-size: 16px;">View Full Listing</a>
        </div>
        
        <p style="margin-top: 30px; color: #6b7280; font-size: 14px; text-align: center;">
          Thank you for your interest!<br/>
          #{company_name}
        </p>
      </body>
      </html>
    HTML
  end
  
  def build_sms_body(custom_message:)
    base_url = ENV['FRONTEND_URL'] || ENV['API_BASE_URL'] || 'http://localhost:3000'
    company_subdomain = listing.company.subdomain || 'demo'
    listing_url = "#{base_url}/#{company_subdomain}/listing/#{listing.id}"
    
    listing_title = [listing.year, listing.make, listing.model].compact.join(' ')
    price = listing.sale_price || listing.rent_price
    price_display = price ? "$#{format_currency(price)}#{listing.rent_price ? '/mo' : ''}" : 'Contact for pricing'
    
    parts = []
    
    # Custom message if provided
    parts << custom_message if custom_message.present?
    
    # Listing summary
    parts << "#{listing_title}: #{price_display}"
    
    # Listing link
    parts << "View Listing: #{listing_url}"
    
    parts.join("\n\n")
  end
  
  def format_currency(amount)
    sprintf('%.2f', amount.to_f)
  end
  
  def company_name
    listing.company.name || ENV['COMPANY_NAME'] || 'Platform DMS'
  end
end
