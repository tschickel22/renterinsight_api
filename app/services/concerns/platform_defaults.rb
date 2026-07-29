# frozen_string_literal: true

# Platform-wide default settings for all companies and locations
# These serve as the base layer in the three-tier inheritance model:
# Location → Company → Platform
#
# This module reads actual platform settings from the database via PlatformSetting
# rather than using hardcoded values
module PlatformDefaults
  # Default branding settings from database or fallback to hardcoded
  def self.branding_settings
    db_branding = PlatformSetting.branding
    # JSON.parse returns string keys, default methods return symbol keys
    
    {
      'primary_color' => db_branding['primaryColor'] || db_branding[:primaryColor] || '#3b82f6',
      'secondary_color' => db_branding['secondaryColor'] || db_branding[:secondaryColor] || '#8b5cf6',
      'font_family' => db_branding['fontFamily'] || db_branding[:fontFamily] || 'Inter',
      'side_menu_color' => db_branding['sideMenuColor'] || db_branding[:sideMenuColor],
      'logo_url' => db_branding['logo'] || db_branding[:logo],
      'favicon_url' => nil
    }
  rescue => e
    Rails.logger.error "Error loading platform branding settings: #{e.message}"
    {
      'primary_color' => '#3b82f6',
      'secondary_color' => '#8b5cf6',
      'font_family' => 'Inter',
      'side_menu_color' => nil,
      'logo_url' => nil,
      'favicon_url' => nil
    }
  end

  # Default communication settings from database or fallback to hardcoded
  def self.communication_settings
    db_comms = PlatformSetting.communications
    # JSON.parse returns string keys, default methods return symbol keys
    email_settings = db_comms['email'] || db_comms[:email] || {}
    sms_settings = db_comms['sms'] || db_comms[:sms] || {}
    
    # Debug logging
    Rails.logger.info "PlatformDefaults.communication_settings - DB Communications: #{db_comms.inspect}"
    Rails.logger.info "PlatformDefaults.communication_settings - Email Settings: #{email_settings.inspect}"
    
    # Normalize provider to lowercase for consistency
    # Check string keys first (from database), then symbol keys (from defaults)
    email_provider = (email_settings['provider'] || email_settings[:provider] || 'sendgrid').to_s.downcase
    sms_provider = (sms_settings['provider'] || sms_settings[:provider] || 'twilio').to_s.downcase
    
    result = {
      'smtp_provider' => email_provider,
      'smtp_from_email' => email_settings['fromEmail'] || email_settings[:fromEmail] || Brand.from_email,
      'smtp_from_name' => email_settings['fromName'] || email_settings[:fromName] || Brand.from_name,
      'smtp_host' => email_settings['smtpHost'] || email_settings[:smtpHost],
      'smtp_port' => email_settings['smtpPort'] || email_settings[:smtpPort],
      'smtp_username' => email_settings['smtpUsername'] || email_settings[:smtpUsername],
      'smtp_api_key' => nil, # Never expose API keys
      'sms_provider' => sms_provider,
      'sms_from_number' => sms_settings['fromNumber'] || sms_settings[:fromNumber],
      'sms_api_key' => nil, # Never expose API keys
      'sms_api_secret' => nil # Never expose API secrets
    }
    
    Rails.logger.info "PlatformDefaults.communication_settings - Result: #{result.inspect}"
    result
  rescue => e
    Rails.logger.error "Error loading platform communication settings: #{e.message}"
    {
      'smtp_provider' => 'sendgrid',
      'smtp_from_email' => Brand.from_email,
      'smtp_from_name' => Brand.from_name,
      'smtp_host' => nil,
      'smtp_port' => nil,
      'smtp_username' => nil,
      'smtp_api_key' => nil,
      'sms_provider' => 'twilio',
      'sms_from_number' => nil,
      'sms_api_key' => nil,
      'sms_api_secret' => nil
    }
  end

  # Default operational settings
  def self.operational_settings
    {
      'timezone' => 'America/New_York',
      'business_hours' => {
        'monday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
        'tuesday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
        'wednesday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
        'thursday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
        'friday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false },
        'saturday' => { 'open' => '10:00', 'close' => '14:00', 'closed' => true },
        'sunday' => { 'open' => '00:00', 'close' => '00:00', 'closed' => true }
      },
      'delivery_radius_miles' => 50,
      'allow_weekend_delivery' => false,
      'require_appointment' => true
    }
  end

  # Default integration settings
  def self.integration_settings
    {
      'zoho' => {
        'enabled' => false,
        'api_key' => nil,
        'region' => 'com',
        'sync_enabled' => false
      },
      'mh_village' => {
        'enabled' => false,
        'api_key' => nil,
        'auto_sync' => false
      },
      'zillow' => {
        'enabled' => false,
        'api_key' => nil,
        'auto_sync' => false
      }
    }
  end
end
