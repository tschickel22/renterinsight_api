# frozen_string_literal: true

module Api
  module Admin
    class ImpersonationController < ApplicationController
      # Admin-only endpoint to generate a portal token for any buyer
      # USE FOR TESTING ONLY - Add proper admin authentication in production
      
      # POST /api/admin/impersonate
      # Body: { buyer_id: 123, buyer_type: 'Lead' }
      def create
        buyer_type = params[:buyer_type] || 'Lead'
        buyer_id = params[:buyer_id]

        unless buyer_id.present?
          return render json: { error: 'buyer_id is required' }, status: :bad_request
        end

        # Find the buyer
        buyer = buyer_type.constantize.find_by(id: buyer_id)
        unless buyer
          return render json: { error: "#{buyer_type} not found" }, status: :not_found
        end

        # Find or create portal access
        portal_access = BuyerPortalAccess.find_or_initialize_by(
          buyer: buyer,
          email: buyer.email
        )

        if portal_access.new_record?
          portal_access.assign_attributes(
            portal_enabled: true,
            email_opt_in: true,
            sms_opt_in: false,
            marketing_opt_in: false
          )
          portal_access.save!
        end

        # Generate JWT token
        token = JWT.encode(
          {
            buyer_id: buyer.id,
            buyer_type: buyer_type,
            exp: 24.hours.from_now.to_i,
            impersonated: true # Mark as impersonation for logging
          },
          Rails.application.secret_key_base,
          'HS256'
        )

        Rails.logger.info "[IMPERSONATION] Admin impersonating #{buyer_type} ##{buyer_id} (#{buyer.email})"

        render json: {
          token: token,
          buyer: {
            id: buyer.id,
            type: buyer_type,
            email: buyer.email,
            name: buyer.respond_to?(:full_name) ? buyer.full_name : nil
          },
          portal_access: {
            id: portal_access.id,
            portal_enabled: portal_access.portal_enabled,
            email_opt_in: portal_access.email_opt_in,
            sms_opt_in: portal_access.sms_opt_in
          },
          portal_url: ENV.fetch('PORTAL_URL', 'http://localhost:3001'),
          message: 'Impersonation token generated. Use this token in Authorization header for portal API calls.'
        }, status: :ok
      end

      # GET /api/admin/impersonate/buyers
      # List all buyers with portal access for easy impersonation
      def buyers
        portal_accesses = BuyerPortalAccess.includes(:buyer).order(created_at: :desc)

        buyers_list = portal_accesses.map do |pa|
          buyer = pa.buyer
          {
            id: buyer.id,
            type: buyer.class.name,
            email: pa.email,
            name: buyer.respond_to?(:full_name) ? buyer.full_name : 'N/A',
            portal_enabled: pa.portal_enabled,
            created_at: pa.created_at,
            last_login_at: pa.last_login_at
          }
        end

        render json: {
          buyers: buyers_list,
          total: buyers_list.length,
          message: 'Use buyer_id and buyer_type to impersonate any buyer'
        }, status: :ok
      end
    end
  end
end
