# frozen_string_literal: true

# WarrantyNotificationService
# 
# Handles warranty-related email notifications using the existing CommunicationService
# and communication templates. This service wraps CommunicationService to provide
# warranty-specific notification methods.
#
# Usage:
#   WarrantyNotificationService.notify_manufacturer(warranty_claim)
#   WarrantyNotificationService.notify_company_on_response(warranty_claim)
#   WarrantyNotificationService.notify_client_on_approval(warranty_claim)
#   WarrantyNotificationService.notify_client_on_denial(warranty_claim)
#
# Communication Hierarchy:
#   Platform → Company → Location settings for email/SMS providers
#   Template fallback: Company template → Platform default template

class WarrantyNotificationService
  class Error < StandardError; end
  class TemplateNotFoundError < Error; end
  class MissingRecipientError < Error; end
  
  # Notify manufacturer when dealer submits a warranty claim
  #
  # @param warranty_claim [WarrantyClaim] The warranty claim being submitted
  # @param cc_emails [Array<String>, String, nil] addresses copied on the email
  #   (e.g. the submitting user, via "CC me"). Blank entries are dropped rather
  #   than failing the send — a bad CC must never cost the manufacturer their copy.
  # @return [Communication, nil] The created communication record or nil if disabled
  #
  def self.notify_manufacturer(warranty_claim, cc_emails: [])
    return nil unless should_notify?('notifyManufacturerOnSubmission', warranty_claim.company)

    # Find template (company-specific or platform default)
    template = find_template('warranty_submitted_to_manufacturer', warranty_claim.company_id)
    raise TemplateNotFoundError, 'Warranty submission template not found' unless template
    
    # Resolve recipient: company's own rep override → global factory contact
    recipient_email = resolve_manufacturer_email(warranty_claim)
    raise MissingRecipientError, 'Manufacturer has no email address' if recipient_email.blank?

    # Build template context
    context = build_claim_context(warranty_claim)

    cc = normalize_cc_addresses(cc_emails, exclude: recipient_email)
    body = render_template(template.body, context)

    # Send via existing CommunicationService
    CommunicationService.send_email(
      communicable: warranty_claim,
      to: recipient_email,
      cc: cc,
      subject: render_template(template.subject, context),
      body: body,
      content_type: content_type_for(body),
      category: 'warranty',
      template: template.id,
      metadata: {
        warranty_claim_id: warranty_claim.id,
        manufacturer_id: warranty_claim.manufacturer_id,
        notification_type: 'manufacturer_submission',
        cc_emails: cc
      }
    )
  rescue => e
    Rails.logger.error("WarrantyNotificationService: Failed to notify manufacturer for claim #{warranty_claim.id}: #{e.message}")
    raise e
  end
  
  # Notify manufacturer that a new note was added to the claim thread. Triggered
  # explicitly by the dealer ("Save & Notify"), so it is NOT gated by the
  # submission setting. Uses a 'warranty_note_added' template if configured, else
  # falls back to a plain inline message so the button always works.
  #
  # @param warranty_claim [WarrantyClaim]
  # @param note [Hash] the note entry { 'body', 'authorName', ... }
  # @return [Communication]
  #
  def self.notify_manufacturer_of_note(warranty_claim, note)
    recipient_email = resolve_manufacturer_email(warranty_claim)
    raise MissingRecipientError, 'Manufacturer has no email address' if recipient_email.blank?

    note ||= {}
    template = find_template('warranty_note_added', warranty_claim.company_id)
    context = build_claim_context(warranty_claim).merge(
      'note_body' => note['body'].to_s,
      'note_author' => note['authorName'].to_s
    )

    subject = template ? render_template(template.subject, context)
                       : "New note on warranty claim #{warranty_claim.claim_number}"
    body = if template
      render_template(template.body, context)
    else
      <<~BODY
        A new note was added to warranty claim #{warranty_claim.claim_number}#{note['authorName'].present? ? " by #{note['authorName']}" : ''}:

        #{note['body']}

        View the claim: #{warranty_claim.public_link}
      BODY
    end

    CommunicationService.send_email(
      communicable: warranty_claim,
      to: recipient_email,
      subject: subject,
      body: body,
      content_type: content_type_for(body),
      category: 'warranty',
      template: template&.id,
      metadata: {
        warranty_claim_id: warranty_claim.id,
        manufacturer_id: warranty_claim.manufacturer_id,
        notification_type: 'manufacturer_note'
      }
    )
  rescue => e
    Rails.logger.error("WarrantyNotificationService: Failed to notify manufacturer of note for claim #{warranty_claim.id}: #{e.message}")
    raise e
  end

  # Notify company when manufacturer responds to warranty claim
  #
  # @param warranty_claim [WarrantyClaim] The warranty claim with response
  # @return [Communication, nil] The created communication record or nil if disabled
  #
  def self.notify_company_on_response(warranty_claim)
    return nil unless should_notify?('notifyCompanyOnResponse', warranty_claim.company)
    
    template = find_template('warranty_manufacturer_responded', warranty_claim.company_id)
    raise TemplateNotFoundError, 'Warranty response template not found' unless template
    
    # Get company notification email (company setting or from assigned user)
    recipient_email = get_company_notification_email(warranty_claim)
    raise MissingRecipientError, 'No company notification email found' if recipient_email.blank?
    
    context = build_claim_context(warranty_claim)
    rendered_body = render_template(template.body, context)

    CommunicationService.send_email(
      communicable: warranty_claim,
      to: recipient_email,
      subject: render_template(template.subject, context),
      body: rendered_body,
      content_type: content_type_for(rendered_body),
      category: 'warranty',
      template: template.id,
      metadata: {
        warranty_claim_id: warranty_claim.id,
        notification_type: 'company_response'
      }
    )
  rescue => e
    Rails.logger.error("WarrantyNotificationService: Failed to notify company for claim #{warranty_claim.id}: #{e.message}")
    raise e
  end
  
  # Notify client when warranty claim is approved
  #
  # @param warranty_claim [WarrantyClaim] The approved warranty claim
  # @return [Communication, nil] The created communication record or nil if disabled
  #
  def self.notify_client_on_approval(warranty_claim)
    return nil unless should_notify?('notifyClientOnResolution', warranty_claim.company)
    
    template = find_template('warranty_approved_client', warranty_claim.company_id)
    raise TemplateNotFoundError, 'Warranty approval template not found' unless template
    
    # Get client email from service ticket or contact
    recipient_email = get_client_email(warranty_claim)
    return nil if recipient_email.blank? # Don't fail if no client email
    
    context = build_claim_context(warranty_claim)
    rendered_body = render_template(template.body, context)

    CommunicationService.send_email(
      communicable: warranty_claim,
      to: recipient_email,
      subject: render_template(template.subject, context),
      body: rendered_body,
      content_type: content_type_for(rendered_body),
      category: 'warranty',
      template: template.id,
      portal_visible: true, # Show in client portal
      metadata: {
        warranty_claim_id: warranty_claim.id,
        notification_type: 'client_approval'
      }
    )
  rescue => e
    Rails.logger.error("WarrantyNotificationService: Failed to notify client for claim #{warranty_claim.id}: #{e.message}")
    # Don't raise - client notification is optional
    nil
  end
  
  # Notify client when warranty claim is denied
  #
  # @param warranty_claim [WarrantyClaim] The denied warranty claim
  # @return [Communication, nil] The created communication record or nil if disabled
  #
  def self.notify_client_on_denial(warranty_claim)
    return nil unless should_notify?('notifyClientOnResolution', warranty_claim.company)
    
    template = find_template('warranty_denied_client', warranty_claim.company_id)
    raise TemplateNotFoundError, 'Warranty denial template not found' unless template
    
    recipient_email = get_client_email(warranty_claim)
    return nil if recipient_email.blank?
    
    context = build_claim_context(warranty_claim)
    rendered_body = render_template(template.body, context)

    CommunicationService.send_email(
      communicable: warranty_claim,
      to: recipient_email,
      subject: render_template(template.subject, context),
      body: rendered_body,
      content_type: content_type_for(rendered_body),
      category: 'warranty',
      template: template.id,
      portal_visible: true,
      metadata: {
        warranty_claim_id: warranty_claim.id,
        notification_type: 'client_denial'
      }
    )
  rescue => e
    Rails.logger.error("WarrantyNotificationService: Failed to notify client for claim #{warranty_claim.id}: #{e.message}")
    nil
  end
  
  private
  
  # Check if notification should be sent based on settings
  #
  # @param setting_key [String] The notification setting key
  # @param company [Company] The company
  # @return [Boolean] True if notification should be sent
  #
  def self.should_notify?(setting_key, company)
    warranty_settings = Setting.get_warranty_settings('Company', company.id)
    warranty_settings[setting_key] != false
  end
  
  # Find communication template with company → platform fallback
  #
  # @param template_type [String] The template type
  # @param company_id [Integer] The company ID
  # @return [CommunicationTemplate, nil] The template or nil
  #
  def self.find_template(template_type, company_id)
    # Try company-specific template first
    template = CommunicationTemplate.find_by(
      template_type: template_type,
      company_id: company_id,
      is_active: true
    )
    
    # Fall back to platform default template
    template ||= CommunicationTemplate.find_by(
      template_type: template_type,
      company_id: nil,
      is_active: true,
      is_default: true
    )
    
    template
  end
  
  # Get company notification email from settings or assigned user
  #
  # @param warranty_claim [WarrantyClaim] The warranty claim
  # @return [String, nil] The email address
  #
  def self.get_company_notification_email(warranty_claim)
    # Try company warranty settings notification email
    warranty_settings = Setting.get_warranty_settings('Company', warranty_claim.company_id)
    return warranty_settings['notificationEmail'] if warranty_settings['notificationEmail'].present?
    
    # Try assigned user email
    if warranty_claim.assigned_to_id.present?
      assigned_user = User.find_by(id: warranty_claim.assigned_to_id)
      return assigned_user.email if assigned_user&.email.present?
    end
    
    # Fall back to company communication settings
    comm_settings = CommunicationSettingsService.for_company(warranty_claim.company)
    email_config = comm_settings.email_config
    email_config[:from_email]
  end
  
  # Get client email from service ticket or contact
  #
  # @param warranty_claim [WarrantyClaim] The warranty claim
  # @return [String, nil] The client email address
  #
  def self.get_client_email(warranty_claim)
    return nil unless warranty_claim.service_ticket.present?
    
    service_ticket = warranty_claim.service_ticket
    
    # Try contact email first
    if service_ticket.contact_id.present?
      contact = service_ticket.contact
      return contact.email if contact&.email.present?
    end
    
    # Try account email
    if service_ticket.account_id.present?
      account = service_ticket.account
      return account.email if account&.email.present?
    end
    
    nil
  end
  
  # Build template context with all available claim data
  #
  # @param warranty_claim [WarrantyClaim] The warranty claim
  # @return [Hash] Template context variables
  #
  def self.build_claim_context(warranty_claim)
    company = warranty_claim.company
    manufacturer = warranty_claim.manufacturer
    service_ticket = warranty_claim.service_ticket
    
    # Get dealer code from location or company manufacturer relationship
    dealer_code = get_dealer_code(warranty_claim)
    
    # Get company contact info from settings or location
    company_phone = get_company_phone(warranty_claim.company, warranty_claim.location)
    company_email = get_company_email(warranty_claim.company)
    
    context = {
      'claim_number' => warranty_claim.claim_number,
      'claim_date' => warranty_claim.submitted_at&.strftime('%m/%d/%Y') || Date.today.strftime('%m/%d/%Y'),
      'estimated_amount' => format_currency(warranty_claim.estimated_amount),
      'approved_amount' => format_currency(warranty_claim.approved_amount),
      'claim_notes' => warranty_claim.notes_to_manufacturer || '',
      'response_status' => warranty_claim.status&.titleize || 'Pending',
      'response_date' => warranty_claim.manufacturer_responded_at&.strftime('%m/%d/%Y') || warranty_claim.updated_at&.strftime('%m/%d/%Y'),
      'manufacturer_name' => manufacturer&.name || 'Manufacturer',
      'manufacturer_response' => warranty_claim.manufacturer_response || '',
      'denial_reason' => warranty_claim.denial_reason || '',
      'company_name' => company.name,
      'company_phone' => company_phone,
      'company_email' => company_email,
      'dealer_code' => dealer_code || 'N/A',
      'warranty_link' => warranty_claim.public_link || '',
      'claim_admin_link' => admin_claim_url(warranty_claim),
      'portal_link' => client_portal_url(warranty_claim)
    }
    
    # Add service ticket info if available
    if service_ticket
      context['ticket_number'] = service_ticket.id.to_s
      context['ticket_description'] = service_ticket.description || service_ticket.title || ''
      context['vehicle_info'] = format_vehicle_info(service_ticket)
      context['customer_name'] = format_customer_name(service_ticket)
    else
      context['ticket_number'] = ''
      context['ticket_description'] = ''
      context['vehicle_info'] = 'Vehicle'
      context['customer_name'] = 'Customer'
    end
    
    # Add parts and labor details
    context['parts_list'] = format_parts_list(warranty_claim)
    context['labor_details'] = format_labor_details(warranty_claim)
    mfr_attachment_count = warranty_claim.manufacturer_attachments.count
    context['photos_count'] = mfr_attachment_count
    context['documents_count'] = mfr_attachment_count
    
    # Conditional sections
    context['approved_amount_section'] = warranty_claim.approved_amount.present? ? 
    "Approved Amount: #{format_currency(warranty_claim.approved_amount)}" : ''
    context['client_copay_section'] = warranty_claim.client_copay_amount.to_f > 0 ? 
    "Your Responsibility: #{format_currency(warranty_claim.client_copay_amount)}" : 
    "No out-of-pocket cost to you."
    context['customer_responsibility_section'] = warranty_claim.estimated_amount.present? ? 
    "Estimated repair cost: #{format_currency(warranty_claim.estimated_amount)}" : ''
    context['next_steps'] = 'We will schedule the repair and keep you updated on progress.'

    # HTML-safe twins of the multi-line values, for templates whose body is real
    # HTML. The plain-text keys are unchanged so existing templates render
    # exactly as before; an HTML template that used them would collapse the
    # parts list onto one line, which is the bug this pair exists to avoid.
    context['parts_list_html']    = to_html_lines(context['parts_list'])
    context['labor_details_html'] = to_html_lines(context['labor_details'])
    context['claim_notes_html']   = to_html_lines(context['claim_notes'].presence || 'None')

    context
  end

  # Escape a plain-text value and keep its line breaks visible in HTML.
  def self.to_html_lines(text)
    ERB::Util.html_escape(text.to_s).to_s.gsub(/\r?\n/, '<br>')
  end

  # Warranty templates are seeded as plain text, but every email in this app is
  # delivered as text/html by default — and HTML collapses whitespace, so those
  # bodies arrived as one unbroken paragraph. Send a body that carries no markup
  # as text/plain so its line breaks survive. Templates that ARE html (the
  # manufacturer claim email, and anything a dealer writes in the editor) are
  # unaffected.
  def self.content_type_for(body)
    markup = body.to_s.match?(/<(a|br|div|p|table|td|tr|span|h[1-6]|strong|em|ul|ol|li)\b[^>]*>/i)
    markup ? 'text/html' : 'text/plain'
  end
  
  # Render template with variable substitution
  #
  # @param text [String] Template text with {{variables}}
  # @param context [Hash] Variable values
  # @return [String] Rendered text
  #
  def self.render_template(text, context)
    return text if text.blank?
    
    text.gsub(/\{\{(\w+)\}\}/) do |match|
      key = $1
      context[key] || match # Keep placeholder if variable not found
    end
  end
  
  # Format currency
  def self.format_currency(amount)
    return '$0.00' if amount.blank?
    "$#{sprintf('%.2f', amount.to_f)}"
  end
  
  # Format vehicle information
  def self.format_vehicle_info(service_ticket)
    return 'Vehicle' unless service_ticket.vehicle
    
    v = service_ticket.vehicle
    "#{v.year} #{v.make} #{v.model}".strip
  end
  
  # Format customer name
  def self.format_customer_name(service_ticket)
    if service_ticket.contact
      "#{service_ticket.contact.first_name} #{service_ticket.contact.last_name}".strip
    elsif service_ticket.account
      service_ticket.account.name
    else
      'Customer'
    end
  end
  
  # Format parts list
  def self.format_parts_list(warranty_claim)
    return 'No parts listed' if warranty_claim.parts.blank?
    
    parts = warranty_claim.parts.is_a?(Array) ? 
      warranty_claim.parts : 
      JSON.parse(warranty_claim.parts.to_s) rescue []
    
    return 'No parts listed' if parts.empty?
    
    parts.map do |part|
      unit_cost = part['cost'] || part['unitCost'] || part['unit_cost']
      "- #{part['description'] || part['part_number']}: Qty #{part['quantity']} @ #{format_currency(unit_cost)}"
    end.join("\n")
  end
  
  # Format labor details
  def self.format_labor_details(warranty_claim)
    return 'No labor listed' if warranty_claim.labor.blank?
    
    labor = warranty_claim.labor.is_a?(Array) ? 
      warranty_claim.labor : 
      JSON.parse(warranty_claim.labor.to_s) rescue []
    
    return 'No labor listed' if labor.empty?
    
    labor.map do |item|
      "- #{item['description']}: #{item['hours']} hrs @ #{format_currency(item['rate'])}/hr"
    end.join("\n")
  end
  
  # Generate admin claim URL
  def self.admin_claim_url(warranty_claim)
    base_url = ENV['FRONTEND_URL'] || 'https://staging.crm.landlordinsight.com'
    "#{base_url}/warranty-claims/#{warranty_claim.id}"
  end
  
  # Generate client portal URL
  def self.client_portal_url(warranty_claim)
    base_url = ENV['FRONTEND_URL'] || 'https://staging.crm.landlordinsight.com'
    "#{base_url}/portal/service-tickets"
  end
  
  # Resolve where to send a warranty claim — the claim SUBMISSION target, not the
  # relationship rep:
  #   company claim_email override → factory claim_email → factory contact_email (legacy)
  def self.resolve_manufacturer_email(warranty_claim)
    company_manufacturer = CompanyManufacturer.find_by(
      company_id: warranty_claim.company_id,
      manufacturer_id: warranty_claim.manufacturer_id
    )
    company_manufacturer&.claim_email.presence ||
      warranty_claim.manufacturer&.claim_email.presence ||
      warranty_claim.manufacturer&.contact_email
  end

  # Normalize a CC list into the single comma-joined string the Communication
  # record and the mail gem both expect. Accepts an array or a comma/semicolon
  # separated string. Drops blanks, anything that isn't shaped like an address,
  # duplicates, and the primary recipient (nobody needs two copies). Returns nil
  # when nothing survives, so the send behaves exactly as it did before CC.
  def self.normalize_cc_addresses(cc_emails, exclude: nil)
    # Split on the entry level too: a single "a@x.com, b@x.com" string is a
    # perfectly ordinary way for a caller to pass two addresses.
    list = Array(cc_emails).flat_map { |entry| entry.to_s.split(/[,;]/) }

    excluded = exclude.to_s.strip.downcase
    seen = []
    list.each do |raw|
      address = raw.to_s.strip
      next if address.blank?
      next unless address.match?(URI::MailTo::EMAIL_REGEXP)
      next if address.downcase == excluded
      next if seen.any? { |kept| kept.downcase == address.downcase }
      seen << address
    end

    seen.presence&.join(', ')
  end

  # Get dealer code from location or company manufacturer relationship
  def self.get_dealer_code(warranty_claim)
    manufacturer_id = warranty_claim.manufacturer_id
    
    # Try location-specific dealer code first
    if warranty_claim.location_id.present?
      location_manufacturer = LocationManufacturer.find_by(
        location_id: warranty_claim.location_id,
        manufacturer_id: manufacturer_id
      )
      return location_manufacturer.dealer_code if location_manufacturer&.dealer_code.present?
    end
    
    # Fall back to company-level dealer code
    company_manufacturer = CompanyManufacturer.find_by(
      company_id: warranty_claim.company_id,
      manufacturer_id: manufacturer_id
    )
    return company_manufacturer.dealer_code if company_manufacturer&.dealer_code.present?
    
    # No dealer code found
    nil
  end
  
  # Get company phone from location or communication settings
  def self.get_company_phone(company, location = nil)
    # Try location phone first
    if location&.phone.present?
      return location.phone
    end
    
    # Try communication settings
    comm_settings = CommunicationSettingsService.for_company(company)
    phone = comm_settings.sms_config[:from_number]
    return phone if phone.present?
    
    # Default fallback
    '(555) 555-5555'
  end
  
  # Get company email from communication settings
  def self.get_company_email(company)
    comm_settings = CommunicationSettingsService.for_company(company)
    email_config = comm_settings.email_config
    email_config[:from_email] || Brand.from_email
  end
end
