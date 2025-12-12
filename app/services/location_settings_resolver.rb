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
    platform_branding = Setting.get('Platform', 0, 'branding') || {}
    company_branding = Setting.get('Company', @company.id, 'branding') || {}
    location_branding = normalize_branding_keys(@location.branding_settings || {})

    # Log the resolution process
    Rails.logger.info "🎨 [LocationSettingsResolver] Resolving branding for Location #{@location.id} (#{@location.name})"
    Rails.logger.info "  📦 Platform branding: #{platform_branding.inspect}"
    Rails.logger.info "  🏢 Company branding: #{company_branding.inspect}"
    Rails.logger.info "  📍 Location branding: #{location_branding.inspect}"
    
    # Merge with priority: Location > Company > Platform
    resolved = platform_branding.deep_merge(company_branding).deep_merge(location_branding)
    
    Rails.logger.info "  ✅ Resolved branding: #{resolved.inspect}"
    
    resolved
  end

  def resolved_communication_settings
    platform_communication = Setting.get('Platform', 0, 'communication') || {}
    company_communication = Setting.get('Company', @company.id, 'communication') || {}
    location_communication = @location.communication_settings || {}

    Rails.logger.debug "📞 [LocationSettingsResolver] Resolving communication for Location #{@location.id}"
    
    platform_communication.deep_merge(company_communication).deep_merge(location_communication)
  end

  def resolved_operational_settings
    platform_operational = Setting.get('Platform', 0, 'operational') || {}
    company_operational = @company.operational_settings || {}
    location_operational = @location.operational_settings || {}

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
    company_integration = @company.integration_settings || {}
    location_integration = @location.integration_settings || {}

    Rails.logger.debug "🔌 [LocationSettingsResolver] Resolving integration for Location #{@location.id}"
    
    platform_integration.deep_merge(company_integration).deep_merge(location_integration)
  end

  private

  # Normalize branding setting keys from snake_case to camelCase
  # This ensures location settings override company settings when merged
  def normalize_branding_keys(settings)
    return {} if settings.blank?
    
    # Map snake_case keys to camelCase
    key_map = {
      'primary_color' => 'primaryColor',
      'secondary_color' => 'secondaryColor',
      'side_menu_color' => 'sideMenuColor',
      'font_family' => 'fontFamily',
      'logo_url' => 'logo',  # Map logo_url to logo
      'favicon_url' => 'favicon',  # Map favicon_url to favicon
      'portal_name' => 'portalName',
      'portal_logo' => 'portalLogo'
    }
    
    normalized = {}
    settings.each do |key, value|
      # Use mapped key if exists, otherwise keep original key
      normalized_key = key_map[key.to_s] || key.to_s
      normalized[normalized_key] = value
      
      # CRITICAL: If location sets logo_url, also set it as portalLogo
      # This ensures location logo overrides company's portalLogo
      if key.to_s == 'logo_url'
        normalized['portalLogo'] = value
      end
    end
    
    Rails.logger.info "  🔧 [LocationSettingsResolver] Normalized location keys: #{settings.keys} → #{normalized.keys}"
    
    normalized
  end
end
