# frozen_string_literal: true

# Resolves settings for locations with three-tier inheritance:
# Location-specific → Company defaults → Platform defaults
class LocationSettingsResolver
  def initialize(location)
    @location = location
    @company = location.company
  end

  def resolved_branding_settings
    # Get settings from each tier
    platform_branding_raw = Setting.get('Platform', 0, 'branding') || {}
    company_branding_raw = Setting.get('Company', @company.id, 'branding') || {}
    location_branding = normalize_branding_keys(@location.branding_settings || {})

    # Normalize company and platform branding too (they might have camelCase keys)
    platform_branding = normalize_branding_keys(platform_branding_raw)
    company_branding = normalize_branding_keys(company_branding_raw)

    # Log the resolution process
    Rails.logger.info "🎨 [LocationSettingsResolver] Resolving branding for Location #{@location.id} (#{@location.name})"
    Rails.logger.info "  📦 Platform branding (normalized): #{platform_branding.inspect}"
    Rails.logger.info "  🏢 Company branding (normalized): #{company_branding.inspect}"
    Rails.logger.info "  📍 Location branding (normalized): #{location_branding.inspect}"
    
    # Merge with priority: Location > Company > Platform
    resolved = platform_branding.deep_merge(company_branding).deep_merge(location_branding)
    
    Rails.logger.info "  ✅ Resolved branding: #{resolved.inspect}"
    
    resolved
  end

  def resolved_communication_settings
    platform_communication = Setting.get('Platform', 0, 'communications') || {}
    company_communication = Setting.get('Company', @company.id, 'communications') || {}
    location_communication = Setting.get('Location', @location.id, 'communications') || {}

    Rails.logger.debug "📞 [LocationSettingsResolver] Resolving communication for Location #{@location.id}"
    Rails.logger.debug "  Platform: #{platform_communication.inspect}"
    Rails.logger.debug "  Company: #{company_communication.inspect}"
    Rails.logger.debug "  Location: #{location_communication.inspect}"
    
    # Merge settings with cascade
    resolved = platform_communication.deep_merge(company_communication).deep_merge(location_communication)
    
    # Add metadata about where each setting comes from
    resolved['_sources'] = {
      'email' => determine_email_source(location_communication, company_communication, platform_communication),
      'sms' => determine_sms_source(location_communication, company_communication, platform_communication)
    }
    
    resolved
  end
  
  private
  
  def determine_email_source(location, company, platform)
    # Check if location has email configured
    if location.dig('email', 'isEnabled') == true || location.dig('email', 'fromEmail').present? || location.dig('email', 'oauthEmail').present?
      'location'
    # Check if company has email configured
    elsif company.dig('email', 'isEnabled') == true || company.dig('email', 'fromEmail').present? || company.dig('email', 'oauthEmail').present?
      'company'
    # Fall back to platform
    elsif platform.dig('email', 'isEnabled') == true || platform.dig('email', 'fromEmail').present? || platform.dig('email', 'oauthEmail').present?
      'platform'
    else
      'none'
    end
  end
  
  def determine_sms_source(location, company, platform)
    # Check if location has SMS configured
    if location.dig('sms', 'isEnabled') == true || location.dig('sms', 'fromNumber').present?
      'location'
    # Check if company has SMS configured
    elsif company.dig('sms', 'isEnabled') == true || company.dig('sms', 'fromNumber').present?
      'company'
    # Fall back to platform
    elsif platform.dig('sms', 'isEnabled') == true || platform.dig('sms', 'fromNumber').present?
      'platform'
    else
      'none'
    end
  end

  def resolved_operational_settings
    platform_operational = Setting.get('Platform', 0, 'operational') || {}
    company_operational = Setting.get('Company', @company.id, 'operational') || {}
    location_operational = Setting.get('Location', @location.id, 'operational') || {}

    Rails.logger.debug "⚙️ [LocationSettingsResolver] Resolving operational for Location #{@location.id}"
    
    # Start with platform defaults
    resolved = platform_operational.deep_merge(company_operational).deep_merge(location_operational)

    # Add timezone and business_hours from location columns if present
    resolved['timezone'] = @location.timezone if @location.timezone.present?
    resolved['business_hours'] = @location.business_hours if @location.business_hours.present?
    resolved['delivery_radius_miles'] = @location.delivery_radius_miles if @location.delivery_radius_miles.present?

    resolved
  end

  def resolved_integration_settings
    platform_integration = Setting.get('Platform', 0, 'integration') || {}
    company_integration = Setting.get('Company', @company.id, 'integration') || {}
    location_integration = Setting.get('Location', @location.id, 'integration') || {}

    Rails.logger.debug "🔌 [LocationSettingsResolver] Resolving integration for Location #{@location.id}"
    
    platform_integration.deep_merge(company_integration).deep_merge(location_integration)
  end

  private

  # Normalize branding setting keys to consistent format
  # Handles both snake_case (location DB) and camelCase (company/platform Settings)
  # Returns BOTH formats for maximum frontend compatibility
  def normalize_branding_keys(settings)
    return {} if settings.blank?
    
    # Map both snake_case and camelCase variants
    key_map = {
      # Snake case mappings
      'primary_color' => 'primaryColor',
      'secondary_color' => 'secondaryColor',
      'side_menu_color' => 'sideMenuColor',
      'font_family' => 'fontFamily',
      'logo_url' => 'logo',
      'favicon_url' => 'favicon',  # Snake case from location DB
      'portal_name' => 'portalName',
      'portal_logo' => 'portalLogo',
      # CamelCase mappings (for company/platform settings)
      'faviconUrl' => 'favicon',  # CamelCase from company/platform Settings
      'logoUrl' => 'logo'
    }
    
    normalized = {}
    settings.each do |key, value|
      next if value.nil?
      
      # Use mapped key if exists, otherwise keep original key
      normalized_key = key_map[key.to_s] || key.to_s
      normalized[normalized_key] = value
      
      # CRITICAL: Also set snake_case variants for frontend compatibility
      if key.to_s == 'logo_url' || key.to_s == 'logoUrl' || normalized_key == 'logo'
        normalized['logo'] = value
        normalized['logo_url'] = value  # Add snake_case variant
        normalized['portalLogo'] = value  # For portal compatibility
      end
      
      if key.to_s == 'favicon_url' || key.to_s == 'faviconUrl' || normalized_key == 'favicon'
        normalized['favicon'] = value
        normalized['favicon_url'] = value  # Add snake_case variant
      end
    end
    
    Rails.logger.info "  🔧 [LocationSettingsResolver] Normalized keys: #{settings.keys} → #{normalized.keys}"
    
    normalized
  end
end
