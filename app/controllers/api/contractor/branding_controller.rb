# frozen_string_literal: true

module Api
  module Contractor
    class BrandingController < BaseController
      # GET /api/contractor/branding
      #
      # Branding is stored in the Settings table (not company.branding_settings column).
      # Keys are camelCase: logo, primaryColor, secondaryColor, favicon, portalLogo, etc.
      # Uses the same hierarchical merge as the main platform: Platform → Company → Location
      def show
        companies_data = all_contractors.includes(:company).map do |c|
          company = c.company
          next unless company

          # Read branding from Settings table (same source as main platform)
          branding = Setting.get('Company', company.id, 'branding', {})
          branding = branding.is_a?(Hash) ? branding.deep_symbolize_keys : {}

          # Also check platform-level branding as fallback
          if branding.empty?
            platform_branding = Setting.get('Platform', 0, 'branding', {})
            branding = platform_branding.is_a?(Hash) ? platform_branding.deep_symbolize_keys : {}
          end

          # Build logo URL - the Settings table stores it under :logo key (camelCase)
          logo = branding[:logo] || branding[:portalLogo]

          # Make relative URLs absolute
          if logo.present? && !logo.start_with?('http')
            api_host = Rails.application.credentials.dig(:app, :api_host) || request.base_url
            logo = "#{api_host}#{logo}"
          end

          {
            company_id: company.id,
            company_name: company.name,
            company_phone: company.phone,
            logo_url: logo,
            primary_color: branding[:primaryColor] || branding[:primary_color],
            secondary_color: branding[:secondaryColor] || branding[:secondary_color]
          }
        end.compact.uniq { |c| c[:company_id] }

        primary = companies_data.find { |c| c[:company_id] == current_contractor.company_id } || companies_data.first || {}

        render json: primary.merge(companies: companies_data)
      end
    end
  end
end
