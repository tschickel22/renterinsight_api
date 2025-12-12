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

        # Get contact (buyer) and their location
        contact = buyer_access.buyer
        
        unless contact
          # Return platform branding only if no contact
          platform_branding = get_platform_branding
          return render json: {
            branding: platform_branding
          }
        end

        company = contact.company
        location = contact.location # Contact's assigned location

        Rails.logger.info "🏪 [Portal] Contact: #{contact.id} - #{contact.full_name}"
        Rails.logger.info "🏪 [Portal] Company: #{company.id} - #{company.name}"
        Rails.logger.info "🏪 [Portal] Location: #{location&.id} - #{location&.name}"

        # Get merged branding (platform defaults + company overrides + location overrides)
        branding_data = serialize_branding(company, location)

        render json: {
          branding: branding_data,
          company: {
            id: company.id,
            name: company.name
          },
          location: location ? {
            id: location.id,
            name: location.name
          } : nil
        }
      rescue => e
        Rails.logger.error "Portal branding error: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
        render json: { 
          error: 'Failed to load branding',
          details: Rails.env.development? ? e.message : nil
        }, status: :internal_server_error
      end

      private

      def serialize_branding(company, location = nil)
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
        
        # Get location branding if location provided
        location_branding = {}
        if location.present?
          Rails.logger.info "🏪 [Portal] Loading location branding for Location #{location.id} (#{location.name})"
          # Use location's resolved branding which includes the full waterfall
          location_resolved = location.resolved_branding_settings || {}
          location_branding = location_resolved.deep_symbolize_keys
          Rails.logger.info "🏪 [Portal] Location resolved branding: #{location_branding.inspect}"
        end
        
        # Merge: defaults < platform < company < location (location takes highest priority)
        merged_branding = default_branding
          .merge(platform_branding)
          .merge(company_branding)
          .merge(location_branding)
        
        Rails.logger.info "🏪 [Portal] Merged branding: #{merged_branding.inspect}"
        
        # Normalize keys to camelCase for frontend
        # Frontend expects: logo, favicon, portalLogo, primaryColor, etc.
        normalized_branding = {
          primaryColor: merged_branding[:primary_color] || merged_branding[:primaryColor],
          secondaryColor: merged_branding[:secondary_color] || merged_branding[:secondaryColor],
          sideMenuColor: merged_branding[:side_menu_color] || merged_branding[:sideMenuColor],
          fontFamily: merged_branding[:font_family] || merged_branding[:fontFamily],
          # Try both snake_case and camelCase for logo/favicon
          logo: merged_branding[:logo_url] || merged_branding[:logo],
          # CRITICAL: Check location logo_url FIRST before company portalLogo
          portalLogo: merged_branding[:logo_url] || merged_branding[:portal_logo] || merged_branding[:portalLogo] || merged_branding[:logo],
          favicon: merged_branding[:favicon_url] || merged_branding[:favicon],
          portalName: merged_branding[:portal_name] || merged_branding[:portalName]
        }.compact
        
        Rails.logger.info "🏪 [Portal] Normalized (before URLs): logo=#{normalized_branding[:logo]}, favicon=#{normalized_branding[:favicon]}"
        
        # Convert logo URLs from relative to absolute
        if normalized_branding[:logo].present?
          normalized_branding[:logo] = absolute_url(normalized_branding[:logo])
          Rails.logger.info "🏪 [Portal] Logo absolute URL: #{normalized_branding[:logo]}"
        end
        
        if normalized_branding[:portalLogo].present?
          normalized_branding[:portalLogo] = absolute_url(normalized_branding[:portalLogo])
          Rails.logger.info "🏪 [Portal] Portal logo absolute URL: #{normalized_branding[:portalLogo]}"
        end
        
        if normalized_branding[:favicon].present?
          normalized_branding[:favicon] = absolute_url(normalized_branding[:favicon])
          Rails.logger.info "🏪 [Portal] Favicon absolute URL: #{normalized_branding[:favicon]}"
        end
        
        # Include platformLogo separately for reference
        if platform_branding[:logo].present?
          normalized_branding[:platformLogo] = absolute_url(platform_branding[:logo])
        end
        
        Rails.logger.info "🏪 [Portal] Final branding sent: #{normalized_branding.inspect}"
        
        normalized_branding
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
