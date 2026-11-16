# frozen_string_literal: true

module Agreements
  # The dealer's logo for an agreement's `company.logo` merge field: the
  # location's own logo (Location Settings, Branding) when it has one, else the
  # company's (Company Settings, Branding). Never the platform logo: a
  # DealerTide mark printed on a dealer's purchase agreement would be wrong.
  module DealerLogo
    KEY = 'company.logo'

    module_function

    # Returns an absolute URL (or data URI), or nil when neither has a logo.
    def url(company, location_id: nil)
      return nil unless company

      raw = location_id.present? && company.locations.exists?(id: location_id) ? logo_from('Location', location_id) : nil
      absolute(raw.presence || logo_from('Company', company.id))
    end

    # The location an agreement prints for: its own, else its deal's.
    def for_agreement(agreement, deal: nil)
      deal ||= agreement.deal_id.present? ? agreement.company.deals.find_by(id: agreement.deal_id) : nil
      url(agreement.company, location_id: agreement.location_id.presence || deal&.try(:location_id))
    end

    def logo_from(scope_type, scope_id)
      branding = Setting.get(scope_type, scope_id, 'branding', {})
      branding.is_a?(Hash) ? branding['logo'].to_s.strip.presence : nil
    end

    # Old logos were saved as a path on the API ("/uploads/..."); everything
    # since is a full URL.
    def absolute(raw)
      return nil if raw.blank?
      return raw if raw.start_with?('http://', 'https://', 'data:image/')
      return "#{ENV.fetch('RAILS_API_URL', 'https://localhost:3001').chomp('/')}#{raw}" if raw.start_with?('/')

      nil
    end
  end
end
