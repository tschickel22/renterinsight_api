# frozen_string_literal: true

module Api
  module Platform
    class SettingsController < ApplicationController
      # Skip authentication for maintenance mode check (must work before login)
      skip_before_action :authenticate, only: [:show]
      
      # GET /api/platform/settings
      def show
        render json: {
          communications: mask_sensitive_fields(fetch_communications_settings),
          notifications: fetch_notifications_settings,
          general: fetch_general_settings,
          branding: fetch_branding_settings,
          warranty: fetch_warranty_settings
        }, status: :ok
      rescue => e
        Rails.logger.error "[PlatformSettings#show] Error: #{e.message}"
        render json: {
          communications: default_communications_settings,
          notifications: default_notifications_settings,
          general: default_general_settings,
          branding: default_branding_settings,
          warranty: default_warranty_settings
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

        # Update general settings if provided
        if params[:general].present?
          save_general_settings(params[:general])
          updated_settings[:general] = fetch_general_settings
        end

        # Update branding settings if provided
        if params[:branding].present?
          save_branding_settings(params[:branding])
          updated_settings[:branding] = fetch_branding_settings
        end
        
        # Update warranty settings if provided
        if params[:warranty].present?
          save_warranty_settings(params[:warranty])
          updated_settings[:warranty] = fetch_warranty_settings
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

        # Convert ActionController::Parameters to hash for service
        settings_hash = email_settings.is_a?(ActionController::Parameters) ? email_settings.to_unsafe_h : email_settings

        # If the FE only sent a recipient string, fall back to the stored config entirely.
        if settings_hash.is_a?(String) || !settings_hash.is_a?(Hash)
          stored = fetch_communications_settings || {}
          settings_hash = (stored['email'] || stored[:email] || {}).deep_stringify_keys
          return render_missing_settings('email') if settings_hash.blank?
        end

        # Replace any masked/encrypted values in the submitted form with the real
        # decrypted secrets from the DB so the tester sees working credentials.
        settings_hash = unmask_secrets_for_testing('email', settings_hash)

        # Test the email configuration
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

        # Convert ActionController::Parameters to hash for service
        settings_hash = sms_settings.is_a?(ActionController::Parameters) ? sms_settings.to_unsafe_h : sms_settings

        if settings_hash.is_a?(String) || !settings_hash.is_a?(Hash)
          stored = fetch_communications_settings || {}
          settings_hash = (stored['sms'] || stored[:sms] || {}).deep_stringify_keys
          return render_missing_settings('sms') if settings_hash.blank?
        end

        settings_hash = unmask_secrets_for_testing('sms', settings_hash)

        # Test the SMS configuration
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

      def fetch_general_settings
        stored = Setting.get('Platform', 0, 'general')
        stored || default_general_settings
      end

      def fetch_branding_settings
        stored = Setting.get('Platform', 0, 'branding')
        branding = stored || default_branding_settings
        
        # Convert logo URLs from relative to absolute
        if branding['logo'].present?
          branding['logo'] = absolute_url(branding['logo'])
        end
        
        # Convert favicon to faviconUrl for frontend (camelCase)
        if branding['favicon'].present?
          branding['faviconUrl'] = absolute_url(branding['favicon'])
          branding.delete('favicon')
        end
        
        if branding['portalLogo'].present?
          branding['portalLogo'] = absolute_url(branding['portalLogo'])
        end
        
        if branding['platformLogo'].present?
          branding['platformLogo'] = absolute_url(branding['platformLogo'])
        end
        
        branding
      end
      
      def fetch_warranty_settings
        Setting.get_warranty_settings('Platform', 0)
      end

      MASKED_PLACEHOLDER = '••••••••'
      # Any field sent back as a run of common mask characters counts as "unchanged".
      # Historically only the exact 8-bullet string was caught, but the FE renders
      # a dot per character of the stored encrypted value (~110 chars), so re-saves
      # were silently re-encrypting a long bullet string and corrupting the secret.
      MASK_ONLY_REGEX = /\A[\u2022\*\u25CF\u00B7\u2219 ]+\z/.freeze

      SENSITIVE_KEYS = {
        'email' => %w[smtpPassword gmailClientSecret gmailRefreshToken sendgridApiKey awsSecretAccessKey],
        'sms'   => %w[twilioAuthToken awsSecretAccessKey]
      }.freeze

      def save_communications_settings(settings)
        restored_settings = restore_masked_secrets(settings)
        encrypted_settings = encrypt_sensitive_fields(restored_settings, :communications)
        Setting.set('Platform', 0, 'communications', encrypted_settings)
      end

      # When the frontend sends back the masked placeholder (any length of bullets/stars)
      # OR an already-encrypted value, preserve the existing stored value so we never
      # overwrite a real secret with a masked display string.
      def restore_masked_secrets(settings)
        existing = fetch_communications_settings
        return settings unless existing.is_a?(Hash)

        restored = settings.deep_dup
        SENSITIVE_KEYS.each do |section, keys|
          next unless restored[section].is_a?(Hash)

          keys.each do |key|
            value = restored[section][key].to_s
            next if value.blank?

            masked    = value == MASKED_PLACEHOLDER || MASK_ONLY_REGEX.match?(value)
            encrypted = value.start_with?('encrypted:')

            if masked || encrypted
              existing_value = existing.dig(section, key) || existing.dig(section.to_sym, key.to_sym)
              restored[section][key] = existing_value if existing_value.present?
            end
          end
        end

        restored
      end

      # Public-ish helper so the test_email / test_sms actions can swap masks in the
      # incoming form payload for the real decrypted value before calling the tester.
      def unmask_secrets_for_testing(section_name, section_hash)
        return section_hash unless section_hash.is_a?(Hash)

        existing = fetch_communications_settings || {}
        stored_section = existing[section_name] || existing[section_name.to_sym] || {}
        stored_section = stored_section.deep_stringify_keys if stored_section.is_a?(Hash)

        merged = section_hash.deep_stringify_keys
        Array(SENSITIVE_KEYS[section_name.to_s]).each do |key|
          value = merged[key].to_s
          next if value.blank?

          masked    = value == MASKED_PLACEHOLDER || MASK_ONLY_REGEX.match?(value)
          encrypted = value.start_with?('encrypted:')
          next unless masked || encrypted

          stored = stored_section[key]
          next if stored.blank?

          decrypted = decrypt_if_needed(stored)
          merged[key] = decrypted if decrypted.present?
        end
        merged
      end

      def decrypt_if_needed(value)
        return value unless value.is_a?(String) && value.start_with?('encrypted:')
        ciphertext = value.sub('encrypted:', '')
        key_base = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
        key = ActiveSupport::KeyGenerator.new(key_base).generate_key('', 32)
        ActiveSupport::MessageEncryptor.new(key).decrypt_and_verify(ciphertext)
      rescue => e
        Rails.logger.error "[PlatformSettings] decrypt_if_needed failed: #{e.message}"
        nil
      end

      def save_notifications_settings(settings)
        Setting.set('Platform', 0, 'notifications', settings)
      end

      def save_general_settings(settings)
        Setting.set('Platform', 0, 'general', settings)
      end

      def save_branding_settings(settings)
        # Convert frontend field names to backend format for storage
        normalized = settings.deep_dup
        
        # Convert faviconUrl to favicon for storage
        if normalized['faviconUrl'].present?
          normalized['favicon'] = normalized.delete('faviconUrl')
        end
        
        Setting.set('Platform', 0, 'branding', normalized)
      end
      
      def save_warranty_settings(settings)
        Setting.set('Platform', 0, 'warranty', settings)
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

      # Replace encrypted secret values with a masked placeholder for the frontend
      def mask_sensitive_fields(settings)
        return settings unless settings.is_a?(Hash)

        masked = settings.deep_dup
        SENSITIVE_KEYS.each do |section, keys|
          sub = masked[section] || masked[section.to_sym]
          next unless sub.is_a?(Hash)

          keys.each do |key|
            value = sub[key] || sub[key.to_sym]
            if value.present?
              k = sub.key?(key) ? key : key.to_sym
              sub[k] = MASKED_PLACEHOLDER
            end
          end
        end

        masked
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

      def default_general_settings
        {
          platformName: ENV['PLATFORM_NAME'] || 'RenterInsight',
          supportEmail: ENV['SUPPORT_EMAIL'] || 'support@renterinsight.com',
          maintenanceMode: false,
          maintenanceMessage: 'We are currently performing scheduled maintenance. Please check back soon.'
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
          portalName: ENV['PORTAL_NAME'] || 'Customer Portal',
          portalLogo: nil,
          platformLogo: nil,
          platformName: ENV['PLATFORM_NAME'] || 'RenterInsight'
        }
      end
      
      def default_warranty_settings
        Setting.warranty_defaults('Platform', 0)
      end
      
    end
  end
end
