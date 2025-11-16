# frozen_string_literal: true

# Resolves settings for locations with three-tier inheritance:
# Location-specific → Company defaults → Platform defaults
class LocationSettingsResolver
  def initialize(location)
    @location = location
    @company = location.company
  end

  def resolved_branding_settings
    platform_defaults = PlatformDefaults.branding_settings
    company_settings = @company.branding_settings || {}
    location_settings = @location.branding_settings || {}

    platform_defaults.deep_merge(company_settings).deep_merge(location_settings)
  end

  def resolved_communication_settings
    platform_defaults = PlatformDefaults.communication_settings
    company_settings = @company.communications_settings || {}
    location_settings = @location.communication_settings || {}

    platform_defaults.deep_merge(company_settings).deep_merge(location_settings)
  end

  def resolved_operational_settings
    platform_defaults = PlatformDefaults.operational_settings
    company_settings = @company.operational_settings || {}
    location_settings = @location.operational_settings || {}

    # Start with platform defaults
    resolved = platform_defaults.deep_merge(company_settings).deep_merge(location_settings)

    # Add timezone and business_hours from location columns if present
    resolved['timezone'] = @location.timezone if @location.timezone.present?
    resolved['business_hours'] = @location.business_hours if @location.business_hours.present?
    resolved['delivery_radius_miles'] = @location.delivery_radius_miles if @location.delivery_radius_miles.present?

    resolved
  end

  def resolved_integration_settings
    platform_defaults = PlatformDefaults.integration_settings
    company_settings = @company.integration_settings || {}
    location_settings = @location.integration_settings || {}

    platform_defaults.deep_merge(company_settings).deep_merge(location_settings)
  end
end
