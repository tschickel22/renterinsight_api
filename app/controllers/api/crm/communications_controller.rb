# frozen_string_literal: true
module Api
  module Crm
    class CommunicationsController < ApplicationController
      before_action :set_lead, except: [:create_log, :email, :sms]
      before_action :set_lead_from_params, only: [:email, :sms]

      # GET /api/crm/leads/:lead_id/communications
      def index
        communications = Communication.where(communicable_type: 'Lead', communicable_id: @lead.id).order(created_at: :desc)
        render json: communications.map { |comm| comm_log_json(comm) }, status: :ok
      end

      # POST /api/crm/communications/email (non-nested route, lead_id in body)
      def email
        send_email
      end

      # POST /api/crm/communications/sms (non-nested route, lead_id in body)
      def sms
        send_sms
      end

      # POST /api/crm/leads/:lead_id/communications/email
      # POST /api/crm/leads/:lead_id/communications/send_email
      def send_email
        # Check if email is configured
        settings = get_effective_settings
        email_config = settings.dig(:communications, :email) || settings.dig('communications', 'email') || {}
        
        Rails.logger.info "[CommunicationsController#send_email] Email config: #{email_config.inspect}"
        Rails.logger.info "[CommunicationsController#send_email] Email configured check: #{email_configured?(email_config)}"
        
        unless email_configured?(email_config)
          return render json: { 
            ok: false, 
            success: false,
            error: 'Email is not configured. Please configure email settings in Platform or Company Settings.',
            debug: {
              config: email_config,
              has_provider: email_config[:provider].present? || email_config['provider'].present?,
              has_from_email: email_config[:fromEmail].present? || email_config['fromEmail'].present?,
              is_enabled: email_config[:isEnabled] || email_config['isEnabled']
            }
          }, status: :unprocessable_entity
        end

        # Support multiple parameter formats
        email_params = extract_email_params
        
        # Actually send the email via provider
        send_result = send_email_via_provider(email_params, email_config)
        
        unless send_result[:success]
          return render json: {
            ok: false,
            success: false,
            error: send_result[:error] || 'Failed to send email'
          }, status: :unprocessable_entity
        end

        # Only create communication log if we have a lead
        # For test email (no lead), just return success without creating record
        if @lead.present?
          log = Communication.create!(
            communicable: @lead,
            channel:    'email',
            direction:  'outbound',
            subject:    email_params[:subject],
            body:       email_params[:content],
            status:     'sent',
            sent_at:    Time.current,
            to_address: email_params[:to],
            from_address: email_config[:fromEmail],
            metadata:   build_email_metadata(email_params, email_config).merge(
              message_id: send_result[:message_id]
            )
          )

          render json: { 
            ok: true, 
            success: true,
            id: log.id,
            messageId: send_result[:message_id],
            provider: email_config[:provider] || 'smtp',
            communication: comm_log_json(log)
          }, status: :created
        else
          # Test email without lead - email was sent successfully
          render json: { 
            ok: true, 
            success: true,
            message: 'Test email sent successfully',
            messageId: send_result[:message_id],
            provider: email_config[:provider] || 'smtp',
            to: email_params[:to],
            from: email_config[:fromEmail]
          }, status: :ok
        end
      rescue => e
        Rails.logger.error("[CommunicationsController#send_email] Error: #{e.message}")
        render json: { 
          ok: false, 
          success: false,
          error: e.message,
          details: e.backtrace.first(3)
        }, status: :unprocessable_entity
      end

      # POST /api/crm/leads/:lead_id/communications/sms
      # POST /api/crm/leads/:lead_id/communications/send_sms
      def send_sms
        # Check if SMS is configured
        settings = get_effective_settings
        sms_config = settings.dig(:communications, :sms) || settings.dig('communications', 'sms') || {}
        
        Rails.logger.info "[CommunicationsController#send_sms] SMS config: #{sms_config.inspect}"
        Rails.logger.info "[CommunicationsController#send_sms] SMS configured check: #{sms_configured?(sms_config)}"
        
        unless sms_configured?(sms_config)
          return render json: { 
            ok: false, 
            success: false,
            error: 'SMS is not configured. Please configure SMS settings in Platform or Company Settings.',
            debug: {
              config: sms_config,
              has_provider: sms_config[:provider].present? || sms_config['provider'].present?,
              has_from_number: sms_config[:fromNumber].present? || sms_config['fromNumber'].present?,
              is_enabled: sms_config[:isEnabled] || sms_config['isEnabled']
            }
          }, status: :unprocessable_entity
        end

        # Support multiple parameter formats
        sms_params = extract_sms_params
        
        # Actually send the SMS via Twilio
        send_result = send_sms_via_provider(sms_params[:to], sms_params[:content], sms_config)
        
        unless send_result[:success]
          return render json: {
            ok: false,
            success: false,
            error: send_result[:error] || 'Failed to send SMS'
          }, status: :unprocessable_entity
        end

        # Only create communication log if we have a lead
        # For test SMS (no lead), just return success without creating record
        if @lead.present?
          log = Communication.create!(
            communicable: @lead,
            channel:    'sms',
            direction:  'outbound',
            body:       sms_params[:content],
            status:     'sent',
            sent_at:    Time.current,
            to_address: sms_params[:to],
            from_address: sms_config[:fromNumber],
            metadata:   build_sms_metadata(sms_params, sms_config).merge(
              message_sid: send_result[:message_sid]
            )
          )

          render json: { 
            ok: true, 
            success: true,
            id: log.id, 
            messageId: send_result[:message_sid],
            provider: sms_config[:provider] || 'twilio',
            communication: comm_log_json(log)
          }, status: :created
        else
          # Test SMS without lead - SMS was sent successfully
          render json: { 
            ok: true, 
            success: true,
            message: 'Test SMS sent successfully',
            messageId: send_result[:message_sid],
            provider: sms_config[:provider] || 'twilio',
            to: sms_params[:to],
            from: sms_config[:fromNumber]
          }, status: :ok
        end
      rescue => e
        Rails.logger.error("[CommunicationsController#send_sms] Error: #{e.message}")
        render json: { 
          ok: false, 
          success: false,
          error: e.message,
          details: e.backtrace.first(3)
        }, status: :unprocessable_entity
      end

      # POST /api/crm/leads/:lead_id/communications (generic log creation)
      def create
        log = Communication.create!(log_params)
        render json: comm_log_json(log), status: :created
      rescue => e
        Rails.logger.error("[CommunicationsController#create] Error: #{e.message}")
        render json: { 
          error: e.message,
          details: e.backtrace.first(3)
        }, status: :unprocessable_entity
      end

      # Alias for backward compatibility
      alias_method :create_log, :create

      private

      def set_lead
        @lead = Lead.find(params[:lead_id])
      rescue ActiveRecord::RecordNotFound => e
        render json: { 
          error: 'Lead not found',
          leadId: params[:lead_id]
        }, status: :not_found
      end

      def set_lead_from_params
        lead_id = params[:lead_id] || params[:leadId]
        @lead = Lead.find(lead_id) if lead_id
      rescue ActiveRecord::RecordNotFound => e
        render json: { 
          error: 'Lead not found',
          leadId: lead_id
        }, status: :not_found
      end

      # Get effective communication settings (company overrides platform)
      def get_effective_settings
        platform_settings = fetch_platform_settings
        Rails.logger.info "[get_effective_settings] Platform settings: #{platform_settings.inspect}"
        
        company_settings = fetch_company_settings
        Rails.logger.info "[get_effective_settings] Company settings: #{company_settings.inspect}"
        
        # Deep merge: company settings override platform settings
        result = merge_settings(platform_settings, company_settings)
        Rails.logger.info "[get_effective_settings] Merged result: #{result.inspect}"
        
        result
      rescue => e
        Rails.logger.error("[CommunicationsController] Error fetching settings: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        # Return safe defaults
        {
          communications: {
            email: { isEnabled: false },
            sms: { isEnabled: false }
          }
        }
      end

      def fetch_platform_settings
        # Fetch directly from database instead of HTTP request
        stored = Setting.get('Platform', 0, 'communications')
        Rails.logger.info "[fetch_platform_settings] Raw stored value: #{stored.inspect}"
        return {} unless stored
        
        # If stored is already a hash with the right structure, return it
        if stored.is_a?(Hash)
          result = {
            communications: stored
          }
          Rails.logger.info "[fetch_platform_settings] Returning: #{result.inspect}"
          return result
        end
        
        {}
      rescue => e
        Rails.logger.warn("[CommunicationsController] Could not fetch platform settings: #{e.message}")
        # Return default platform settings
        {
          communications: {
            email: {
              provider: 'smtp',
              fromEmail: 'platform@renterinsight.com',
              fromName: 'RenterInsight Platform',
              isEnabled: true
            },
            sms: {
              provider: 'twilio',
              fromNumber: '+1234567890',
              isEnabled: false
            }
          }
        }
      end

      def fetch_company_settings
        # Make internal request to company settings
        response = Faraday.get("#{request.base_url}/api/company/settings") rescue nil
        return {} unless response&.success?
        
        JSON.parse(response.body, symbolize_names: true) rescue {}
      rescue => e
        Rails.logger.warn("[CommunicationsController] Could not fetch company settings: #{e.message}")
        {}
      end

      def merge_settings(platform, company)
        # Convert all keys to symbols for consistent access
        platform = platform.deep_symbolize_keys if platform.respond_to?(:deep_symbolize_keys)
        company = company.deep_symbolize_keys if company.respond_to?(:deep_symbolize_keys)
        
        result = platform.deep_dup
        
        if company.dig(:communications, :email)
          result[:communications] ||= {}
          result[:communications][:email] ||= {}
          result[:communications][:email].merge!(company[:communications][:email])
        end
        
        if company.dig(:communications, :sms)
          result[:communications] ||= {}
          result[:communications][:sms] ||= {}
          result[:communications][:sms].merge!(company[:communications][:sms])
        end
        
        result
      end

      # Check if email is properly configured
      def email_configured?(config)
        # Handle both string and symbol keys
        is_enabled = config[:isEnabled] || config['isEnabled']
        from_email = config[:fromEmail] || config['fromEmail']
        provider = config[:provider] || config['provider']
        smtp_host = config[:smtpHost] || config['smtpHost']
        
        is_enabled == true &&
        from_email.present? &&
        (provider.present? || smtp_host.present?)
      end

      # Check if SMS is properly configured
      def sms_configured?(config)
        # Handle both string and symbol keys
        is_enabled = config[:isEnabled] || config['isEnabled']
        from_number = config[:fromNumber] || config['fromNumber']
        provider = config[:provider] || config['provider']
        
        is_enabled == true &&
        from_number.present? &&
        provider.present?
      end
      
      # Send SMS via provider (Twilio, AWS SNS, etc.)
      def send_sms_via_provider(to, message, config)
        provider = (config[:provider] || config['provider'] || 'twilio').to_sym
        
        case provider
        when :twilio
          send_sms_via_twilio(to, message, config)
        when :aws_sns
          send_sms_via_aws_sns(to, message, config)
        else
          { success: false, error: "Unknown SMS provider: #{provider}" }
        end
      rescue => e
        Rails.logger.error("[send_sms_via_provider] Error: #{e.message}")
        { success: false, error: e.message }
      end
      
      # Send SMS via Twilio
      def send_sms_via_twilio(to, message, config)
        require 'net/http'
        require 'uri'
        require 'json'
        
        account_sid = config[:twilioAccountSid] || config['twilioAccountSid']
        auth_token = decrypt_if_needed(config[:twilioAuthToken] || config['twilioAuthToken'])
        from_number = config[:fromNumber] || config['fromNumber']
        
        Rails.logger.info "[send_sms_via_twilio] Sending to #{to} from #{from_number}"
        
        uri = URI.parse("https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json")
        
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(account_sid, auth_token)
        request.set_form_data(
          'From' => from_number,
          'To' => to,
          'Body' => message
        )
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        
        result = JSON.parse(response.body)
        
        if response.code.to_i == 201
          Rails.logger.info "[send_sms_via_twilio] Success: #{result['sid']}"
          { 
            success: true, 
            message_sid: result['sid'],
            status: result['status']
          }
        else
          Rails.logger.error "[send_sms_via_twilio] Error: #{result['message']}"
          { 
            success: false, 
            error: result['message'] || 'Twilio API error'
          }
        end
      rescue => e
        Rails.logger.error "[send_sms_via_twilio] Exception: #{e.message}"
        { success: false, error: e.message }
      end
      
      # Send SMS via AWS SNS
      def send_sms_via_aws_sns(to, message, config)
        require 'net/http'
        require 'uri'
        require 'openssl'
        require 'base64'
        require 'time'
        require 'cgi'
        
        access_key = config[:awsAccessKey] || config['awsAccessKey']
        secret_key = decrypt_if_needed(config[:awsSecretKey] || config['awsSecretKey'])
        region = config[:awsRegion] || config['awsRegion'] || 'us-east-1'
        
        unless access_key.present? && secret_key.present?
          return { success: false, error: 'AWS SNS credentials not configured' }
        end
        
        Rails.logger.info "[send_sms_via_aws_sns] Sending to #{to} via region #{region}"
        
        # AWS SNS Publish API call
        host = "sns.#{region}.amazonaws.com"
        endpoint = "https://#{host}/"
        
        # Create AWS Signature V4
        timestamp = Time.now.utc
        date_stamp = timestamp.strftime('%Y%m%d')
        amz_date = timestamp.strftime('%Y%m%dT%H%M%SZ')
        
        payload = {
          'Action' => 'Publish',
          'Version' => '2010-03-31',
          'PhoneNumber' => to,
          'Message' => message
        }
        
        canonical_querystring = payload.sort.map { |k, v| "#{CGI.escape(k.to_s)}=#{CGI.escape(v.to_s)}" }.join('&')
        
        canonical_headers = "host:#{host}\nx-amz-date:#{amz_date}\n"
        signed_headers = 'host;x-amz-date'
        
        canonical_request = [
          'GET',
          '/',
          canonical_querystring,
          canonical_headers,
          signed_headers,
          Digest::SHA256.hexdigest('')
        ].join("\n")
        
        algorithm = 'AWS4-HMAC-SHA256'
        credential_scope = "#{date_stamp}/#{region}/sns/aws4_request"
        string_to_sign = [
          algorithm,
          amz_date,
          credential_scope,
          Digest::SHA256.hexdigest(canonical_request)
        ].join("\n")
        
        # Calculate signature
        k_date = OpenSSL::HMAC.digest('sha256', "AWS4#{secret_key}", date_stamp)
        k_region = OpenSSL::HMAC.digest('sha256', k_date, region)
        k_service = OpenSSL::HMAC.digest('sha256', k_region, 'sns')
        k_signing = OpenSSL::HMAC.digest('sha256', k_service, 'aws4_request')
        signature = OpenSSL::HMAC.hexdigest('sha256', k_signing, string_to_sign)
        
        authorization_header = "#{algorithm} Credential=#{access_key}/#{credential_scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
        
        uri = URI.parse("#{endpoint}?#{canonical_querystring}")
        request = Net::HTTP::Get.new(uri)
        request['Host'] = host
        request['X-Amz-Date'] = amz_date
        request['Authorization'] = authorization_header
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        
        if response.code.to_i == 200
          # Parse MessageId from XML response
          message_id = response.body.match(/<MessageId>(.*?)<\/MessageId>/)[1] rescue SecureRandom.uuid
          Rails.logger.info "[send_sms_via_aws_sns] Success: #{message_id}"
          { 
            success: true, 
            message_sid: message_id,
            status: 'sent'
          }
        else
          # Parse error from XML
          error_msg = response.body.match(/<Message>(.*?)<\/Message>/)[1] rescue 'AWS SNS API error'
          Rails.logger.error "[send_sms_via_aws_sns] Error: #{error_msg}"
          { 
            success: false, 
            error: error_msg
          }
        end
      rescue => e
        Rails.logger.error "[send_sms_via_aws_sns] Exception: #{e.message}"
        { success: false, error: e.message }
      end
      
      # Send email via provider (SMTP, Gmail, SendGrid, AWS SES)
      def send_email_via_provider(email_params, config)
        provider = (config[:provider] || config['provider'] || 'smtp').to_sym
        
        case provider
        when :smtp
          send_email_via_smtp(email_params, config)
        when :gmail
          send_email_via_gmail(email_params, config)
        when :sendgrid
          send_email_via_sendgrid(email_params, config)
        when :aws_ses
          send_email_via_aws_ses(email_params, config)
        else
          { success: false, error: "Unknown email provider: #{provider}" }
        end
      rescue => e
        Rails.logger.error("[send_email_via_provider] Error: #{e.message}")
        { success: false, error: e.message }
      end
      
      # Send email via SMTP
      def send_email_via_smtp(email_params, config)
        require 'net/smtp'
        require 'mail'
        
        host = config[:smtpHost] || config['smtpHost']
        port = (config[:smtpPort] || config['smtpPort'] || 587).to_i
        username = config[:smtpUsername] || config['smtpUsername']
        password = decrypt_if_needed(config[:smtpPassword] || config['smtpPassword'])
        from_email = config[:fromEmail] || config['fromEmail']
        from_name = config[:fromName] || config['fromName']
        
        Rails.logger.info "[send_email_via_smtp] Sending to #{email_params[:to]} via #{host}:#{port}"
        
        mail = Mail.new do
          from     "#{from_name} <#{from_email}>"
          to       email_params[:to]
          subject  email_params[:subject]
          
          # Support both HTML and text content
          if email_params[:content]&.include?('<html') || email_params[:content]&.include?('<body')
            html_part do
              content_type 'text/html; charset=UTF-8'
              body email_params[:content]
            end
          else
            body email_params[:content]
          end
        end
        
        # Add CC and BCC if present
        mail.cc = email_params[:cc] if email_params[:cc].present?
        mail.bcc = email_params[:bcc] if email_params[:bcc].present?
        
        mail.delivery_method :smtp, {
          address: host,
          port: port,
          user_name: username,
          password: password,
          authentication: :plain,
          enable_starttls_auto: port == 587
        }
        
        mail.deliver!
        
        Rails.logger.info "[send_email_via_smtp] Success: #{mail.message_id}"
        { 
          success: true, 
          message_id: mail.message_id
        }
      rescue => e
        Rails.logger.error "[send_email_via_smtp] Exception: #{e.message}"
        { success: false, error: e.message }
      end
      
      # Send email via Gmail OAuth
      def send_email_via_gmail(email_params, config)
        require 'net/http'
        require 'uri'
        require 'json'
        require 'base64'
        
        access_token = decrypt_if_needed(config[:gmailAccessToken] || config['gmailAccessToken'])
        refresh_token = decrypt_if_needed(config[:gmailRefreshToken] || config['gmailRefreshToken'])
        client_id = config[:gmailClientId] || config['gmailClientId']
        client_secret = decrypt_if_needed(config[:gmailClientSecret] || config['gmailClientSecret'])
        from_email = config[:fromEmail] || config['fromEmail']
        from_name = config[:fromName] || config['fromName']
        
        # If access token expired, refresh it
        if access_token.blank? && refresh_token.present?
          Rails.logger.info "[send_email_via_gmail] Refreshing access token"
          token_result = refresh_gmail_token(refresh_token, client_id, client_secret)
          
          if token_result[:success]
            access_token = token_result[:access_token]
            # TODO: Save new access token to database
          else
            return { success: false, error: "Failed to refresh Gmail token: #{token_result[:error]}" }
          end
        end
        
        unless access_token.present?
          return { success: false, error: 'Gmail access token not configured. Please connect your Gmail account.' }
        end
        
        Rails.logger.info "[send_email_via_gmail] Sending to #{email_params[:to]}"
        
        # Create RFC 2822 formatted email
        email_content = create_rfc2822_email(email_params, from_email, from_name)
        
        # Base64url encode the email
        encoded_email = Base64.urlsafe_encode64(email_content).gsub('=', '')
        
        uri = URI.parse('https://gmail.googleapis.com/gmail/v1/users/me/messages/send')
        
        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{access_token}"
        request['Content-Type'] = 'application/json'
        request.body = { raw: encoded_email }.to_json
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        
        result = JSON.parse(response.body) rescue {}
        
        if response.code.to_i == 200
          message_id = result['id']
          Rails.logger.info "[send_email_via_gmail] Success: #{message_id}"
          { 
            success: true, 
            message_id: message_id
          }
        else
          error_msg = result.dig('error', 'message') || 'Gmail API error'
          Rails.logger.error "[send_email_via_gmail] Error: #{error_msg}"
          { 
            success: false, 
            error: error_msg
          }
        end
      rescue => e
        Rails.logger.error "[send_email_via_gmail] Exception: #{e.message}"
        { success: false, error: e.message }
      end
      
      # Refresh Gmail OAuth token
      def refresh_gmail_token(refresh_token, client_id, client_secret)
        uri = URI.parse('https://oauth2.googleapis.com/token')
        
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(
          'client_id' => client_id,
          'client_secret' => client_secret,
          'refresh_token' => refresh_token,
          'grant_type' => 'refresh_token'
        )
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        
        result = JSON.parse(response.body) rescue {}
        
        if response.code.to_i == 200
          { 
            success: true, 
            access_token: result['access_token'],
            expires_in: result['expires_in']
          }
        else
          { 
            success: false, 
            error: result['error_description'] || result['error'] || 'Token refresh failed'
          }
        end
      rescue => e
        { success: false, error: e.message }
      end
      
      # Create RFC 2822 formatted email message
      def create_rfc2822_email(email_params, from_email, from_name)
        lines = []
        lines << "From: #{from_name} <#{from_email}>"
        lines << "To: #{email_params[:to]}"
        lines << "Cc: #{email_params[:cc]}" if email_params[:cc].present?
        lines << "Bcc: #{email_params[:bcc]}" if email_params[:bcc].present?
        lines << "Subject: #{email_params[:subject]}"
        lines << "MIME-Version: 1.0"
        
        # Detect if content is HTML
        if email_params[:content]&.include?('<html') || email_params[:content]&.include?('<body')
          lines << "Content-Type: text/html; charset=utf-8"
        else
          lines << "Content-Type: text/plain; charset=utf-8"
        end
        
        lines << ""
        lines << email_params[:content]
        
        lines.join("\r\n")
      end
      
      # Send email via SendGrid
      def send_email_via_sendgrid(email_params, config)
        require 'net/http'
        require 'uri'
        require 'json'
        
        api_key = decrypt_if_needed(config[:sendgridApiKey] || config['sendgridApiKey'])
        from_email = config[:fromEmail] || config['fromEmail']
        from_name = config[:fromName] || config['fromName']
        
        Rails.logger.info "[send_email_via_sendgrid] Sending to #{email_params[:to]}"
        
        uri = URI.parse('https://api.sendgrid.com/v3/mail/send')
        
        payload = {
          personalizations: [
            {
              to: [{ email: email_params[:to] }],
              subject: email_params[:subject]
            }
          ],
          from: {
            email: from_email,
            name: from_name
          },
          content: [
            {
              type: email_params[:content]&.include?('<') ? 'text/html' : 'text/plain',
              value: email_params[:content]
            }
          ]
        }
        
        # Add CC if present
        if email_params[:cc].present?
          payload[:personalizations][0][:cc] = [{ email: email_params[:cc] }]
        end
        
        # Add BCC if present
        if email_params[:bcc].present?
          payload[:personalizations][0][:bcc] = [{ email: email_params[:bcc] }]
        end
        
        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{api_key}"
        request['Content-Type'] = 'application/json'
        request.body = payload.to_json
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        
        if response.code.to_i == 202
          # SendGrid returns 202 Accepted
          message_id = response['X-Message-Id'] || SecureRandom.uuid
          Rails.logger.info "[send_email_via_sendgrid] Success: #{message_id}"
          { 
            success: true, 
            message_id: message_id
          }
        else
          result = JSON.parse(response.body) rescue {}
          error_msg = result.dig('errors', 0, 'message') || 'SendGrid API error'
          Rails.logger.error "[send_email_via_sendgrid] Error: #{error_msg}"
          { 
            success: false, 
            error: error_msg
          }
        end
      rescue => e
        Rails.logger.error "[send_email_via_sendgrid] Exception: #{e.message}"
        { success: false, error: e.message }
      end
      
      # Send email via AWS SES
      def send_email_via_aws_ses(email_params, config)
        require 'net/http'
        require 'uri'
        require 'openssl'
        require 'base64'
        require 'time'
        
        access_key = config[:awsAccessKey] || config['awsAccessKey']
        secret_key = decrypt_if_needed(config[:awsSecretKey] || config['awsSecretKey'])
        region = config[:awsRegion] || config['awsRegion'] || 'us-east-1'
        from_email = config[:fromEmail] || config['fromEmail']
        from_name = config[:fromName] || config['fromName']
        
        unless access_key.present? && secret_key.present?
          return { success: false, error: 'AWS SES credentials not configured' }
        end
        
        Rails.logger.info "[send_email_via_aws_ses] Sending to #{email_params[:to]} via region #{region}"
        
        # Prepare email content
        email_content = create_rfc2822_email(email_params, from_email, from_name)
        
        # AWS SES SendRawEmail API call
        host = "email.#{region}.amazonaws.com"
        endpoint = "https://#{host}/"
        
        # Create AWS Signature V4
        timestamp = Time.now.utc
        date_stamp = timestamp.strftime('%Y%m%d')
        amz_date = timestamp.strftime('%Y%m%dT%H%M%SZ')
        
        payload = {
          'Action' => 'SendRawEmail',
          'Version' => '2010-12-01',
          'RawMessage.Data' => Base64.strict_encode64(email_content)
        }
        
        # Add destinations
        destinations = [email_params[:to]]
        destinations << email_params[:cc] if email_params[:cc].present?
        destinations << email_params[:bcc] if email_params[:bcc].present?
        
        destinations.flatten.each_with_index do |dest, i|
          payload["Destinations.member.#{i + 1}"] = dest
        end
        
        canonical_querystring = payload.sort.map { |k, v| "#{CGI.escape(k.to_s)}=#{CGI.escape(v.to_s)}" }.join('&')
        
        canonical_headers = "host:#{host}\nx-amz-date:#{amz_date}\n"
        signed_headers = 'host;x-amz-date'
        
        canonical_request = [
          'GET',
          '/',
          canonical_querystring,
          canonical_headers,
          signed_headers,
          Digest::SHA256.hexdigest('')
        ].join("\n")
        
        algorithm = 'AWS4-HMAC-SHA256'
        credential_scope = "#{date_stamp}/#{region}/ses/aws4_request"
        string_to_sign = [
          algorithm,
          amz_date,
          credential_scope,
          Digest::SHA256.hexdigest(canonical_request)
        ].join("\n")
        
        # Calculate signature
        k_date = OpenSSL::HMAC.digest('sha256', "AWS4#{secret_key}", date_stamp)
        k_region = OpenSSL::HMAC.digest('sha256', k_date, region)
        k_service = OpenSSL::HMAC.digest('sha256', k_region, 'ses')
        k_signing = OpenSSL::HMAC.digest('sha256', k_service, 'aws4_request')
        signature = OpenSSL::HMAC.hexdigest('sha256', k_signing, string_to_sign)
        
        authorization_header = "#{algorithm} Credential=#{access_key}/#{credential_scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
        
        uri = URI.parse("#{endpoint}?#{canonical_querystring}")
        request = Net::HTTP::Get.new(uri)
        request['Host'] = host
        request['X-Amz-Date'] = amz_date
        request['Authorization'] = authorization_header
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        
        if response.code.to_i == 200
          # Parse MessageId from XML response
          message_id = response.body.match(/<MessageId>(.*?)<\/MessageId>/)[1] rescue SecureRandom.uuid
          Rails.logger.info "[send_email_via_aws_ses] Success: #{message_id}"
          { 
            success: true, 
            message_id: message_id
          }
        else
          # Parse error from XML
          error_msg = response.body.match(/<Message>(.*?)<\/Message>/)[1] rescue 'AWS SES API error'
          Rails.logger.error "[send_email_via_aws_ses] Error: #{error_msg}"
          { 
            success: false, 
            error: error_msg
          }
        end
      rescue => e
        Rails.logger.error "[send_email_via_aws_ses] Exception: #{e.message}"
        { success: false, error: e.message }
      end
      
      # Decrypt if value is encrypted
      def decrypt_if_needed(value)
        return value unless value.present?
        return value unless value.to_s.start_with?('encrypted:')
        
        encrypted_value = value.to_s.sub('encrypted:', '')
        decrypt(encrypted_value)
      rescue => e
        Rails.logger.error("[decrypt_if_needed] Error: #{e.message}")
        value
      end
      
      # Decrypt encrypted value
      def decrypt(encrypted_value)
        secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
        key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
        crypt = ActiveSupport::MessageEncryptor.new(key)
        crypt.decrypt_and_verify(encrypted_value)
      rescue => e
        Rails.logger.error("[decrypt] Error: #{e.message}")
        nil
      end

      # Extract email parameters from various possible formats
      def extract_email_params
        # Try nested :email key first
        if params[:email].present?
          email_data = params[:email]
          {
            subject: email_data[:subject],
            content: email_data[:body] || email_data[:html] || email_data[:content],
            to: email_data[:to] || @lead&.email,
            template_id: email_data[:template_id] || email_data[:templateId],
            cc: email_data[:cc],
            bcc: email_data[:bcc],
            attachments: email_data[:attachments]
          }
        else
          # Fall back to root-level parameters
          {
            subject: params[:subject],
            content: params[:body] || params[:html] || params[:content],
            to: params[:to] || @lead&.email,
            template_id: params[:template_id] || params[:templateId],
            cc: params[:cc],
            bcc: params[:bcc],
            attachments: params[:attachments]
          }
        end
      end

      # Extract SMS parameters from various possible formats
      def extract_sms_params
        # Try nested :sms key first
        if params[:sms].present?
          sms_data = params[:sms]
          {
            content: sms_data[:message] || sms_data[:content] || sms_data[:body],
            to: sms_data[:to] || @lead&.phone,
            template_id: sms_data[:template_id] || sms_data[:templateId]
          }
        else
          # Fall back to root-level parameters
          {
            content: params[:message] || params[:content] || params[:body],
            to: params[:to] || @lead&.phone,
            template_id: params[:template_id] || params[:templateId]
          }
        end
      end

      # Build email metadata
      def build_email_metadata(email_params, config = {})
        {
          provider: config[:provider] || 'smtp',
          template_id: email_params[:template_id],
          to: email_params[:to],
          cc: email_params[:cc],
          bcc: email_params[:bcc],
          has_attachments: email_params[:attachments].present?,
          from_email: config[:fromEmail],
          from_name: config[:fromName]
        }.compact
      end

      # Build SMS metadata
      def build_sms_metadata(sms_params, config = {})
        {
          provider: config[:provider] || 'twilio',
          template_id: sms_params[:template_id],
          to: sms_params[:to],
          character_count: sms_params[:content]&.length,
          from_number: config[:fromNumber]
        }.compact
      end

      # Strong parameters for generic log creation
      def log_params
        {
          communicable: @lead,
          channel:      params[:type] || params[:comm_type] || params[:commType] || 'email',
          direction:    params[:direction] || 'outbound',
          subject:      params[:subject],
          body:         params[:content] || params[:body] || params[:message],
          status:       params[:status].presence || 'sent',
          sent_at:      parse_time(params[:sent_at] || params[:sentAt]) || Time.current,
          delivered_at: parse_time(params[:delivered_at] || params[:deliveredAt]),
          opened_at:    parse_time(params[:opened_at] || params[:openedAt]),
          to_address:   params[:to] || @lead&.email,
          from_address: params[:from],
          metadata:     extract_metadata
        }.compact
      end

      # Extract metadata from params
      def extract_metadata
        if params[:metadata].present?
          params[:metadata].is_a?(Hash) ? params[:metadata] : {}
        else
          {}
        end
      end

      # Consistent JSON serialization for communication logs
      def comm_log_json(comm)
        {
          id:          comm.id,
          leadId:      comm.communicable_id,
          type:        comm.channel,
          commType:    comm.channel,
          direction:   comm.direction,
          subject:     comm.subject,
          content:     comm.body,
          status:      comm.status,
          sentAt:      comm.sent_at&.iso8601,
          deliveredAt: comm.delivered_at&.iso8601,
          openedAt:    comm.opened_at&.iso8601,
          metadata:    comm.metadata || {},
          createdAt:   comm.created_at&.iso8601,
          updatedAt:   comm.updated_at&.iso8601
        }.compact
      end

      # Parse time strings safely
      def parse_time(value)
        return nil if value.blank?
        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
