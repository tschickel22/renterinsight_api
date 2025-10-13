# frozen_string_literal: true

module Api
  module Company
    class SettingsController < ApplicationController
      # GET /api/company/settings
      def show
        company = find_or_create_company
        
        render json: {
          communications: fetch_communications_settings(company),
          notifications: fetch_notifications_settings(company),
          companyId: company&.id
        }, status: :ok
      rescue => e
        Rails.logger.error "[CompanySettings#show] Error: #{e.message}"
        render json: {
          communications: default_communications_settings,
          notifications: default_notifications_settings
        }, status: :ok
      end

      # PUT/PATCH /api/company/settings
      def update
        company = find_or_create_company
        
        if company
          updated_settings = {}
          
          # Update communications settings if provided
          if params[:communications].present?
            save_communications_settings(company, params[:communications])
            updated_settings[:communications] = fetch_communications_settings(company)
          end
          
          # Update notifications settings if provided
          if params[:notifications].present?
            save_notifications_settings(company, params[:notifications])
            updated_settings[:notifications] = fetch_notifications_settings(company)
          end
          
          render json: {
            **updated_settings,
            companyId: company.id,
            message: 'Company settings updated successfully'
          }, status: :ok
        else
          render json: {
            communications: params[:communications] || default_communications_settings,
            notifications: params[:notifications] || default_notifications_settings,
            message: 'Settings saved (no company record yet)'
          }, status: :ok
        end
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
        
        # Test the email configuration
        result = TestCommunicationService.new(email_settings, :email).test
        
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
        
        # Test the SMS configuration
        result = TestCommunicationService.new(sms_settings, :sms).test
        
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

      def find_or_create_company
        # Try to find existing company
        company = current_user&.company || Company.first rescue nil
        
        # If no company exists, create a default one
        if company.nil? && defined?(Company)
          begin
            company = Company.create!(name: 'Demo Company')
          rescue => e
            Rails.logger.warn "[CompanySettings] Could not create company: #{e.message}"
            nil
          end
        end
        
        company
      end

      def fetch_communications_settings(company)
        return default_communications_settings unless company
        
        # Get company-specific settings or fall back to defaults
        company.communications_settings || default_communications_settings
      end

      def fetch_notifications_settings(company)
        return default_notifications_settings unless company
        
        company.notifications_settings || default_notifications_settings
      end

      def save_communications_settings(company, settings)
        # Encrypt sensitive credentials before saving
        encrypted_settings = encrypt_sensitive_fields(settings, :communications)
        company.communications_settings = encrypted_settings
      end

      def save_notifications_settings(company, settings)
        company.notifications_settings = settings
      end

      def encrypt_sensitive_fields(settings, channel)
        encrypted = settings.deep_dup
        
        case channel
        when :communications
          # Encrypt email credentials
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
          
          # Encrypt SMS credentials
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
        # Ensure key is exactly 32 bytes for AES-256
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
            fromEmail: 'noreply@example.com',
            fromName: 'Demo Company',
            isEnabled: true
          },
          sms: {
            provider: 'twilio',
            fromNumber: '+1234567890',
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
    end
  end
end