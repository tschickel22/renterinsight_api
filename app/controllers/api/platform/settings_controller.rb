# frozen_string_literal: true

module Api
  module Platform
    class SettingsController < ApplicationController
      # GET /api/platform/settings
      def show
        render json: {
          communications: fetch_communications_settings,
          notifications: fetch_notifications_settings
        }, status: :ok
      rescue => e
        Rails.logger.error "[PlatformSettings#show] Error: #{e.message}"
        render json: {
          communications: default_communications_settings,
          notifications: default_notifications_settings
        }, status: :ok
      end

      # PUT/PATCH /api/platform/settings
      def update
        updated_settings = {}
        
        # Update communications settings if provided
        if params[:communications].present?
          save_communications_settings(params[:communications])
          updated_settings[:communications] = fetch_communications_settings
        end
        
        # Update notifications settings if provided
        if params[:notifications].present?
          save_notifications_settings(params[:notifications])
          updated_settings[:notifications] = fetch_notifications_settings
        end
        
        render json: {
          **updated_settings,
          message: 'Platform settings updated successfully'
        }, status: :ok
      rescue => e
        Rails.logger.error "[PlatformSettings#update] Error: #{e.message}"
        render json: { 
          error: 'Failed to update platform settings',
          message: e.message 
        }, status: :unprocessable_entity
      end

      # POST /api/platform/settings/test_email
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
        Rails.logger.error "[PlatformSettings#test_email] Error: #{e.message}"
        render json: {
          success: false,
          error: e.message,
          backtrace: e.backtrace.first(3)
        }, status: :unprocessable_entity
      end

      # POST /api/platform/settings/test_sms
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
        Rails.logger.error "[PlatformSettings#test_sms] Error: #{e.message}"
        render json: {
          success: false,
          error: e.message,
          backtrace: e.backtrace.first(3)
        }, status: :unprocessable_entity
      end

      private

      def fetch_communications_settings
        # Try database first, fall back to defaults
        stored = Setting.get('Platform', 0, 'communications')
        stored || default_communications_settings
      end

      def fetch_notifications_settings
        stored = Setting.get('Platform', 0, 'notifications')
        stored || default_notifications_settings
      end

      def save_communications_settings(settings)
        # Encrypt sensitive credentials before saving
        encrypted_settings = encrypt_sensitive_fields(settings, :communications)
        Setting.set('Platform', 0, 'communications', encrypted_settings)
      end

      def save_notifications_settings(settings)
        Setting.set('Platform', 0, 'notifications', settings)
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
            provider: ENV['EMAIL_PROVIDER'] || 'smtp',
            fromEmail: ENV['EMAIL_FROM'] || 'platform@renterinsight.com',
            fromName: ENV['EMAIL_FROM_NAME'] || 'RenterInsight Platform',
            smtpHost: ENV['SMTP_HOST'] || 'smtp.example.com',
            smtpPort: (ENV['SMTP_PORT'] || 587).to_i,
            smtpUsername: ENV['SMTP_USERNAME'],
            smtpPassword: nil, # Never return actual password
            isEnabled: ENV['EMAIL_ENABLED'] != 'false'
          },
          sms: {
            provider: ENV['SMS_PROVIDER'] || 'twilio',
            fromNumber: ENV['SMS_FROM_NUMBER'] || '+1234567890',
            twilioAccountSid: ENV['TWILIO_ACCOUNT_SID'],
            twilioAuthToken: nil, # Never return actual token
            isEnabled: ENV['SMS_ENABLED'] == 'true'
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