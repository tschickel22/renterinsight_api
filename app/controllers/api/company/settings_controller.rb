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

      # POST /api/company/settings/send_test_email
      def send_test_email
        email_params = params[:email] || {}
        to = email_params[:to]
        subject = email_params[:subject] || 'Test Email from RenterInsight'
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
        from_email = decrypted_settings[:fromEmail] || decrypted_settings[:from_email]
        
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
        mail.delivery_method :smtp, {
          address: host,
          port: port,
          user_name: username,
          password: password,
          authentication: :plain,
          enable_starttls_auto: port == 587
        }
        
        mail.deliver!
        
        { success: true, message_id: mail.message_id }
      rescue => e
        Rails.logger.error "[SMTP] Send failed: #{e.message}"
        { success: false, error: e.message }
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
        
        # Three-tier waterfall: Location → Company → Platform
        
        # 1. Try location settings first (if location context exists)
        if Current.location_id.present?
          location_settings = Setting.get('Location', Current.location_id, 'communications')
          return location_settings if location_settings.present?
        end
        
        # 2. Fall back to company settings
        company_settings = Setting.get('Company', company.id, 'communications')
        return company_settings if company_settings.present?
        
        # 3. Fall back to platform settings
        platform_settings = Setting.get('Platform', 0, 'communications')
        return platform_settings if platform_settings.present?
        
        # 4. Final fallback to hard-coded defaults
        default_communications_settings
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
        encrypted_settings = encrypt_sensitive_fields(settings, :communications)
        Setting.set('Company', company.id, 'communications', encrypted_settings)
      end

      def save_notifications_settings(company, settings)
        Setting.set('Company', company.id, 'notifications', settings)
      end

      def save_branding_settings(company, settings)
        Setting.set('Company', company.id, 'branding', settings)
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
