# frozen_string_literal: true

module Api
  module V1
    class CompanySettingsController < ApplicationController
      before_action :set_company_scope
      
      # RBAC Authorization - map to appropriate resources
      before_action :authorize_settings_read!, only: [:show_operational, :show_communication]
      before_action :authorize_settings_update!, only: [:update_operational, :update_communication, :update_rbac]
      before_action :authorize_branding_read!, only: [:show_branding]
      before_action :authorize_branding_update!, only: [:update_branding]
      before_action :authorize_finance_manage!, only: [:show_loan, :update_loan]

      # GET /api/v1/company_settings/operational
      def show_operational
        settings = @company.operational_settings.presence

        render json: {
          operational_settings: settings,
          defaults: PlatformDefaults.operational_settings
        }
      end

      # PATCH /api/v1/company_settings/operational
      def update_operational
        Rails.logger.info "🔧 [CompanySettings#update_operational] Received params: #{params.inspect}"
        Rails.logger.info "🔧 [CompanySettings#update_operational] Company: #{@company&.name} (ID: #{@company&.id})"

        settings = params[:operational_settings] || {}
        Rails.logger.info "📊 [CompanySettings#update_operational] Operational settings: #{settings.inspect}"

        @company.operational_settings = settings

        if @company.save
          Rails.logger.info "✅ [CompanySettings#update_operational] Settings saved successfully"
          render json: {
            operational_settings: @company.operational_settings,
            message: 'Operational settings updated successfully'
          }
        else
          Rails.logger.error "❌ [CompanySettings#update_operational] Save failed: #{@company.errors.full_messages}"
          render json: {
            errors: @company.errors.full_messages
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
        settings = @company.branding_settings || {}

        render json: {
          branding_settings: settings,
          defaults: PlatformDefaults.branding_settings
        }
      end

      # PATCH /api/v1/company_settings/branding
      def update_branding
        settings = params[:branding_settings] || {}

        @company.branding_settings = settings

        if @company.save
          render json: {
            branding_settings: @company.branding_settings,
            message: 'Branding settings updated successfully'
          }
        else
          render json: {
            errors: @company.errors.full_messages
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
        settings = @company.communications_settings || {}

        render json: {
          communication_settings: settings,
          defaults: PlatformDefaults.communication_settings
        }
      end

      # PATCH /api/v1/company_settings/communication
      def update_communication
        settings = params[:communication_settings] || {}

        @company.communications_settings = settings

        if @company.save
          render json: {
            communication_settings: @company.communications_settings,
            message: 'Communication settings updated successfully'
          }
        else
          render json: {
            errors: @company.errors.full_messages
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

        @company.use_rbac_system = ActiveModel::Type::Boolean.new.cast(use_rbac)

        if @company.save
          Rails.logger.info "✅ [CompanySettings#update_rbac] RBAC #{@company.use_rbac_system ? 'enabled' : 'disabled'} for company #{@company.name}"
          render json: {
            use_rbac_system: @company.use_rbac_system,
            message: "RBAC system #{@company.use_rbac_system ? 'enabled' : 'disabled'} successfully"
          }
        else
          Rails.logger.error "❌ [CompanySettings#update_rbac] Failed to update: #{@company.errors.full_messages}"
          render json: {
            errors: @company.errors.full_messages
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating RBAC setting: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # GET /api/v1/company_settings/loan
      def show_loan
        settings = @company.loan_settings || {}

        render json: {
          loan_settings: settings,
          defaults: default_loan_settings
        }
      end

      # PATCH /api/v1/company_settings/loan
      def update_loan
        Rails.logger.info "💰 [CompanySettings#update_loan] Received params: #{params.inspect}"

        settings = params[:loan_settings] || {}
        Rails.logger.info "📊 [CompanySettings#update_loan] Loan settings: #{settings.inspect}"

        @company.loan_settings = settings

        if @company.save
          Rails.logger.info "✅ [CompanySettings#update_loan] Loan settings saved successfully"
          render json: {
            loan_settings: @company.loan_settings,
            message: 'Loan settings updated successfully'
          }
        else
          Rails.logger.error "❌ [CompanySettings#update_loan] Save failed: #{@company.errors.full_messages}"
          render json: {
            errors: @company.errors.full_messages
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating loan settings: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      private

      # RBAC Authorization Methods for company_settings resource
      def authorize_settings_read!
        return if skip_rbac?
        unless current_user.has_permission?('company_settings', 'read', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied READ access to company_settings for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to view company settings' }, status: :forbidden
        end
      end

      def authorize_settings_update!
        return if skip_rbac?
        unless current_user.has_permission?('company_settings', 'update', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied UPDATE access to company_settings for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to modify company settings' }, status: :forbidden
        end
      end

      # RBAC Authorization Methods for branding resource
      def authorize_branding_read!
        return if skip_rbac?
        unless current_user.has_permission?('branding', 'read', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied READ access to branding for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to view branding settings' }, status: :forbidden
        end
      end

      def authorize_branding_update!
        return if skip_rbac?
        unless current_user.has_permission?('branding', 'update', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied UPDATE access to branding for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to modify branding settings' }, status: :forbidden
        end
      end

      # RBAC Authorization Methods for finance resource
      def authorize_finance_manage!
        return if skip_rbac?
        unless current_user.has_permission?('finance', 'manage', 'all', @company&.id)
          Rails.logger.warn "[RBAC] User #{current_user.id} denied MANAGE access to finance for company #{@company&.id}"
          render json: { error: 'Permission denied: You do not have permission to manage finance settings' }, status: :forbidden
        end
      end

      # Skip RBAC for platform admins or if company doesn't use RBAC
      def skip_rbac?
        return true if current_user.platform_admin?
        return true if current_user.super_admin?
        return true unless @company&.use_rbac_system
        false
      end

      def set_company_scope
        unless current_user
          Rails.logger.error "[CompanySettingsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end

        company_id = current_company_id

        unless company_id.present?
          Rails.logger.error "[CompanySettingsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end

        @company = ::Company.find_by(id: company_id)

        if @company.nil?
          Rails.logger.error "[CompanySettingsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end

        Rails.logger.info "[CompanySettingsController] Company scope set: #{@company.name} (ID: #{@company.id}) for user: #{current_user.email}"
      end

      # Default loan settings
      def default_loan_settings
        {
          default_interest_rate: 6.99,
          max_loan_term: 84,
          min_down_payment_percent: 10,
          default_payment_frequency: 'monthly'
        }
      end
    end
  end
end
