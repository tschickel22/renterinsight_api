# frozen_string_literal: true

module Api
  module Company
    class SettingsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_company_scope

      # GET /api/company/settings
      def show
        render json: {
          communications: fetch_communications_settings(@company),
          notifications: fetch_notifications_settings(@company),
          branding: fetch_branding_settings(@company),
          companyId: @company&.id
        }, status: :ok
      rescue => e
        Rails.logger.error "[CompanySettings#show] Error: #{e.message}"
        render json: {
          communications: default_communications_settings,
          notifications: default_notifications_settings,
          branding: default_branding_settings
        }, status: :ok
      end

      # PUT/PATCH /api/company/settings
      def update
        updated_settings = {}
        
        if params[:communications].present?
          save_communications_settings(@company, params[:communications])
          updated_settings[:communications] = fetch_communications_settings(@company)
        end
        
        if params[:notifications].present?
          save_notifications_settings(@company, params[:notifications])
          updated_settings[:notifications] = fetch_notifications_settings(@company)
        end

        if params[:branding].present?
          save_branding_settings(@company, params[:branding])
          updated_settings[:branding] = fetch_branding_settings(@company)
        end
        
        render json: {
          **updated_settings,
          companyId: @company.id,
          message: 'Company settings updated successfully'
        }, status: :ok
      rescue => e
        Rails.logger.error "[CompanySettings#update] Error: #{e.message}"
        render json: { 
          error: 'Failed to update company settings',
          message: e.message 
        }, status: :unprocessable_entity
      end

      # POST /api/company/settings/test_email
      def test_email
        email_settings = params[:email] || params[:settings] || {}
        
        return render_missing_settings('email') if email_settings.blank?
        
        settings_hash = email_settings.is_a?(ActionController::Parameters) ? email_settings.to_unsafe_h : email_settings
        
        result = TestCommunicationService.new(settings_hash, :email).test
        
        if result[:success]
          render json: {
            success: true,
            message: result[:message],
            provider: result[:provider]
          }, status: :ok
        else
          render json: {
            success: false,
            error: result[:error],
            details: result[:backtrace]
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[CompanySettings#test_email] Error: #{e.message}"
        render json: {
          success: false,
          error: e.message,
          backtrace: e.backtrace.first(3)
        }, status: :unprocessable_entity
      end

      # POST /api/company/settings/test_sms
      def test_sms
        sms_settings = params[:sms] || params[:settings] || {}
        
        return render_missing_settings('sms') if sms_settings.blank?
        
        settings_hash = sms_settings.is_a?(ActionController::Parameters) ? sms_settings.to_unsafe_h : sms_settings
        
        result = TestCommunicationService.new(settings_hash, :sms).test
        
        if result[:success]
          render json: {
            success: true,
            message: result[:message],
            provider: result[:provider]
          }, status: :ok
        else
          render json: {
            success: false,
            error: result[:error],
            details: result[:backtrace]
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[CompanySettings#test_sms] Error: #{e.message}"
        render json: {
          success: false,
          error: e.message,
          backtrace: e.backtrace.first(3)
        }, status: :unprocessable_entity
      end

      private

      def fetch_communications_settings(company)
        return default_communications_settings unless company
        company.communications_settings || default_communications_settings
      end

      def fetch_notifications_settings(company)
        return default_notifications_settings unless company
        company.notifications_settings || default_notifications_settings
      end

      def fetch_branding_settings(company)
        return default_branding_settings unless company
        
        branding = company.branding_settings || default_branding_settings
        
        if branding['logo'].present?
          branding['logo'] = absolute_url(branding['logo'])
        end
        
        if branding['favicon'].present?
          branding['favicon'] = absolute_url(branding['favicon'])
        end
        
        if branding['portalLogo'].present?
          branding['portalLogo'] = absolute_url(branding['portalLogo'])
        end
        
        if branding['platformLogo'].present?
          branding['platformLogo'] = absolute_url(branding['platformLogo'])
        end
        
        branding
      end

      def save_communications_settings(company, settings)
        encrypted_settings = encrypt_sensitive_fields(settings, :communications)
        company.communications_settings = encrypted_settings
      end

      def save_notifications_settings(company, settings)
        company.notifications_settings = settings
      end

      def save_branding_settings(company, settings)
        company.branding_settings = settings
      end

      def encrypt_sensitive_fields(settings, channel)
        encrypted = settings.deep_dup
        
        case channel
        when :communications
          if encrypted.dig('email', 'smtpPassword').present?
            encrypted['email']['smtpPassword'] = encrypt(encrypted['email']['smtpPassword'])
          end
          if encrypted.dig('email', 'gmailClientSecret').present?
            encrypted['email']['gmailClientSecret'] = encrypt(encrypted['email']['gmailClientSecret'])
          end
          if encrypted.dig('email', 'gmailRefreshToken').present?
            encrypted['email']['gmailRefreshToken'] = encrypt(encrypted['email']['gmailRefreshToken'])
          end
          if encrypted.dig('email', 'sendgridApiKey').present?
            encrypted['email']['sendgridApiKey'] = encrypt(encrypted['email']['sendgridApiKey'])
          end
          if encrypted.dig('email', 'awsSecretAccessKey').present?
            encrypted['email']['awsSecretAccessKey'] = encrypt(encrypted['email']['awsSecretAccessKey'])
          end
          
          if encrypted.dig('sms', 'twilioAuthToken').present?
            encrypted['sms']['twilioAuthToken'] = encrypt(encrypted['sms']['twilioAuthToken'])
          end
          if encrypted.dig('sms', 'awsSecretAccessKey').present?
            encrypted['sms']['awsSecretAccessKey'] = encrypt(encrypted['sms']['awsSecretAccessKey'])
          end
        end
        
        encrypted
      end

      def encrypt(value)
        return value if value.blank?
        return value if value.start_with?('encrypted:')
        
        secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
        key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
        crypt = ActiveSupport::MessageEncryptor.new(key)
        "encrypted:#{crypt.encrypt_and_sign(value)}"
      end

      def render_missing_settings(channel)
        render json: {
          success: false,
          error: "#{channel.capitalize} settings are required for testing"
        }, status: :unprocessable_entity
      end

      def default_communications_settings
        {
          email: {
            provider: 'smtp',
            fromEmail: nil,
            fromName: nil,
            isEnabled: false
          },
          sms: {
            provider: 'twilio',
            fromNumber: nil,
            isEnabled: false
          }
        }
      end
      
      def default_notifications_settings
        {
          email: {
            isEnabled: true,
            sendReminders: true,
            sendActivityUpdates: true,
            dailyDigest: false
          },
          sms: {
            isEnabled: false,
            sendReminders: true,
            sendUrgentOnly: true
          },
          popup: {
            isEnabled: true,
            showReminders: true,
            showActivityUpdates: true,
            autoClose: true,
            autoCloseDelay: 5000
          }
        }
      end

      def default_branding_settings
        {
          logo: nil,
          favicon: nil,
          primaryColor: '#3b82f6',
          secondaryColor: '#8b5cf6',
          fontFamily: 'Inter',
          sideMenuColor: nil,
          portalName: 'Customer Portal',
          portalLogo: nil,
          platformLogo: nil,
          platformName: nil
        }
      end
      
      def absolute_url(path)
        return path if path.blank?
        return path if path.start_with?('http://', 'https://')
        
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
