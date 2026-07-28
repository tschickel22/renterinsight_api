# frozen_string_literal: true

module Api
  module Platform
    class SettingsController < ApplicationController
      include CommunicationSecrets

      # Skip authentication for maintenance mode check (must work before login)
      skip_before_action :authenticate, only: [:show]

      # Everything except the pre-login brand kernel is platform-admin only.
      # Writing these settings reconfigures email/SMS delivery for every tenant.
      before_action :require_platform_admin!, except: [:show]

      # GET /api/platform/settings
      #
      # Three tiers, because three different callers need three different things:
      #   public         → brand kernel + maintenance banner, for login/invite/portal
      #   any signed-in  → whether platform email/SMS is configured, for the
      #                    settings cascade and "can I send?" checks
      #   platform admin → the full config
      #
      # The middle tier deliberately omits provider credentials AND the
      # identifiers next to them (Twilio account SID, AWS access key ID, SMTP
      # host/username): masking the secret is not enough when the account it
      # belongs to is printed beside it.
      def show
        payload = {
          general: fetch_general_settings,
          branding: fetch_branding_settings
        }

        if platform_admin_request?
          payload[:communications] = mask_sensitive_fields(fetch_communications_settings)
          payload[:notifications]  = fetch_notifications_settings
          payload[:warranty]       = fetch_warranty_settings
        elsif authenticated_request?
          payload[:communications] = communications_summary(fetch_communications_settings)
          payload[:notifications]  = fetch_notifications_settings
        end

        render json: payload, status: :ok
      rescue => e
        Rails.logger.error "[PlatformSettings#show] Error: #{e.message}"
        render json: {
          general: default_general_settings,
          branding: default_branding_settings
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

      # `authenticate` is skipped on #show so the login page can read the brand
      # kernel, which means current_user is never populated for that action.
      # Decode the bearer token here instead — absent, invalid, or non-admin all
      # mean "public caller", and public callers get the brand kernel only.
      def platform_admin_request?
        user = bearer_token_user
        user.present? && (user.platform_admin? || user.super_admin?)
      end

      def authenticated_request?
        bearer_token_user.present?
      end

      def bearer_token_user
        return @bearer_token_user if defined?(@bearer_token_user)

        @bearer_token_user = begin
          header = request.headers['Authorization']
          decoded = header.present? ? JsonWebToken.decode(header.split(' ').last) : nil
          decoded.present? ? User.find_by(id: decoded[:user_id]) : nil
        end
      end

      # What a signed-in non-admin may know about platform delivery: which
      # provider is in play, whether it is on, and the from-identity that will
      # appear on their messages. No credentials, no account identifiers.
      SUMMARY_KEYS = {
        'email' => %w[provider fromEmail fromName isEnabled],
        'sms'   => %w[provider fromNumber isEnabled]
      }.freeze

      def communications_summary(settings)
        settings = normalize_settings_payload(settings)
        return {} unless settings.is_a?(Hash)

        SUMMARY_KEYS.each_with_object({}) do |(section, keys), summary|
          sub = settings[section]
          next unless sub.is_a?(Hash)

          summary[section] = sub.slice(*keys)
        end
      end

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
        # Delegate to PlatformSetting.general so brand-kernel defaults + persisted
        # overrides come from a single source of truth. That way any new default
        # field added to PlatformSetting.default_general automatically appears
        # here without touching this controller.
        PlatformSetting.general
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

      def save_communications_settings(settings)
        existing = fetch_communications_settings
        # A payload carrying only one channel must not delete the other. Saving
        # just the SMS section used to leave {"sms" => {"fromNumber" => ...}}
        # behind and take every email credential with it. Merge at section
        # granularity: a section the client sent is authoritative, a section it
        # omitted is untouched.
        merged = existing.is_a?(Hash) ? normalize_settings_payload(existing).merge(normalize_settings_payload(settings)) : settings

        restored_settings  = restore_masked_secrets(merged, existing)
        encrypted_settings = encrypt_sensitive_fields(restored_settings)
        Setting.set('Platform', 0, 'communications', encrypted_settings)
      end

      # Public-ish helper so the test_email / test_sms actions can swap masks in the
      # incoming form payload for the real decrypted value before calling the tester.
      def unmask_secrets_for_testing(section_name, section_hash)
        merged = normalize_settings_payload(section_hash)
        return section_hash unless merged.is_a?(Hash)

        existing = fetch_communications_settings || {}
        stored_section = existing[section_name] || existing[section_name.to_sym] || {}
        stored_section = stored_section.deep_stringify_keys if stored_section.is_a?(Hash)

        Array(SENSITIVE_KEYS[section_name.to_s]).each do |key|
          value = merged[key].to_s
          next if value.blank?
          next unless mask_only?(value) || value.start_with?('encrypted:')

          stored = stored_section[key]
          next if stored.blank?

          decrypted = decrypt_secret(stored)
          merged[key] = decrypted if decrypted.present?
        end
        merged
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
        # Kept for backward compatibility with the reset-to-defaults flow.
        # PlatformSetting.default_general is the actual source of truth for
        # brand-kernel defaults; this method delegates so we don't duplicate.
        PlatformSetting.default_general
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
