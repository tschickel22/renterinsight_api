# frozen_string_literal: true

module Api
  module Company
    class SettingsController < ApplicationController
      include CommunicationSecrets

      before_action :authenticate_user!
      before_action :set_company_scope

      # GET /api/company/settings
      def show
        return unless authorize_action!('company_settings', 'read')

        render json: {
          communications: mask_sensitive_fields(fetch_communications_settings(@company)),
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
        return unless authorize_action!('company_settings', 'update')

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
        return unless authorize_action!('company_settings', 'update')

        email_settings = params[:email] || params[:settings] || {}

        return render_missing_settings('email') if email_settings.blank?
        
        settings_hash = email_settings.is_a?(ActionController::Parameters) ? email_settings.to_unsafe_h : email_settings

        # For OAuth providers, oauthEmail/oauthAccessToken are set server-side during the
        # OAuth callback and are NOT sent back by the frontend form - merge from DB
        provider = settings_hash['provider'] || settings_hash[:provider]
        if provider.to_s.start_with?('oauth_')
          db_email_settings = (fetch_communications_settings(@company)&.dig('email') || {}).stringify_keys
          %w[oauthEmail oauthProvider oauthAccessToken oauthRefreshToken oauthExpiresAt oauthConnectedAt].each do |key|
            settings_hash[key] = db_email_settings[key] if settings_hash[key].blank? && db_email_settings[key].present?
          end
          Rails.logger.info "[test_email] Merged OAuth fields from DB: oauthEmail=#{settings_hash['oauthEmail'].inspect}"
        end
        
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

      # POST /api/company/settings/send_test_email
      def send_test_email
        return unless authorize_action!('company_settings', 'update')

        email_params = params[:email] || {}
        to = email_params[:to]
        subject = email_params[:subject] || "Test Email from #{Brand.current.name}"
        body = email_params[:body] || 'This is a test email to verify your email configuration.'
        
        if to.blank?
          return render json: {
            success: false,
            error: 'Recipient email address is required'
          }, status: :unprocessable_entity
        end
        
        # Get current company's email settings (with cascade)
        communications_settings = fetch_communications_settings(@company)
        email_settings = communications_settings&.dig('email') || {}
        
        if email_settings.blank? || !email_settings['isEnabled']
          return render json: {
            success: false,
            error: 'Email is not configured for this company'
          }, status: :unprocessable_entity
        end
        
        # Decrypt sensitive fields
        email_settings_symbolized = email_settings.deep_symbolize_keys
        decrypted_settings = decrypt_email_settings(email_settings_symbolized)
        
        # Get provider and from address
        provider = decrypted_settings[:provider] || 'smtp'
        is_oauth = provider.to_s.start_with?('oauth_')
        from_email = if is_oauth
          decrypted_settings[:oauthEmail] || decrypted_settings['oauthEmail']
        else
          decrypted_settings[:fromEmail] || decrypted_settings[:from_email]
        end

        Rails.logger.info "[send_test_email] Company #{@company.id}: provider=#{provider}, from=#{from_email}, is_oauth=#{is_oauth}"
        
        if from_email.blank?
          return render json: {
            success: false,
            error: 'From email address is not configured'
          }, status: :unprocessable_entity
        end
        
        # Send email directly using appropriate provider
        begin
          result = send_test_email_via_provider(
            provider: provider,
            to: to,
            from: from_email,
            subject: subject,
            body: body,
            settings: decrypted_settings
          )
          
          if result[:success]
            render json: {
              success: true,
              message: "Test email sent successfully to #{to}",
              messageId: result[:message_id]
            }, status: :ok
          else
            render json: {
              success: false,
              error: result[:error] || 'Failed to send test email'
            }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "[CompanySettings#send_test_email] Error: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          render json: {
            success: false,
            error: e.message
          }, status: :unprocessable_entity
        end
      end
      
      def send_test_email_via_provider(provider:, to:, from:, subject:, body:, settings:)
        case provider.to_sym
        when :smtp, :gmail
          send_via_smtp(to: to, from: from, subject: subject, body: body, settings: settings)
        when :sendgrid
          send_via_sendgrid(to: to, from: from, subject: subject, body: body, settings: settings)
        when :aws_ses
          send_via_aws_ses(to: to, from: from, subject: subject, body: body, settings: settings)
        when :oauth_microsoft, :oauth_google
          send_via_oauth_smtp(to: to, from: from, subject: subject, body: body, settings: settings)
        else
          { success: false, error: "Unknown email provider: #{provider}" }
        end
      end
      
      def send_via_smtp(to:, from:, subject:, body:, settings:)
        require 'net/smtp'
        require 'mail'
        
        host = settings[:smtpHost] || settings[:smtp_host]
        port = (settings[:smtpPort] || settings[:smtp_port] || 587).to_i
        username = settings[:smtpUsername] || settings[:smtp_username]
        password = settings[:smtpPassword] || settings[:smtp_password]
        from_name = settings[:fromName] || settings[:from_name]
        
        # Build email message
        mail = Mail.new do
          from     "#{from_name} <#{from}>"
          to       to
          subject  subject
          body     body
        end
        
        # Send via SMTP
        authentication = (settings[:smtpAuthentication] || settings[:smtp_authentication] || 'plain').to_sym

        mail.delivery_method :smtp, {
          address: host,
          port: port,
          user_name: username,
          password: password,
          authentication: authentication,
          enable_starttls_auto: port == 587
        }
        
        mail.deliver!
        
        { success: true, message_id: mail.message_id }
      rescue => e
        Rails.logger.error "[SMTP] Send failed: #{e.message}"
        { success: false, error: e.message }
      end
      
      def send_via_oauth_smtp(to:, from:, subject:, body:, settings:)
        oauth_provider = (settings[:oauthProvider] || settings['oauthProvider'] || '').to_s
        smtp_host, smtp_port = case oauth_provider
                               when 'microsoft' then ['smtp.office365.com', 587]
                               when 'google'    then ['smtp.gmail.com', 587]
                               else return { success: false, error: "Unknown OAuth provider: #{oauth_provider}" }
                               end

        oauth_email  = settings[:oauthEmail] || settings['oauthEmail']
        access_token = settings[:oauthAccessToken] || settings['oauthAccessToken']

        # Refresh token if near expiry
        oauth_expires = settings[:oauthExpiresAt] || settings['oauthExpiresAt']
        if oauth_expires.present?
          expires_at = Time.parse(oauth_expires.to_s) rescue nil
          if expires_at && expires_at <= 5.minutes.from_now
            refresh_token = settings[:oauthRefreshToken] || settings['oauthRefreshToken']
            refreshed = refresh_oauth_access_token_for_test(oauth_provider, refresh_token)
            access_token = refreshed if refreshed
          end
        end

        oauth_from = from.presence || oauth_email

        send_via_smtp(
          to: to, from: oauth_from, subject: subject, body: body,
          settings: settings.merge(
            smtpHost: smtp_host,
            smtpPort: smtp_port,
            smtpUsername: oauth_email,
            smtpPassword: access_token,
            smtpAuthentication: 'xoauth2',
            fromName: settings[:fromName] || settings['fromName'] || oauth_email
          )
        )
      end

      def refresh_oauth_access_token_for_test(provider, refresh_token)
        return nil if refresh_token.blank?

        token_url = case provider
                    when 'microsoft' then 'https://login.microsoftonline.com/common/oauth2/v2.0/token'
                    when 'google'    then 'https://oauth2.googleapis.com/token'
                    else return nil
                    end

        client_id     = ENV["#{provider.upcase}_OAUTH_CLIENT_ID"] ||
                        Rails.application.credentials.dig(:oauth, provider.to_sym, :client_id)
        client_secret = ENV["#{provider.upcase}_OAUTH_CLIENT_SECRET"] ||
                        Rails.application.credentials.dig(:oauth, provider.to_sym, :client_secret)

        uri = URI(token_url)
        req = Net::HTTP::Post.new(uri)
        req.set_form_data(
          client_id:     client_id,
          client_secret: client_secret,
          refresh_token: refresh_token,
          grant_type:    'refresh_token'
        )
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
        tokens = JSON.parse(res.body)

        return nil if tokens['error'].present?

        tokens['access_token']
      rescue => e
        Rails.logger.error "[CompanySettings] OAuth token refresh failed: #{e.message}"
        nil
      end

      def send_via_sendgrid(to:, from:, subject:, body:, settings:)
        require 'net/http'
        require 'uri'
        require 'json'
        
        api_key = settings[:sendgridApiKey] || settings[:sendgrid_api_key]
        from_name = settings[:fromName] || settings[:from_name]
        
        unless api_key.present?
          return { success: false, error: 'SendGrid API key is missing' }
        end
        
        uri = URI.parse('https://api.sendgrid.com/v3/mail/send')
        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{api_key}"
        request['Content-Type'] = 'application/json'
        
        request.body = {
          personalizations: [{ to: [{ email: to }] }],
          from: { email: from, name: from_name },
          subject: subject,
          content: [{ type: 'text/plain', value: body }]
        }.to_json
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        
        if response.code.to_i == 202
          { success: true, message_id: response['x-message-id'] }
        else
          result = JSON.parse(response.body) rescue {}
          { success: false, error: result['errors']&.first&.dig('message') || 'SendGrid send failed' }
        end
      rescue => e
        Rails.logger.error "[SendGrid] Send failed: #{e.message}"
        { success: false, error: e.message }
      end
      
      def send_via_aws_ses(to:, from:, subject:, body:, settings:)
        require 'aws-sdk-ses'
        
        access_key = settings[:awsAccessKeyId] || settings[:aws_access_key_id]
        secret_key = settings[:awsSecretAccessKey] || settings[:aws_secret_access_key]
        region = settings[:awsRegion] || settings[:aws_region] || 'us-east-1'
        
        unless access_key.present? && secret_key.present?
          return { success: false, error: 'AWS credentials are missing' }
        end
        
        ses = Aws::SES::Client.new(
          access_key_id: access_key,
          secret_access_key: secret_key,
          region: region
        )
        
        response = ses.send_email({
          source: from,
          destination: { to_addresses: [to] },
          message: {
            subject: { data: subject },
            body: { text: { data: body } }
          }
        })
        
        { success: true, message_id: response.message_id }
      rescue Aws::SES::Errors::ServiceError => e
        Rails.logger.error "[AWS SES] Send failed: #{e.message}"
        { success: false, error: e.message }
      rescue => e
        Rails.logger.error "[AWS SES] Send failed: #{e.message}"
        { success: false, error: e.message }
      end
      
      def decrypt_email_settings(settings)
        decrypted = settings.deep_dup
        
        decrypted[:smtpPassword] = decrypt_if_needed(decrypted[:smtpPassword] || decrypted[:smtp_password])
        decrypted[:sendgridApiKey] = decrypt_if_needed(decrypted[:sendgridApiKey] || decrypted[:sendgrid_api_key])
        decrypted[:awsSecretAccessKey] = decrypt_if_needed(decrypted[:awsSecretAccessKey] || decrypted[:aws_secret_access_key])
        
        decrypted
      end
      
      def decrypt(encrypted_value)
        return encrypted_value if encrypted_value.blank?
        secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
        key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
        crypt = ActiveSupport::MessageEncryptor.new(key)
        crypt.decrypt_and_verify(encrypted_value)
      end

      def decrypt_if_needed(value)
        return value unless value.present?
        return value unless value.to_s.start_with?('encrypted:')
        
        encrypted_value = value.to_s.sub('encrypted:', '')
        decrypt(encrypted_value)
      rescue => e
        Rails.logger.error "[Decryption] Error: #{e.message}"
        value
      end

      # POST /api/company/settings/test_sms
      def test_sms
        return unless authorize_action!('company_settings', 'update')

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

        # Three-tier waterfall with deep_merge: Platform → Company → Location
        # Each level overrides the previous, so Location SMS + Company email both work
        platform_settings = Setting.get('Platform', 0, 'communications') || {}
        company_settings = Setting.get('Company', company.id, 'communications') || {}
        location_settings = if Current.location_id.present?
                              Setting.get('Location', Current.location_id, 'communications') || {}
                            else
                              {}
                            end

        result = platform_settings.deep_merge(company_settings).deep_merge(location_settings)

        result.present? ? result : default_communications_settings
      end

      def fetch_notifications_settings(company)
        return default_notifications_settings unless company
        
        # Three-tier waterfall: Location → Company → Platform
        
        # 1. Try location settings first (if location context exists)
        if Current.location_id.present?
          location_settings = Setting.get('Location', Current.location_id, 'notifications')
          return location_settings if location_settings.present?
        end
        
        # 2. Fall back to company settings
        company_settings = Setting.get('Company', company.id, 'notifications')
        return company_settings if company_settings.present?
        
        # 3. Fall back to platform settings
        platform_settings = Setting.get('Platform', 0, 'notifications')
        return platform_settings if platform_settings.present?
        
        # 4. Final fallback to hard-coded defaults
        default_notifications_settings
      end

      def fetch_branding_settings(company)
        return default_branding_settings unless company
        
        # Three-tier waterfall: Location → Company → Platform
        branding = nil
        
        # 1. Try location settings first (if location context exists)
        if Current.location_id.present?
          branding = Setting.get('Location', Current.location_id, 'branding')
        end
        
        # 2. Fall back to company settings
        branding ||= Setting.get('Company', company.id, 'branding')
        
        # 3. Fall back to platform settings
        branding ||= Setting.get('Platform', 0, 'branding')
        
        # 4. Final fallback to hard-coded defaults
        branding ||= default_branding_settings
        
        # Convert relative URLs to absolute
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
        existing = fetch_communications_settings(company)
        cleaned_settings = clean_stale_email_fields(normalize_settings_payload(settings))
        # Section-granular merge: a channel the client omitted keeps its stored
        # config instead of being deleted by a partial save. Within a section the
        # client wins, so clean_stale_email_fields' provider-switch removals still apply.
        cleaned_settings = normalize_settings_payload(existing).merge(cleaned_settings) if existing.is_a?(Hash)

        restored_settings  = restore_masked_secrets(cleaned_settings, existing)
        encrypted_settings = encrypt_sensitive_fields(restored_settings)
        Setting.set('Company', company.id, 'communications', encrypted_settings)
      end

      # Remove stale fields from a previous provider when switching email providers
      # e.g., clear OAuth fields when switching to SES, clear SMTP fields when switching to OAuth
      def clean_stale_email_fields(settings)
        return settings unless settings.is_a?(Hash) || settings.is_a?(ActionController::Parameters)

        cleaned = settings.deep_dup
        email = cleaned['email'] || cleaned[:email]
        return cleaned unless email.is_a?(Hash) || email.is_a?(ActionController::Parameters)

        provider = (email['provider'] || email[:provider]).to_s
        oauth_keys = %w[oauthProvider oauthAccessToken oauthRefreshToken oauthExpiresAt oauthEmail oauthConnectedAt]
        smtp_keys = %w[smtpHost smtpPort smtpUsername smtpPassword smtpAuthentication smtpEnableTls smtpEnableStarttls]

        unless provider.start_with?('oauth_')
          oauth_keys.each { |k| email.delete(k) }
        end

        if provider.start_with?('oauth_') || provider == 'aws_ses' || provider == 'sendgrid'
          smtp_keys.each { |k| email.delete(k) }
        end

        cleaned
      end

      def save_notifications_settings(company, settings)
        Setting.set('Company', company.id, 'notifications', settings)
      end

      def save_branding_settings(company, settings)
        Setting.set('Company', company.id, 'branding', settings)
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
      
    end
  end
end
