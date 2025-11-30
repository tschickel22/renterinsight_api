# frozen_string_literal: true

# SMS Service with three-tier inheritance: Location → Company → Platform
# Handles SMS notifications using Twilio
class SmsService
  attr_reader :location, :company, :sms_settings
  
  def initialize(location: nil, company: nil)
    @location = location
    @company = company || location&.company
    @sms_settings = resolve_sms_settings
  end
  
  # Send invoice notification via SMS
  def send_invoice_notification(invoice)
    contact = invoice.contact
    
    # Validate phone number exists
    unless contact.phone.present?
      Rails.logger.warn "[SmsService] Cannot send SMS - contact #{contact.id} has no phone number"
      return { success: false, error: 'Contact has no phone number' }
    end
    
    # Build message from template
    message = invoice_template(invoice)
    
    # Send SMS
    send_sms(
      to: contact.phone,
      body: message
    )
  end
  
  # Send payment receipt notification via SMS
  def send_payment_receipt(invoice, payment)
    contact = invoice.contact
    
    unless contact.phone.present?
      Rails.logger.warn "[SmsService] Cannot send SMS - contact #{contact.id} has no phone number"
      return { success: false, error: 'Contact has no phone number' }
    end
    
    message = payment_receipt_template(invoice, payment)
    
    send_sms(
      to: contact.phone,
      body: message
    )
  end
  
  # Generic SMS sender
  def send_sms(to:, body:)
    # Check all possible key variations for from_number
    from_number = sms_settings['fromNumber'] || 
                  sms_settings[:fromNumber] ||
                  sms_settings['from_number'] ||
                  sms_settings[:from_number] ||
                  sms_settings['FromNumber'] ||
                  sms_settings[:FromNumber]
    
    unless from_number.present?
      Rails.logger.error "[SmsService] Cannot send SMS - no from number configured"
      Rails.logger.error "[SmsService] Available SMS settings keys: #{sms_settings.keys.inspect}"
      Rails.logger.error "[SmsService] Full SMS settings: #{sms_settings.inspect}"
      return { success: false, error: 'SMS from number not configured' }
    end
    
    # Initialize Twilio client
    twilio_client = build_twilio_client
    
    unless twilio_client
      return { success: false, error: 'Twilio credentials not configured' }
    end
    
    begin
      message = twilio_client.messages.create(
        from: from_number,
        to: normalize_phone(to),
        body: body
      )
      
      Rails.logger.info "[SmsService] SMS sent successfully - SID: #{message.sid}"
      
      { success: true, message_sid: message.sid }
    rescue Twilio::REST::RestError => e
      Rails.logger.error "[SmsService] Twilio error: #{e.message}"
      { success: false, error: e.message }
    rescue => e
      Rails.logger.error "[SmsService] SMS send error: #{e.message}"
      { success: false, error: e.message }
    end
  end
  
  private
  
  # Decrypt encrypted setting values
  # Values stored as "encrypted:DATA--IV--AUTH_TAG" need to be decrypted
  # Uses the same encryption method as settings_controller.rb
  def decrypt_value(value)
    return value unless value.is_a?(String) && value.start_with?('encrypted:')
    
    Rails.logger.info "[SmsService] Attempting to decrypt value starting with: #{value[0..30]}..."
    
    # Remove "encrypted:" prefix
    encrypted_data = value.sub(/^encrypted:/, '')
    
    Rails.logger.info "[SmsService] Encrypted data (first 50 chars): #{encrypted_data[0..50]}"
    
    # Use the SAME encryption method as settings_controller.rb
    # Key must be generated using KeyGenerator, not truncated
    secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
    key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
    crypt = ActiveSupport::MessageEncryptor.new(key)
    
    begin
      decrypted = crypt.decrypt_and_verify(encrypted_data)
      Rails.logger.info "[SmsService] Successfully decrypted value (length: #{decrypted.to_s.length})"
      decrypted
    rescue => e
      Rails.logger.error "[SmsService] Decryption failed - Exception class: #{e.class.name}"
      Rails.logger.error "[SmsService] Decryption failed - Message: #{e.message}"
      Rails.logger.error "[SmsService] Decryption failed - Backtrace: #{e.backtrace.first(3).join(', ')}"
      
      # Return original if decrypt fails (shouldn't happen now)
      value
    end
  end
  
  # Recursively decrypt all encrypted values in a hash
  def decrypt_hash(hash)
    return hash unless hash.is_a?(Hash)
    
    hash.each_with_object({}) do |(key, value), result|
      result[key] = if value.is_a?(Hash)
        decrypt_hash(value)
      elsif value.is_a?(String) && value.start_with?('encrypted:')
        decrypt_value(value)
      else
        value
      end
    end
  end
  
  # Resolve SMS settings using three-tier inheritance
  # Priority: Location → Company → Platform
  # Reads directly from Settings table to preserve nested structure
  def resolve_sms_settings
    # Try location settings first
    if @location.present?
      location_settings = Setting.find_by(scope_type: 'Location', scope_id: @location.id, key: 'communications')
      if location_settings&.value.present?
        # Parse JSON string to Hash if needed
        comm_settings = location_settings.value.is_a?(String) ? JSON.parse(location_settings.value) : location_settings.value
        # Decrypt any encrypted values
        comm_settings = decrypt_hash(comm_settings)
        if comm_settings['sms'].present?
          Rails.logger.info "[SmsService] Using Location SMS settings"
          return comm_settings['sms']
        end
      end
    end
    
    # Try company settings
    if @company.present?
      company_settings = Setting.find_by(scope_type: 'Company', scope_id: @company.id, key: 'communications')
      if company_settings&.value.present?
        # Parse JSON string to Hash if needed
        comm_settings = company_settings.value.is_a?(String) ? JSON.parse(company_settings.value) : company_settings.value
        # Decrypt any encrypted values
        comm_settings = decrypt_hash(comm_settings)
        if comm_settings['sms'].present?
          Rails.logger.info "[SmsService] Using Company SMS settings"
          return comm_settings['sms']
        end
      end
    end
    
    # Fall back to platform settings
    platform_settings = Setting.find_by(scope_type: 'Platform', scope_id: 0, key: 'communications')
    if platform_settings&.value.present?
      # Parse JSON string to Hash if needed
      comm_settings = platform_settings.value.is_a?(String) ? JSON.parse(platform_settings.value) : platform_settings.value
      Rails.logger.info "[SmsService] Platform settings comm_settings class: #{comm_settings.class}"
      Rails.logger.info "[SmsService] Platform settings comm_settings keys: #{comm_settings.keys.inspect}"
      
      # Decrypt any encrypted values
      comm_settings = decrypt_hash(comm_settings)
      Rails.logger.info "[SmsService] After decryption - twilioAuthToken: #{comm_settings['sms']['twilioAuthToken'][0..10]}..." if comm_settings['sms']['twilioAuthToken'].present?
      
      if comm_settings['sms'].present?
        Rails.logger.info "[SmsService] Using Platform SMS settings"
        Rails.logger.info "[SmsService] Platform SMS keys: #{comm_settings['sms'].keys.inspect}"
        return comm_settings['sms']
      else
        Rails.logger.error "[SmsService] Platform has no 'sms' key. Keys: #{comm_settings.keys.inspect}"
      end
    else
      Rails.logger.error "[SmsService] Platform settings not found or value blank"
    end
    
    Rails.logger.error "[SmsService] No SMS settings found at any level"
    {}
  rescue => e
    Rails.logger.error "[SmsService] Error resolving SMS settings: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    {}
  end
  
  # Build Twilio client with credentials from database settings
  # NO fallback to Rails.application.credentials - all config comes from database
  def build_twilio_client
    # Check for credentials in multiple key formats
    # Flat structure uses: sms_account_sid, sms_auth_token
    # Nested structure uses: twilioAccountSid, twilioAuthToken, accountSid, authToken
    account_sid = sms_settings['twilioAccountSid'] || 
                  sms_settings[:twilioAccountSid] ||
                  sms_settings['accountSid'] || 
                  sms_settings[:accountSid] || 
                  sms_settings['account_sid'] ||
                  sms_settings[:account_sid] ||
                  sms_settings['sms_account_sid'] ||
                  sms_settings[:sms_account_sid]
    
    auth_token = sms_settings['twilioAuthToken'] ||
                 sms_settings[:twilioAuthToken] ||
                 sms_settings['authToken'] || 
                 sms_settings[:authToken] ||
                 sms_settings['auth_token'] ||
                 sms_settings[:auth_token] ||
                 sms_settings['sms_auth_token'] ||
                 sms_settings[:sms_auth_token]
    
    unless account_sid.present? && auth_token.present?
      Rails.logger.error "[SmsService] Twilio credentials not configured in database settings"
      Rails.logger.error "[SmsService] Available SMS setting keys: #{sms_settings.keys.inspect}"
      return nil
    end
    
    Rails.logger.info "[SmsService] Initializing Twilio client with account SID: #{account_sid[0..10]}..."
    
    Twilio::REST::Client.new(account_sid, auth_token)
  rescue => e
    Rails.logger.error "[SmsService] Error building Twilio client: #{e.message}"
    nil
  end
  
  # Normalize phone number to E.164 format
  def normalize_phone(phone)
    # Remove all non-digits
    digits = phone.gsub(/\D/, '')
    
    # Add +1 if it's a 10-digit US number
    if digits.length == 10
      "+1#{digits}"
    elsif digits.length == 11 && digits.start_with?('1')
      "+#{digits}"
    else
      "+#{digits}"
    end
  end
  
  # Invoice notification template
  def invoice_template(invoice)
    company_name = invoice.company.name
    invoice_number = invoice.invoice_number
    amount = format_currency(invoice.total)
    due_date = invoice.due_date&.strftime('%m/%d/%Y')
    payment_link = invoice.payment_url
    
    message = "#{company_name}: Invoice #{invoice_number} for #{amount}"
    message += " is due #{due_date}." if due_date
    message += " Pay online: #{payment_link}"
    
    message
  end
  
  # Payment receipt template
  def payment_receipt_template(invoice, payment)
    company_name = invoice.company.name
    invoice_number = invoice.invoice_number
    amount = format_currency(payment.amount)
    
    "#{company_name}: Payment of #{amount} received for Invoice #{invoice_number}. Thank you!"
  end
  
  # Format currency for SMS (no cents if whole dollar)
  def format_currency(amount)
    if amount % 1 == 0
      "$#{amount.to_i}"
    else
      "$#{'%.2f' % amount}"
    end
  end
end
