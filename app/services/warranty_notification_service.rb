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
  # @return [Communication, nil] The created communication record or nil if disabled
  #
  def self.notify_manufacturer(warranty_claim)
    return nil unless should_notify?('notifyManufacturerOnSubmission', warranty_claim.company)
    
    # Find template (company-specific or platform default)
    template = find_template('warranty_submitted_to_manufacturer', warranty_claim.company_id)
    raise TemplateNotFoundError, 'Warranty submission template not found' unless template
    
    # Resolve recipient: company's own rep override → global factory contact
    recipient_email = resolve_manufacturer_email(warranty_claim)
    raise MissingRecipientError, 'Manufacturer has no email address' if recipient_email.blank?

    # Build template context
    context = build_claim_context(warranty_claim)

    # Send via existing CommunicationService
    CommunicationService.send_email(
      communicable: warranty_claim,
      to: recipient_email,
      subject: render_template(template.subject, context),
      body: render_template(template.body, context),
      category: 'warranty',
      template: template.id,
      metadata: {
        warranty_claim_id: warranty_claim.id,
        manufacturer_id: warranty_claim.manufacturer_id,
        notification_type: 'manufacturer_submission'
      }
    )
  rescue => e
    Rails.logger.error("WarrantyNotificationService: Failed to notify manufacturer for claim #{warranty_claim.id}: #{e.message}")
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
    
    CommunicationService.send_email(
      communicable: warranty_claim,
      to: recipient_email,
      subject: render_template(template.subject, context),
      body: render_template(template.body, context),
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
    
    CommunicationService.send_email(
      communicable: warranty_claim,
      to: recipient_email,
      subject: render_template(template.subject, context),
      body: render_template(template.body, context),
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
    
    CommunicationService.send_email(
      communicable: warranty_claim,
      to: recipient_email,
      subject: render_template(template.subject, context),
      body: render_template(template.body, context),
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
    
    context
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
      "- #{part['description'] || part['part_number']}: Qty #{part['quantity']} @ #{format_currency(part['cost'])}"
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
    email_config[:from_email] || 'noreply@renterinsight.com'
  end
end
