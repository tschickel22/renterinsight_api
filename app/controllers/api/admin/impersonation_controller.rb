# frozen_string_literal: true

module Api
  module Admin
    class ImpersonationController < ApplicationController
      before_action :authenticate_user!
      before_action :require_platform_admin!
      before_action :set_company_scope
      
      ALLOWED_BUYER_TYPES = %w[Lead Contact].freeze

      # POST /api/admin/impersonate
      # Body: { buyer_id: 123, buyer_type: 'Lead' }
      def create
        buyer_type = params[:buyer_type] || 'Lead'
        buyer_id = params[:buyer_id]

        unless buyer_id.present?
          return render json: { error: 'buyer_id is required' }, status: :bad_request
        end

        unless ALLOWED_BUYER_TYPES.include?(buyer_type)
          return render json: { error: "Invalid buyer_type. Must be one of: #{ALLOWED_BUYER_TYPES.join(', ')}" }, status: :bad_request
        end

        buyer = find_scoped_buyer(buyer_type, buyer_id)
        unless buyer
          return render json: { error: "#{buyer_type} not found in your company" }, status: :not_found
        end

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

        token = JWT.encode(
          {
            buyer_id: buyer.id,
            buyer_type: buyer_type,
            exp: 24.hours.from_now.to_i,
            impersonated: true,
            impersonated_by: current_user.id,
            company_id: @company.id
          },
          Rails.application.secret_key_base,
          'HS256'
        )

        Rails.logger.info "[IMPERSONATION] User ##{current_user.id} (#{current_user.email}) impersonating #{buyer_type} ##{buyer_id} (#{buyer.email}) for Company ##{@company.id}"

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
      # List buyers with portal access for impersonation (scoped to company)
      def buyers
        portal_accesses = company_scoped_portal_accesses.includes(:buyer).order(created_at: :desc)

        buyers_list = portal_accesses.map do |pa|
          buyer = pa.buyer
          next unless buyer
          
          {
            id: buyer.id,
            type: buyer.class.name,
            email: pa.email,
            name: buyer.respond_to?(:full_name) ? buyer.full_name : 'N/A',
            portal_enabled: pa.portal_enabled,
            created_at: pa.created_at,
            last_login_at: pa.last_login_at
          }
        end.compact

        render json: {
          buyers: buyers_list,
          total: buyers_list.length,
          message: 'Use buyer_id and buyer_type to impersonate any buyer'
        }, status: :ok
      end

      private

      def find_scoped_buyer(buyer_type, buyer_id)
        case buyer_type
        when 'Lead'
          @company.leads.find_by(id: buyer_id)
        when 'Contact'
          @company.contacts.find_by(id: buyer_id)
        end
      end

      def company_scoped_portal_accesses
        lead_ids = @company.leads.pluck(:id)
        contact_ids = @company.contacts.pluck(:id)

        BuyerPortalAccess.where(
          "(buyer_type = 'Lead' AND buyer_id IN (?)) OR (buyer_type = 'Contact' AND buyer_id IN (?))",
          lead_ids,
          contact_ids
        )
      end
    end
  end
end
