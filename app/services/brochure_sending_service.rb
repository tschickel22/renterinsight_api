# frozen_string_literal: true

# Service to handle sending brochures via email, SMS, or both
# Integrates with company communication settings and falls back to platform settings
# 
# Usage:
#   BrochureSendingService.new(brochure).send(
#     delivery_methods: ['email', 'sms'],
#     to_email: 'customer@example.com',
#     to_phone: '+1234567890',
#     custom_message: 'Check out these properties'
#   )

class BrochureSendingService
  class Error < StandardError; end
  
  # Recipients we can attribute a click to. Anything else sends untracked.
  TRACKABLE_ENTITY_TYPES = %w[Lead Contact].freeze

  attr_reader :brochure, :results

  def initialize(brochure)
    @brochure = brochure
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
  # @param entity_type [String] - 'Lead' or 'Contact', the person being sent to.
  #   Callers must have already verified the record belongs to the brochure's
  #   company. Supplying it is what makes the click attributable.
  # @param entity_id [Integer] - id of that Lead/Contact
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
    entity_type: nil,
    entity_id: nil,
    **options
  )
    @entity_type = entity_type.to_s.presence
    @entity_id   = entity_id
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
    tracked_link = build_tracked_link
    body = build_email_body(custom_message: custom_message,
                            brochure_url: link_url(tracked_link),
                            brochure_link: tracked_link)

    begin
      result = CommunicationService.send_email(
        communicable: brochure,
        to: to,
        subject: subject,
        body: body,
        from: from,
        cc: cc,
        bcc: bcc,
        category: 'brochures',
        metadata: { 
          brochure_id: brochure.id,
          brochure_title: brochure.title,
          vehicle_count: brochure.vehicle_count
        },
        portal_visible: false,
        send_async: false,
        **options
      )
      
      if result[:success]
        attach_communication(tracked_link, result[:communication])
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
      Rails.logger.error "Error sending brochure email: #{e.message}"
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
    tracked_link = build_tracked_link
    body = build_sms_body(custom_message: custom_message, brochure_url: link_url(tracked_link))

    begin
      result = CommunicationService.send_sms(
        communicable: brochure,
        to: to,
        body: body,
        from: from,
        category: 'brochures',
        metadata: { 
          brochure_id: brochure.id,
          brochure_title: brochure.title,
          vehicle_count: brochure.vehicle_count
        },
        portal_visible: false,
        send_async: false,
        **options
      )
      
      if result[:success]
        attach_communication(tracked_link, result[:communication])
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
      Rails.logger.error "Error sending brochure SMS: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      @results[:errors] << e.message
      @results[:failed] << { 
        channel: 'sms', 
        to: to,
        reason: e.message 
      }
    end
  end
  
  # One TrackedLink per channel, so an email click and an SMS click stay
  # distinguishable. Returns nil when there's nobody to attribute the click to,
  # or if minting fails — the send itself must never break over tracking.
  def build_tracked_link
    return nil unless TRACKABLE_ENTITY_TYPES.include?(@entity_type) && @entity_id.present?

    link = TrackedLink.create_for_brochure!(
      company:     brochure.company,
      brochure:    brochure,
      url:         brochure.public_url(public_base_url),
      entity_type: @entity_type,
      entity_id:   @entity_id
    )
    # Carry the recipient's identity onto the brochure page itself, so the homes
    # they click once they're there are attributable too. The token is only
    # known after create, hence the second write.
    link.update_column(:url, recipient_brochure_url(link))
    link
  rescue => e
    Rails.logger.warn "[Brochure] tracked link creation failed for brochure #{brochure.id}: #{e.message}"
    nil
  end

  # Each home in the email gets its own tracked link, so we learn which homes a
  # recipient is drawn to and not merely that they opened the collection. The
  # link carries vehicle_id, which also feeds the Hot Inventory Interest queue.
  def listing_link_url(vehicle, brochure_link)
    return nil unless brochure_link

    TrackedLink.for_brochure_listing!(
      company:     brochure.company,
      brochure:    brochure,
      vehicle_id:  vehicle.id,
      url:         recipient_brochure_url(brochure_link, vehicle_id: vehicle.id),
      entity_type: @entity_type,
      entity_id:   @entity_id
    ).tracking_url
  rescue => e
    Rails.logger.warn "[Brochure] listing link failed for vehicle #{vehicle.id}: #{e.message}"
    nil
  end

  def recipient_brochure_url(brochure_link, vehicle_id: nil)
    query = { rt: brochure_link.token }
    query[:listing] = vehicle_id if vehicle_id
    "#{brochure.public_url(public_base_url)}?#{query.to_query}"
  end

  def link_url(tracked_link)
    tracked_link&.tracking_url || brochure.public_url(public_base_url)
  end

  def attach_communication(tracked_link, communication)
    return if tracked_link.nil? || communication.nil?

    tracked_link.update_column(:communication_id, communication.id)
  rescue => e
    Rails.logger.warn "[Brochure] linking tracked link #{tracked_link&.id} to communication failed: #{e.message}"
  end

  def public_base_url
    ENV['FRONTEND_URL'] || ENV['API_BASE_URL'] || 'http://localhost:3000'
  end

  def build_email_subject
    "#{brochure.title} - Property Collection from #{company_name}"
  end

  def build_email_body(custom_message:, brochure_url: nil, brochure_link: nil)
    brochure_url ||= brochure.public_url(public_base_url)

    # Build vehicle summary HTML
    vehicles = brochure.vehicles.active.limit(5)
    vehicles_html = ''
    
    if vehicles.any?
      vehicles_html = '<h3 style="margin-top: 20px; margin-bottom: 15px; color: #374151;">Featured Properties:</h3>'
      vehicles_html += '<div style="margin-bottom: 20px;">'
      
      vehicles.each do |vehicle|
        price = vehicle.sale_price || vehicle.rent_price
        price_display = price ? "$#{format_currency(price)}#{vehicle.rent_price ? '/mo' : ''}" : 'Contact for pricing'

        # Each card links to that home inside the brochure, tracked, so we know
        # which one caught their eye. Falls back to an unlinked card when the
        # send isn't attributable to anyone.
        card_html = <<~VEHICLE_HTML
          <div style="padding: 15px; background-color: #f9fafb; border-radius: 8px; margin-bottom: 15px; border-left: 4px solid #2563eb;">
            <div style="font-weight: bold; color: #1f2937; font-size: 16px; margin-bottom: 5px;">#{vehicle.display_name}</div>
            <div style="color: #6b7280; font-size: 14px; margin-bottom: 5px;">
              #{[vehicle.location_city, vehicle.location_state].compact.join(', ')}
            </div>
            <div style="color: #059669; font-weight: bold; font-size: 16px;">#{price_display}</div>
          </div>
        VEHICLE_HTML

        listing_url = listing_link_url(vehicle, brochure_link)
        vehicles_html += if listing_url
                           %(<a href="#{listing_url}" style="text-decoration: none; color: inherit; display: block;">#{card_html}</a>)
                         else
                           card_html
                         end
      end
      
      if brochure.vehicle_count > 5
        vehicles_html += "<p style=\"color: #6b7280; font-size: 14px;\">Plus #{brochure.vehicle_count - 5} more properties...</p>"
      end
      
      vehicles_html += '</div>'
    end
    
    # Custom message HTML
    custom_message_html = ''
    if custom_message.present?
      custom_message_html = "<p style=\"margin-bottom: 20px; color: #374151; line-height: 1.6;\">#{custom_message}</p>"
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
        
        <p style="color: #374151; font-size: 16px;">We've created a special collection of properties just for you.</p>
        
        <div style="background-color: #f3f4f6; padding: 20px; border-radius: 8px; margin: 20px 0;">
          <table style="width: 100%; border-collapse: collapse;">
            <tr>
              <td style="padding: 8px 0; color: #6b7280; font-size: 14px;">Collection:</td>
              <td style="padding: 8px 0; text-align: right; font-weight: bold; font-size: 18px;">#{brochure.title}</td>
            </tr>
            <tr>
              <td style="padding: 8px 0; color: #6b7280; font-size: 14px;">Properties:</td>
              <td style="padding: 8px 0; text-align: right; font-weight: bold; color: #2563eb; font-size: 18px;">#{brochure.vehicle_count} listings</td>
            </tr>
          </table>
        </div>
        
        #{vehicles_html}
        
        <div style="margin: 30px 0; text-align: center;">
          <a href="#{brochure_url}" style="display: inline-block; padding: 15px 40px; background-color: #2563eb; color: white; text-decoration: none; border-radius: 8px; font-weight: bold; font-size: 16px;">View Full Collection</a>
        </div>
        
        #{brochure.description.present? ? "<div style=\"margin-top: 20px; padding: 15px; background-color: #f9fafb; border-left: 4px solid #d1d5db;\">#{brochure.description}</div>" : ''}
        
        <p style="margin-top: 30px; color: #6b7280; font-size: 14px; text-align: center;">
          Thank you for your interest!<br/>
          #{company_name}
        </p>
      </body>
      </html>
    HTML
  end
  
  def build_sms_body(custom_message:, brochure_url: nil)
    brochure_url ||= brochure.public_url(public_base_url)

    parts = []
    
    # Custom message if provided
    parts << custom_message if custom_message.present?
    
    # Brochure summary
    parts << "#{brochure.title}: #{brochure.vehicle_count} properties"
    
    # Brochure link
    parts << "View Collection: #{brochure_url}"
    
    parts.join("\n\n")
  end
  
  def format_currency(amount)
    sprintf('%.2f', amount.to_f)
  end
  
  def company_name
    brochure.company.name || ENV['COMPANY_NAME'] || 'Platform DMS'
  end
end
