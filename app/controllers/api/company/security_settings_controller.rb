# frozen_string_literal: true

module Api
  module Company
    class SecuritySettingsController < ApplicationController
      before_action :authenticate
      before_action :authorize_company_admin!

      # GET /api/company/:company_id/security/settings
      def show
        Rails.logger.info "[SecuritySettings] GET settings for company #{company_id}"
        settings = load_security_settings
        
        render json: {
          success: true,
          settings: settings
        }
      rescue => e
        Rails.logger.error "[SecuritySettings] Error loading settings: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        render json: {
          success: false,
          error: e.message,
          error_class: e.class.to_s
        }, status: :internal_server_error
      end

      # PATCH /api/company/:company_id/security/settings
      def update
        settings = load_security_settings
        updated_settings = settings.merge(security_params)
        
        save_security_settings(updated_settings)
        
        # TODO: Log the change to audit system
        # AuditEvent.create!(
        #   company_id: company_id,
        #   actor_user_id: current_user.id,
        #   resource_type: 'SecuritySettings',
        #   resource_id: company_id,
        #   verb: 'security_settings_update',
        #   metadata: {
        #     updated_fields: security_params.keys,
        #     previous_values: settings.slice(*security_params.keys)
        #   },
        #   occurred_at: Time.current
        # )
        
        render json: {
          success: true,
          settings: updated_settings,
          message: 'Security settings updated successfully'
        }
      rescue => e
        render json: {
          success: false,
          error: e.message
        }, status: :unprocessable_entity
      end

      # GET /api/company/:company_id/security/mfa_stats
      def mfa_stats
        Rails.logger.info "[SecuritySettings] GET MFA stats for company #{company_id}"
        
        # Get users for this company
        users = User.where(company_id: company_id)
        total_users = users.count
        
        # Check if mfa_enabled column exists, otherwise default to 0
        mfa_enabled_count = if User.column_names.include?('mfa_enabled')
          users.where(mfa_enabled: true).count
        else
          0
        end
        
        enrollment_percentage = total_users > 0 ? (mfa_enabled_count.to_f / total_users * 100).round(1) : 0.0
        
        # Get users without MFA
        users_without_mfa = if User.column_names.include?('mfa_enabled')
          users
            .where(mfa_enabled: [false, nil])
            .where(status: 'active')
            .select(:id, :email, :first_name, :last_name, :role)
            .map do |user|
              {
                id: user.id,
                name: "#{user.first_name} #{user.last_name}".strip.presence || user.email,
                email: user.email,
                role: user.role
              }
            end
        else
          # If column doesn't exist, all active users don't have MFA
          users
            .where(status: 'active')
            .select(:id, :email, :first_name, :last_name, :role)
            .map do |user|
              {
                id: user.id,
                name: "#{user.first_name} #{user.last_name}".strip.presence || user.email,
                email: user.email,
                role: user.role
              }
            end
        end
        
        render json: {
          success: true,
          stats: {
            total_users: total_users,
            mfa_enabled_count: mfa_enabled_count,
            enrollment_percentage: enrollment_percentage
          },
          users_without_mfa: users_without_mfa
        }
      rescue => e
        Rails.logger.error "[SecuritySettings] Error loading MFA stats: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        render json: {
          success: false,
          error: e.message,
          error_class: e.class.to_s
        }, status: :internal_server_error
      end

      private

      def company_id
        id = params[:company_id] || params[:id]
        Rails.logger.info "[SecuritySettings] Company ID: #{id}"
        id
      end

      def authorize_company_admin!
        Rails.logger.info "[SecuritySettings] Auth check - User: #{current_user.id}, Current Company: #{current_company_id}, Target Company: #{company_id}, Role: #{current_user.role}"
        
        unless current_company_id.to_s == company_id.to_s && current_user.effective_admin?
          Rails.logger.warn "[SecuritySettings] Authorization failed"
          render json: { 
            success: false,
            error: 'Unauthorized',
            details: 'Must be a company admin to access security settings'
          }, status: :forbidden
        end
      end

      def security_params
        params.require(:settings).permit(
          :mfaRequired,
          :allowWebAuthn,
          :backupCodesEnabled,
          passwordPolicy: [
            :minLength,
            :requireUppercase,
            :requireLowercase,
            :requireNumbers,
            :requireSymbols,
            :preventReuse,
            :maxAge
          ],
          sessionPolicy: [
            :maxIdleMinutes,
            :maxAbsoluteHours,
            :singleSessionOnly,
            :requireMfaForSensitive
          ],
          ipAllowlist: []
        ).to_h.deep_transform_keys { |key| key.to_s.underscore }
      end

      def load_security_settings
        setting = Setting.find_by(
          scope_type: 'Company',
          scope_id: company_id,
          key: 'security_settings'
        )
        
        if setting
          JSON.parse(setting.value).deep_transform_keys { |key| key.to_s.camelize(:lower) }
        else
          default_security_settings
        end
      end

      def save_security_settings(settings)
        # Transform keys to camelCase for storage
        camelized_settings = settings.deep_transform_keys { |key| key.to_s.camelize(:lower) }
        
        setting = Setting.find_or_initialize_by(
          scope_type: 'Company',
          scope_id: company_id,
          key: 'security_settings'
        )
        
        setting.value = camelized_settings.to_json
        setting.save!
      end

      def default_security_settings
        {
          'mfaRequired' => false,
          'allowWebAuthn' => true,
          'backupCodesEnabled' => true,
          'passwordPolicy' => {
            'minLength' => 12,
            'requireUppercase' => true,
            'requireLowercase' => true,
            'requireNumbers' => true,
            'requireSymbols' => true,
            'preventReuse' => 5,
            'maxAge' => 90
          },
          'sessionPolicy' => {
            'maxIdleMinutes' => 60,
            'maxAbsoluteHours' => 24,
            'singleSessionOnly' => false,
            'requireMfaForSensitive' => true
          },
          'ipAllowlist' => []
        }
      end
    end
  end
end
