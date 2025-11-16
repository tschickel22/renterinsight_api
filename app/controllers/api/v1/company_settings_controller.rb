# frozen_string_literal: true

module Api
  module V1
    class CompanySettingsController < ApplicationController
      before_action :authorize_company_admin!

      # GET /api/v1/company_settings/operational
      def show_operational
        settings = current_company.operational_settings || {}
        
        render json: {
          operational_settings: settings,
          defaults: PlatformDefaults.operational_settings
        }
      end

      # PATCH /api/v1/company_settings/operational
      def update_operational
        settings = params[:operational_settings] || {}
        
        current_company.operational_settings = settings
        
        render json: {
          operational_settings: current_company.operational_settings,
          message: 'Operational settings updated successfully'
        }
      rescue => e
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # GET /api/v1/company_settings/branding
      def show_branding
        settings = current_company.branding_settings || {}
        
        render json: {
          branding_settings: settings,
          defaults: PlatformDefaults.branding_settings
        }
      end

      # PATCH /api/v1/company_settings/branding
      def update_branding
        settings = params[:branding_settings] || {}
        
        current_company.branding_settings = settings
        
        render json: {
          branding_settings: current_company.branding_settings,
          message: 'Branding settings updated successfully'
        }
      rescue => e
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # GET /api/v1/company_settings/communication
      def show_communication
        settings = current_company.communications_settings || {}
        
        render json: {
          communication_settings: settings,
          defaults: PlatformDefaults.communication_settings
        }
      end

      # PATCH /api/v1/company_settings/communication
      def update_communication
        settings = params[:communication_settings] || {}
        
        current_company.communications_settings = settings
        
        render json: {
          communication_settings: current_company.communications_settings,
          message: 'Communication settings updated successfully'
        }
      rescue => e
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      private

      def current_company
        @current_company ||= ::Company.find_by(id: current_company_id)
      end

      def authorize_company_admin!
        unless current_user&.admin?
          render json: { error: 'Admin access required' }, status: :forbidden
        end
      end
    end
  end
end
