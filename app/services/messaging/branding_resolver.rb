module Messaging
  # Resolves branding for the email header. Cascade:
  #   recipient's location (if any) → campaign's location (if any) → company
  # Missing fields at each level fall through to the next. `logo` is the JSONB
  # key on branding_settings; there is no dedicated `logo_url` column.
  #
  # Location.resolved_branding_settings already does field-by-field cascade
  # to Company + Platform defaults, so we only need to pick the right
  # starting Location and then guarantee a company-name fallback.
  class BrandingResolver
    PLATFORM_PRIMARY   = '#3b82f6'.freeze
    PLATFORM_SECONDARY = '#111827'.freeze

    def initialize(recipient:, campaign:, company:)
      @recipient = recipient
      @campaign  = campaign
      @company   = company
    end

    def resolve
      location = pick_location
      raw = location&.resolved_branding_settings || company_branding
      raw = raw.is_a?(Hash) ? raw : {}

      name    = location&.name.presence || @company.name
      phone   = location&.phone.presence || @company.try(:phone)
      address = location&.full_address.presence || company_full_address

      {
        logo_url:        raw['logo'].presence,
        primary_color:   raw['primaryColor'].presence   || PLATFORM_PRIMARY,
        secondary_color: raw['secondaryColor'].presence || PLATFORM_SECONDARY,
        name:            name,
        phone:           phone,
        address:         address
      }
    end

    private

    # Recipient's location wins so multi-location "All" sends show each
    # recipient THEIR dealership; falls back to campaign-scoped location for
    # single-location campaigns; falls back to company for orphans.
    def pick_location
      rec_loc = @recipient.respond_to?(:location) ? @recipient.location : nil
      rec_loc || @campaign.try(:location)
    end

    def company_branding
      raw = Setting.get('Company', @company.id, 'branding') || @company.try(:branding_settings) || {}
      normalize_keys(raw)
    end

    # branding_settings historically stored camelCase in some tenants and
    # snake_case in others — LocationSettingsResolver#normalize_branding_keys
    # handles this for locations but Company#branding_settings does not.
    def normalize_keys(hash)
      return {} unless hash.is_a?(Hash)
      hash.each_with_object({}) do |(k, v), acc|
        key = k.to_s
        acc[key] = v
        acc['logo']           ||= v if key == 'logo_url'
        acc['primaryColor']   ||= v if key == 'primary_color'
        acc['secondaryColor'] ||= v if key == 'secondary_color'
      end
    end

    def company_full_address
      parts = [
        @company.try(:address_line1),
        @company.try(:address_line2),
        @company.try(:city),
        @company.try(:state),
        @company.try(:zip_code)
      ].map(&:presence).compact
      parts.any? ? parts.join(', ') : nil
    end
  end
end
