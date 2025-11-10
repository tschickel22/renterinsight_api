# frozen_string_literal: true

module Api
  module Portal
    class SettingsController < ApplicationController
      # Skip standard authentication - portal has its own
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!

      # GET /api/portal/settings/branding
      def branding
        buyer_access = current_portal_buyer
        
        unless buyer_access
          return render json: { 
            error: 'Authentication required'
          }, status: :unauthorized
        end

        # Get company from buyer's contact
        company = buyer_access.buyer&.company
        
        unless company
          # Return platform branding only if no company
          platform_branding = get_platform_branding
          return render json: {
            branding: platform_branding
          }
        end

        # Get merged branding (platform defaults + company overrides)
        branding_data = serialize_branding(company)

        render json: {
          branding: branding_data,
          company: {
            id: company.id,
            name: company.name
          }
        }
      rescue => e
        Rails.logger.error "Portal branding error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
        render json: { 
          error: 'Failed to load branding',
          details: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end

      private

      def serialize_branding(company)
        # Get platform branding (fallback/defaults)
        platform_branding = get_platform_branding
        
        default_branding = {
          primaryColor: '#3b82f6',
          secondaryColor: '#64748b',
          fontFamily: 'Inter',
          portalName: 'Customer Portal'
        }

        # Get company branding
        company_branding_raw = Setting.get('Company', company.id, 'branding', {})
        company_branding = company_branding_raw.deep_symbolize_keys
        
        # Merge: defaults < platform < company (company takes highest priority)
        merged_branding = default_branding
          .merge(platform_branding)
          .merge(company_branding)
        
        # Convert logo URLs from relative to absolute
        if merged_branding[:logo].present?
          merged_branding[:logo] = absolute_url(merged_branding[:logo])
        end
        
        if merged_branding[:portalLogo].present?
          merged_branding[:portalLogo] = absolute_url(merged_branding[:portalLogo])
        end
        
        # Include platformLogo separately for reference
        if platform_branding[:logo].present?
          merged_branding[:platformLogo] = absolute_url(platform_branding[:logo])
        end
        
        merged_branding
      end

      def get_platform_branding
        platform_branding_raw = Setting.get('Platform', 0, 'branding', {})
        platform_branding = platform_branding_raw.deep_symbolize_keys
        
        # Add platform name from general settings
        platform_general = Setting.get('Platform', 0, 'general', {})
        platform_branding[:platformName] = platform_general['platformName'] || platform_general[:platformName] || 'RenterInsight'
        
        platform_branding
      end

      def absolute_url(path)
        return path if path.blank?
        return path if path.start_with?('http://', 'https://')
        
        # Get base URL from request or ENV
        base_url = if request.present?
          "#{request.protocol}#{request.host_with_port}"
        else
          ENV['RAILS_API_URL'] || 'https://localhost:3001'
        end
        
        "#{base_url}#{path}"
      end
    end
  end
end
