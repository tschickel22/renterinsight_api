# frozen_string_literal: true

module Api
  module V1
    class CompanySettingsController < ApplicationController
      before_action :authorize_company_admin!

      # GET /api/v1/company_settings/operational
      def show_operational
        # Use .presence to return nil if empty/blank, not empty hash
        settings = current_company.operational_settings.presence
        
        render json: {
          operational_settings: settings,
          defaults: PlatformDefaults.operational_settings
        }
      end

      # PATCH /api/v1/company_settings/operational
      def update_operational
        Rails.logger.info "🔧 [CompanySettings#update_operational] Received params: #{params.inspect}"
        Rails.logger.info "🔧 [CompanySettings#update_operational] Company: #{current_company&.name} (ID: #{current_company&.id})"
        
        settings = params[:operational_settings] || {}
        Rails.logger.info "📊 [CompanySettings#update_operational] Operational settings: #{settings.inspect}"
        
        current_company.operational_settings = settings
        
        if current_company.save
          Rails.logger.info "✅ [CompanySettings#update_operational] Settings saved successfully"
          render json: {
            operational_settings: current_company.operational_settings,
            message: 'Operational settings updated successfully'
          }
        else
          Rails.logger.error "❌ [CompanySettings#update_operational] Save failed: #{current_company.errors.full_messages}"
          render json: {
            errors: current_company.errors.full_messages
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating operational settings: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
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
        
        if current_company.save
          render json: {
            branding_settings: current_company.branding_settings,
            message: 'Branding settings updated successfully'
          }
        else
          render json: {
            errors: current_company.errors.full_messages
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating branding settings: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
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
        
        if current_company.save
          render json: {
            communication_settings: current_company.communications_settings,
            message: 'Communication settings updated successfully'
          }
        else
          render json: {
            errors: current_company.errors.full_messages
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating communication settings: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # PATCH /api/v1/company_settings/rbac
      def update_rbac
        Rails.logger.info "🔐 [CompanySettings#update_rbac] Received params: #{params.inspect}"
        
        use_rbac = params[:use_rbac_system]
        
        if use_rbac.nil?
          render json: { error: 'use_rbac_system parameter is required' }, status: :bad_request
          return
        end
        
        current_company.use_rbac_system = ActiveModel::Type::Boolean.new.cast(use_rbac)
        
        if current_company.save
          Rails.logger.info "✅ [CompanySettings#update_rbac] RBAC #{current_company.use_rbac_system ? 'enabled' : 'disabled'} for company #{current_company.name}"
          render json: {
            use_rbac_system: current_company.use_rbac_system,
            message: "RBAC system #{current_company.use_rbac_system ? 'enabled' : 'disabled'} successfully"
          }
        else
          Rails.logger.error "❌ [CompanySettings#update_rbac] Failed to update: #{current_company.errors.full_messages}"
          render json: {
            errors: current_company.errors.full_messages
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating RBAC setting: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      private

      def current_company
        @current_company ||= ::Company.find_by(id: current_company_id)
      end

      def authorize_company_admin!
        unless current_user
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end

        unless current_company
          render json: { error: 'Company not found' }, status: :not_found
          return
        end

        # Platform admins can manage any company (via proxy)
        return if current_user.admin? || current_user.super_admin?

        # Company users can only manage their own company
        unless current_user.company_id == current_company.id
          render json: { error: 'Forbidden - You can only manage your own company settings' }, status: :forbidden
          return
        end
      end
    end
  end
end
