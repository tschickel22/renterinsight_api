# frozen_string_literal: true

module Api
  module Public
    class InvitationsController < ApplicationController
      # Public endpoints - no authentication required for invitation acceptance
      skip_before_action :authenticate, only: [:verify_token, :accept]
      
      # GET /api/public/invitations/verify?token=xxx
      def verify_token
        token = params[:token]
        
        unless token.present?
          return render json: { 
            success: false,
            error: 'Invitation token is required' 
          }, status: :bad_request
        end
        
        # Use InvitationService to verify the token
        service = InvitationService.new(invited_by: nil)
        result = service.verify_invitation(token)
        
        if result[:valid]
          invitation = result[:invitation]
          
          # Get branding based on invitation type
          company_branding = nil
          
          # For tenant invitations, use PLATFORM branding (not company branding)
          if invitation.invitation_type == 'tenant'
            # Get platform settings
            platform_general = PlatformSetting.general
            platform_branding_settings = PlatformSetting.branding
            
            platform_name = platform_general['platformName'] || platform_general[:platformName] || 'RenterInsight'
            logo_value = platform_branding_settings['logo'] || platform_branding_settings[:logo]
            
            # Convert relative logo URLs to absolute URLs
            frontend_url = ENV['FRONTEND_URL'] || 'https://localhost:5173'
            if logo_value.present?
              if logo_value.start_with?('http://', 'https://')
                logo_url = logo_value
              else
                logo_url = "#{frontend_url}#{logo_value.start_with?('/') ? logo_value : '/' + logo_value}"
              end
            else
              logo_url = nil
            end
            
            company_branding = {
              logo: logo_url,
              primaryColor: platform_branding_settings['primaryColor'] || platform_branding_settings[:primaryColor] || '#3b82f6',
              secondaryColor: platform_branding_settings['secondaryColor'] || platform_branding_settings[:secondaryColor] || '#8b5cf6',
              fontFamily: platform_branding_settings['fontFamily'] || platform_branding_settings[:fontFamily] || 'Inter',
              platformName: platform_name
            }
            
            Rails.logger.info "[TENANT INVITATION] Using platform branding: #{company_branding.inspect}"
          elsif invitation.company
            # For company_user and portal_user, use company branding
            # Get platform name from platform settings
            platform_name = begin
              general_settings = PlatformSetting.general
              general_settings['platformName'] || general_settings[:platformName]
            rescue StandardError => e
              Rails.logger.warn "[INVITATION VERIFY] PlatformSetting error: #{e.message}"
              nil
            end
            platform_name ||= 'Renter Insight DMS'
            
            # Get branding from company settings (stored as JSON)
            branding = invitation.company.branding_settings || {}
            
            Rails.logger.info "[INVITATION BRANDING] Company ID: #{invitation.company.id}, Branding: #{branding.inspect}"
            
            # Convert relative logo URLs to absolute URLs for public pages
            frontend_url = ENV['FRONTEND_URL'] || 'https://localhost:5173'
            logo_value = branding['logo']
            portal_logo_value = branding['portalLogo']
            
            # Convert logo to absolute URL if it's a relative path
            logo_url = if logo_value.present?
              if logo_value.start_with?('http://', 'https://')
                logo_value
              else
                "#{frontend_url}#{logo_value.start_with?('/') ? logo_value : '/' + logo_value}"
              end
            else
              nil
            end
            
            # Convert portal logo to absolute URL if it's a relative path
            portal_logo_url = if portal_logo_value.present?
              if portal_logo_value.start_with?('http://', 'https://')
                portal_logo_value
              else
                "#{frontend_url}#{portal_logo_value.start_with?('/') ? portal_logo_value : '/' + portal_logo_value}"
              end
            else
              nil
            end
            
            company_branding = {
              logo: logo_url,
              portalLogo: portal_logo_url,
              primaryColor: branding['primaryColor'] || '#3b82f6',
              secondaryColor: branding['secondaryColor'] || '#8b5cf6',
              fontFamily: branding['fontFamily'] || 'Inter',
              portalName: branding['portalName'] || 'Customer Portal',
              platformName: platform_name
            }
            
            Rails.logger.info "[INVITATION BRANDING] Sending to frontend: #{company_branding.inspect}"
          end
          
          # Return invitation info for account setup in format frontend expects
          response_data = {
            success: true,
            email: invitation.email,
            phone: invitation.phone,
            recipientName: invitation.recipient_name,
            role: invitation.role,
            companyName: invitation.company&.name,
            expiresAt: invitation.expires_at&.iso8601,
            message: invitation.message,
            invitationType: invitation.invitation_type,
            token: token,
            branding: company_branding
          }
          
          Rails.logger.info "[INVITATION VERIFY] Returning response with branding: #{response_data.to_json}"
          
          render json: response_data
        else
          render json: { 
            success: false,
            error: result[:error] || 'Invalid or expired invitation'
          }, status: :not_found
        end
      rescue InvitationService::InvitationNotFoundError => e
        render json: { 
          success: false,
          error: 'Invalid or expired invitation token' 
        }, status: :not_found
      rescue StandardError => e
        Rails.logger.error "[INVITATION VERIFY] Error: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        
        render json: { 
          success: false,
          error: 'Failed to verify invitation' 
        }, status: :internal_server_error
      end
      
      # POST /api/public/invitations/accept?token=xxx
      def accept
        token = params[:token]
        
        unless token.present?
          return render json: { 
            success: false,
            error: 'Invitation token is required' 
          }, status: :bad_request
        end
        
        # Prepare user parameters
        user_params = {
          first_name: params[:firstName] || params[:first_name],
          last_name: params[:lastName] || params[:last_name],
          name: "#{params[:firstName]} #{params[:lastName]}".strip,
          password: params[:password],
          phone: params[:phone],
          company_name: params[:companyName] || params[:company_name],
          domain: params[:domain]
        }
        
        # Validate required fields
        unless user_params[:password].present?
          return render json: { 
            success: false,
            error: 'Password is required' 
          }, status: :bad_request
        end
        
        unless user_params[:first_name].present? && user_params[:last_name].present?
          return render json: { 
            success: false,
            error: 'First name and last name are required' 
          }, status: :bad_request
        end
        
        # Use InvitationService to accept the invitation
        service = InvitationService.new(invited_by: nil)
        result = service.accept_invitation(
          token: token,
          user_params: user_params,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
        
        if result[:success]
          user = result[:user]
          
          # CRITICAL DEBUG: Log what we're encoding in JWT
          Rails.logger.info "🔐 [JWT GENERATION] User ID: #{user.id}, Email: #{user.email}"
          Rails.logger.info "🔐 [JWT GENERATION] Company ID: #{user.company_id}, Role: #{user.role}"
          Rails.logger.info "🔐 [JWT GENERATION] Company Name: #{user.company&.name}"
          
          # Generate JWT token for immediate login
          jwt_token = JsonWebToken.encode(
            user_id: user.id,
            email: user.email,
            company_id: user.company_id,
            role: user.role
          )
          
          Rails.logger.info "🔐 [JWT GENERATED] Token created for company_id: #{user.company_id}"
          
          render json: {
            success: true,
            message: 'Account activated successfully',
            token: jwt_token,
            user: build_user_response(user)
          }
        else
          render json: { 
            success: false,
            error: result[:error] || 'Failed to accept invitation'
          }, status: :unprocessable_entity
        end
      rescue InvitationService::InvitationNotFoundError => e
        render json: { 
          success: false,
          error: 'Invalid or expired invitation token' 
        }, status: :not_found
      rescue InvitationService::InvitationExpiredError => e
        render json: { 
          success: false,
          error: 'This invitation has expired' 
        }, status: :unprocessable_entity
      rescue InvitationService::InvitationAlreadyAcceptedError => e
        render json: { 
          success: false,
          error: 'This invitation has already been accepted' 
        }, status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error "[INVITATION ACCEPT] Error: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        
        render json: { 
          success: false,
          error: 'Failed to accept invitation' 
        }, status: :internal_server_error
      end
      
      private
      
      # Build consistent user response with company subscription data
      def build_user_response(user)
        company = user.company
        location_data = build_location_data(user, company)
        
        {
          id: user.id,
          email: user.email,
          firstName: user.first_name,
          lastName: user.last_name,
          user_type: determine_user_type(user),
          role: user.role,
          company_id: (user.platform_admin? || user.super_admin?) ? nil : user.company_id,
          companyName: company&.name,
          rbac_enabled: company&.use_rbac_system || false,
          permissions: build_permissions(user, company),
          roles: build_roles(user, company),
          user_tier: location_data[:user_tier],
          location_ids: location_data[:location_ids],
          location_role: location_data[:location_role],
          assigned_locations: location_data[:assigned_locations],
          company: build_company_data(user, company)
        }
      end
      
      # Build company data including subscription and module access
      def build_company_data(user, company)
        return nil if user.platform_admin? || user.super_admin?
        return nil unless company.present?
        
        module_access = company.module_access
        subscription_status = module_access.subscription_status
        
        {
          id: company.id,
          name: company.name,
          enabled_modules: module_access.enabled_modules,
          subscription_status: subscription_status[:status],
          plan_name: subscription_status[:plan_name],
          plan_display_name: subscription_status[:plan_display_name],
          is_active: subscription_status[:is_active],
          is_trial: subscription_status[:is_trial],
          trial_days_remaining: subscription_status[:trial_days_remaining],
          in_grace_period: subscription_status[:in_grace_period],
          max_users: subscription_status.dig(:limits, :max_users),
          max_locations: subscription_status.dig(:limits, :max_locations),
          max_storage_gb: subscription_status.dig(:limits, :max_storage_gb)
        }
      end
      
      # Determine user type
      def determine_user_type(user)
        return 'platform_admin' if user.platform_admin?
        return 'super_admin' if user.super_admin?
        return 'company_admin' if user.company_admin?
        return 'admin' if user.admin?
        return 'client' if user.client?
        return 'staff' if user.staff?
        'staff'
      end
      
      # Build permissions array
      def build_permissions(user, company)
        return ['*:*:*'] if user.platform_admin? || user.super_admin?
        return ['*:*:*'] unless company&.use_rbac_system
        user.permissions_for_company(company.id)
      end
      
      # Build roles array
      def build_roles(user, company)
        return [{ key: 'platform_admin', name: 'Platform Admin', tier: 'platform' }] if user.platform_admin?
        return [{ key: 'super_admin', name: 'Super Admin', tier: 'platform' }] if user.super_admin?
        return [] unless company&.use_rbac_system
        
        user.roles_for_company(company.id).map do |role|
          {
            key: role.key,
            name: role.name,
            tier: role.tier,
            color: role.color
          }
        end
      end
      
      # Build location data
      def build_location_data(user, company)
        return { user_tier: 'platform', location_ids: [], location_role: nil, assigned_locations: [] } if user.platform_admin? || user.super_admin?
        
        user_locations = user.user_locations.active.includes(:location).where(company_id: company&.id)
        
        if user_locations.any?
          location_ids = user_locations.map(&:location_id)
          role_priority = { 'location_admin' => 3, 'location_manager' => 2, 'location_staff' => 1 }
          primary_assignment = user_locations.max_by { |ul| role_priority[ul.location_role] || 0 }
          
          assigned_locations = user_locations.map do |ul|
            {
              id: ul.location_id,
              name: ul.location&.name,
              code: ul.location&.code,
              role: ul.location_role
            }
          end
          
          {
            user_tier: 'location',
            location_ids: location_ids,
            location_role: primary_assignment&.location_role,
            assigned_locations: assigned_locations
          }
        else
          is_company_tier = user.company_admin? || 
                            user.roles_for_company(company&.id).any? { |r| r.tier == 'company' }
          
          {
            user_tier: is_company_tier ? 'company' : 'location',
            location_ids: [],
            location_role: nil,
            assigned_locations: []
          }
        end
      end
    end
  end
end
