# frozen_string_literal: true
module Api
  module Crm
    class CommunicationsController < ApplicationController
      include RbacAuthorization
      rbac_resource :communications,
        read_actions: [:index],
        create_actions: [:create, :create_log, :email, :sms, :send_email, :send_sms],
        update_actions: [],
        delete_actions: []
      
      before_action :set_company_scope
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
        # USER EMAIL CONNECTION WATERFALL: Check if user has their own email connection first
        if current_user&.has_email_connection?
          Rails.logger.info "[CommunicationsController#send_email] Using user #{current_user.id} email connection"
          return send_email_via_user_connection
        end

        # Check if email is configured (company/platform waterfall)
        settings = get_effective_settings
        email_config = settings.dig(:communications, :email) || settings.dig('communications', 'email') || {}

        Rails.logger.info "[CommunicationsController#send_email] Email config provider: #{email_config[:provider] || email_config['provider']}"

        unless email_configured?(email_config)
          return render json: {
            ok: false,
            success: false,
            error: 'Email is not configured. Please configure email settings in Platform or Company Settings.'
          }, status: :unprocessable_entity
        end

        # Support multiple parameter formats
        email_params = extract_email_params

        # Generate reply-to address for tracking
        reply_to = generate_reply_to_address

        # Actually send the email via provider (with reply_to)
        send_result = send_email_via_provider(email_params, email_config, reply_to: reply_to)

        unless send_result[:success]
          return render json: {
            ok: false,
            success: false,
            error: send_result[:error] || 'Failed to send email'
          }, status: :unprocessable_entity
        end

        from_addr = email_config[:fromEmail] || email_config['fromEmail'] || email_config[:oauthEmail] || email_config['oauthEmail']

        # Only create communication log if we have a lead
        if @lead.present?
          log = Communication.create!(
            communicable: @lead,
            company_id: @company&.id,
            channel:    'email',
            direction:  'outbound',
            subject:    email_params[:subject],
            body:       email_params[:content],
            status:     'sent',
            sent_at:    Time.current,
            to_address: email_params[:to],
            from_address: from_addr,
            reply_to:   reply_to,
            metadata:   build_email_metadata(email_params, email_config).merge(
              message_id: send_result[:message_id]
            )
          )

          render json: {
            ok: true,
            success: true,
            id: log.id,
            messageId: send_result[:message_id],
            provider: email_config[:provider] || email_config['provider'] || 'smtp',
            communication: comm_log_json(log)
          }, status: :created
        else
          render json: {
            ok: true,
            success: true,
            message: 'Test email sent successfully',
            messageId: send_result[:message_id],
            provider: email_config[:provider] || email_config['provider'] || 'smtp',
            to: email_params[:to],
            from: from_addr
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
        # Check if SMS is configured.
        # NOTE: previously used the controller's local get_effective_settings waterfall,
        # which returned the platform fromNumber even when the company had its own
        # dedicated number. CommunicationSettingsService applies the correct
        # Location → Company → Platform waterfall (and decrypts the auth token),
        # so we delegate to it and remap to the camelCase keys the rest of
        # send_sms_via_twilio / sms_configured? already expect.
        comm_service = CommunicationSettingsService.for_company(@company)
        sms_cfg      = comm_service.sms_config
        sms_config = {
          provider:                  sms_cfg[:provider] || 'twilio',
          fromNumber:                sms_cfg[:from_number],
          isEnabled:                 sms_cfg[:enabled],
          twilioAccountSid:          sms_cfg[:twilio_account_sid],
          twilioAuthToken:           sms_cfg[:twilio_auth_token],
          twilioMessagingServiceSid: sms_cfg[:twilio_messaging_service_sid]
        }.compact

        Rails.logger.info "[CommunicationsController#send_sms] SMS config via CommSettingsService: fromNumber=#{sms_config[:fromNumber]}"
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
            company_id: @company&.id,
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

      def set_company_scope
        unless current_user
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
      end

      def set_lead
        # STRICT TENANT ISOLATION: Only access leads in same company
        @lead = @company.leads.find_by(id: params[:lead_id])
        unless @lead
          render json: { 
            error: 'Lead not found or access denied',
            leadId: params[:lead_id]
          }, status: :not_found
          return
        end
      end

      def set_lead_from_params
        lead_id = params[:lead_id] || params[:leadId]
        return unless lead_id.present?
        
        # STRICT TENANT ISOLATION: Only access leads in same company
        @lead = @company.leads.find_by(id: lead_id)
        unless @lead
          render json: { 
            error: 'Lead not found or access denied',
            leadId: lead_id
          }, status: :not_found
          return
        end
      end

      # Get effective communication settings with 4-level waterfall:
      # User → Location → Company → Platform
      def get_effective_settings
        platform_settings = fetch_platform_settings
        company_settings = fetch_company_settings
        location_settings = fetch_location_settings

        Rails.logger.info "[get_effective_settings] Waterfall check:"
        Rails.logger.info "  - Platform: #{platform_settings.dig(:communications, :email, :provider) || 'none'}"
        Rails.logger.info "  - Company: #{company_settings.dig(:communications, :email, :provider) || 'none'}"
        Rails.logger.info "  - Location: #{location_settings.dig(:communications, :email, :provider) || 'none'}"

        # Start with platform (lowest priority)
        result = platform_settings.deep_dup

        # Merge company (overrides platform)
        result = merge_settings(result, company_settings) if company_settings.present?

        # Merge location (overrides company)
        result = merge_settings(result, location_settings) if location_settings.present?

        Rails.logger.info "[get_effective_settings] Merged result provider: #{result.dig(:communications, :email, :provider)}"

        result
      rescue => e
        Rails.logger.error("[CommunicationsController] Error fetching settings: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        {
          communications: {
            email: { isEnabled: false },
            sms: { isEnabled: false }
          }
        }
      end

      def fetch_platform_settings
        stored = Setting.get('Platform', 0, 'communications')
        return {} unless stored.is_a?(Hash)

        { communications: stored.deep_symbolize_keys }
      rescue => e
        Rails.logger.warn("[CommunicationsController] Could not fetch platform settings: #{e.message}")
        {}
      end

      def fetch_company_settings
        return {} unless @company

        stored = Setting.get('Company', @company.id, 'communications')
        return {} unless stored.is_a?(Hash)

        { communications: stored.deep_symbolize_keys }
      rescue => e
        Rails.logger.warn("[CommunicationsController] Could not fetch company settings: #{e.message}")
        {}
      end

      def fetch_location_settings
        location_id = Current.location_id
        return {} unless location_id.present?

        stored = Setting.get('Location', location_id, 'communications')
        return {} unless stored.is_a?(Hash)

        { communications: stored.deep_symbolize_keys }
      rescue => e
        Rails.logger.warn("[CommunicationsController] Could not fetch location settings: #{e.message}")
        {}
      end

      def merge_settings(base, override)
        base = base.deep_symbolize_keys if base.respond_to?(:deep_symbolize_keys)
        override = override.deep_symbolize_keys if override.respond_to?(:deep_symbolize_keys)

        result = base.deep_dup

        if override.dig(:communications, :email)
          result[:communications] ||= {}
          result[:communications][:email] ||= {}
          result[:communications][:email] = result[:communications][:email].deep_merge(override[:communications][:email])
        end

        if override.dig(:communications, :sms)
          result[:communications] ||= {}
          result[:communications][:sms] ||= {}
          result[:communications][:sms] = result[:communications][:sms].deep_merge(override[:communications][:sms])
        end

        result
      end

      # Check if email is properly configured
      def email_configured?(config)
        # Handle both string and symbol keys
        is_enabled = config[:isEnabled] || config['isEnabled']
        from_email = config[:fromEmail] || config['fromEmail'] || config[:oauthEmail] || config['oauthEmail']
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
        
        account_sid           = config[:twilioAccountSid]          || config['twilioAccountSid']          || ENV['TWILIO_ACCOUNT_SID']
        auth_token            = decrypt_if_needed(config[:twilioAuthToken] || config['twilioAuthToken']) || ENV['TWILIO_AUTH_TOKEN']
        from_number           = config[:fromNumber]                || config['fromNumber']                || ENV['TWILIO_PHONE_NUMBER']
        messaging_service_sid = config[:twilioMessagingServiceSid] || config['twilioMessagingServiceSid'] || ENV['TWILIO_MESSAGING_SERVICE_SID']
        
        if messaging_service_sid.present?
          Rails.logger.info "[send_sms_via_twilio] Sending to #{to} via MessagingService #{messaging_service_sid}"
        else
          Rails.logger.info "[send_sms_via_twilio] Sending to #{to} from #{from_number} (no MessagingService)"
        end
        
        uri = URI.parse("https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json")
        
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(account_sid, auth_token)
        
        # A2P 10DLC compliance: send with BOTH MessagingServiceSid AND From.
        # MessagingServiceSid satisfies carrier A2P requirements (routes through
        # the registered campaign). From ensures the message goes out from the
        # company's dedicated number, not a random number from the pool.
        # Twilio supports both fields together when the From number is in the pool.
        form_data = { 'To' => to, 'Body' => message }
        if messaging_service_sid.present? && from_number.present?
          form_data['MessagingServiceSid'] = messaging_service_sid
          form_data['From'] = from_number
        elsif messaging_service_sid.present?
          form_data['MessagingServiceSid'] = messaging_service_sid
        else
          form_data['From'] = from_number
        end
        
        request.set_form_data(form_data)
        
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
      
      # Send email via user's personal email connection
      def send_email_via_user_connection
        email_params = extract_email_params
        connection = current_user.default_email_connection
        user_config = CommunicationSettingsService.for_user(current_user).email_config

        Rails.logger.info "[send_email_via_user_connection] User #{current_user.id} provider: #{connection&.provider}, config: #{user_config.except(:smtp_password).inspect}"

        # Generate reply-to address for tracking
        reply_to = generate_reply_to_address

        # Route based on connection type (SMTP vs OAuth)
        if connection&.provider == 'oauth_outlook'
          # Microsoft 365: use Graph API (SMTP blocked on Render / M365 SMTP AUTH disabled)
          send_result = send_email_via_microsoft_graph(email_params, connection, reply_to: reply_to)
          used_provider = 'microsoft_graph'
        elsif connection&.oauth_provider?
          oauth_config = {
            oauthProvider: connection.provider == 'oauth_gmail' ? 'google' : 'microsoft',
            oauthEmail: connection.email_address,
            oauthAccessToken: connection.oauth_token_encrypted,
            oauthRefreshToken: connection.oauth_refresh_token_encrypted,
            oauthExpiresAt: connection.oauth_expires_at&.iso8601,
            fromEmail: connection.email_address,
            fromName: connection.display_name || current_user.full_name,
            provider: connection.provider == 'oauth_gmail' ? 'oauth_google' : 'oauth_microsoft'
          }
          send_result = send_email_via_oauth_smtp(email_params, oauth_config, reply_to: reply_to)
          used_provider = oauth_config[:provider]
        else
          smtp_config = {
            smtpHost: user_config[:smtp_server],
            smtpPort: user_config[:smtp_port],
            smtpUsername: user_config[:smtp_username],
            smtpPassword: user_config[:smtp_password],
            fromEmail: user_config[:from_email],
            fromName: user_config[:from_name] || current_user.full_name,
            provider: 'smtp'
          }
          send_result = send_email_via_smtp(email_params, smtp_config, reply_to: reply_to)
          used_provider = 'smtp'
        end

        from_addr = user_config[:from_email] || connection&.email_address

        unless send_result[:success]
          return render json: {
            ok: false,
            success: false,
            error: send_result[:error] || 'Failed to send email via user connection'
          }, status: :unprocessable_entity
        end

        if @lead.present?
          log = Communication.create!(
            communicable: @lead,
            company_id: @company&.id,
            channel: 'email',
            direction: 'outbound',
            subject: email_params[:subject],
            body: email_params[:content],
            status: 'sent',
            sent_at: Time.current,
            to_address: email_params[:to],
            from_address: from_addr,
            reply_to: reply_to,
            metadata: build_email_metadata(email_params, { fromEmail: from_addr }).merge(
              message_id: send_result[:message_id],
              sent_by_user_id: current_user.id,
              user_email_connection: true,
              provider: used_provider
            )
          )

          render json: {
            ok: true,
            success: true,
            id: log.id,
            messageId: send_result[:message_id],
            provider: used_provider,
            userEmailConnection: true,
            communication: comm_log_json(log)
          }, status: :created
        else
          render json: {
            ok: true,
            success: true,
            message: 'Test email sent via user connection',
            messageId: send_result[:message_id],
            provider: used_provider,
            userEmailConnection: true,
            to: email_params[:to],
            from: from_addr
          }, status: :ok
        end
      rescue => e
        Rails.logger.error "[send_email_via_user_connection] Error: #{e.message}"
        render json: {
          ok: false,
          success: false,
          error: e.message
        }, status: :unprocessable_entity
      end
      
      # Send email via provider (SMTP, Gmail, SendGrid, AWS SES, OAuth)
      def send_email_via_provider(email_params, config, reply_to: nil)
        provider = (config[:provider] || config['provider'] || 'smtp').to_sym

        case provider
        when :smtp
          send_email_via_smtp(email_params, config, reply_to: reply_to)
        when :gmail
          send_email_via_gmail(email_params, config, reply_to: reply_to)
        when :sendgrid
          send_email_via_sendgrid(email_params, config)
        when :aws_ses
          send_email_via_aws_ses(email_params, config)
        when :oauth_microsoft
          send_email_via_graph_from_config(email_params, config, reply_to: reply_to)
        when :oauth_google
          send_email_via_oauth_smtp(email_params, config, reply_to: reply_to)
        else
          { success: false, error: "Unknown email provider: #{provider}" }
        end
      rescue => e
        Rails.logger.error("[send_email_via_provider] Error: #{e.message}")
        { success: false, error: e.message }
      end
      
      # Send email via SMTP
      def send_email_via_smtp(email_params, config, reply_to: nil)
        require 'net/smtp'
        require 'mail'

        host = config[:smtpHost] || config['smtpHost']
        port = (config[:smtpPort] || config['smtpPort'] || 587).to_i
        username = config[:smtpUsername] || config['smtpUsername']
        raw_password = config[:smtpPassword] || config['smtpPassword']
        password = decrypt_if_needed(raw_password)

        from_email = config[:fromEmail] || config['fromEmail']
        from_name = config[:fromName] || config['fromName']

        Rails.logger.info "[send_email_via_smtp] Sending to #{email_params[:to]} via #{host}:#{port}, reply_to: #{reply_to}"

        mail = Mail.new do
          from     "#{from_name} <#{from_email}>"
          to       email_params[:to]
          subject  email_params[:subject]

          if email_params[:content]&.include?('<html') || email_params[:content]&.include?('<body')
            html_part do
              content_type 'text/html; charset=UTF-8'
              body email_params[:content]
            end
          else
            body email_params[:content]
          end
        end

        mail.reply_to = reply_to if reply_to.present?
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
        { success: true, message_id: mail.message_id }
      rescue => e
        Rails.logger.error "[send_email_via_smtp] Exception: #{e.message}"
        { success: false, error: e.message }
      end

      # Send email via OAuth SMTP (Microsoft 365 / Google) using XOAUTH2
      def send_email_via_oauth_smtp(email_params, config, reply_to: nil)
        require 'mail'

        oauth_provider = config[:oauthProvider] || config['oauthProvider']
        oauth_email    = config[:oauthEmail] || config['oauthEmail']
        access_token   = config[:oauthAccessToken] || config['oauthAccessToken']

        # Refresh token if near expiry
        oauth_expires = config[:oauthExpiresAt] || config['oauthExpiresAt']
        if oauth_expires.present?
          expires_at = Time.parse(oauth_expires.to_s) rescue nil
          if expires_at && expires_at <= 5.minutes.from_now
            refresh_token = config[:oauthRefreshToken] || config['oauthRefreshToken']
            refreshed = refresh_oauth_access_token_for_send(oauth_provider, refresh_token)
            access_token = refreshed if refreshed
          end
        end

        from_email = config[:fromEmail] || config['fromEmail'] || oauth_email
        from_name  = config[:fromName] || config['fromName'] || oauth_email

        unless oauth_email.present? && access_token.present?
          return { success: false, error: "OAuth email not configured: email=#{oauth_email.present?}, token=#{access_token.present?}" }
        end

        smtp_host, smtp_port = case oauth_provider.to_s
                               when 'microsoft' then ['smtp.office365.com', 587]
                               when 'google'    then ['smtp.gmail.com', 587]
                               else ['smtp.gmail.com', 587]
                               end

        Rails.logger.info "[send_email_via_oauth_smtp] Sending to #{email_params[:to]} via #{smtp_host}:#{smtp_port} as #{oauth_email}, reply_to: #{reply_to}"

        mail = Mail.new do
          from     "#{from_name} <#{from_email}>"
          to       email_params[:to]
          subject  email_params[:subject]

          if email_params[:content]&.include?('<html') || email_params[:content]&.include?('<body')
            html_part do
              content_type 'text/html; charset=UTF-8'
              body email_params[:content]
            end
          else
            body email_params[:content]
          end
        end

        mail.reply_to = reply_to if reply_to.present?
        mail.cc = email_params[:cc] if email_params[:cc].present?
        mail.bcc = email_params[:bcc] if email_params[:bcc].present?

        mail.delivery_method :smtp, {
          address: smtp_host,
          port: smtp_port,
          user_name: oauth_email,
          password: access_token,
          authentication: :xoauth2,
          enable_starttls_auto: true
        }

        mail.deliver!

        Rails.logger.info "[send_email_via_oauth_smtp] Success: #{mail.message_id}"
        { success: true, message_id: mail.message_id }
      rescue => e
        Rails.logger.error "[send_email_via_oauth_smtp] Exception: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        { success: false, error: e.message }
      end

      # Send email via Microsoft Graph from a config hash (company/platform-level OAuth Microsoft)
      def send_email_via_graph_from_config(email_params, config, reply_to: nil)
        oauth_email = config[:oauthEmail] || config['oauthEmail'] || config[:fromEmail] || config['fromEmail']
        access_token = config[:oauthAccessToken] || config['oauthAccessToken']

        # Refresh token if near expiry (use Graph scope for Microsoft)
        oauth_expires = config[:oauthExpiresAt] || config['oauthExpiresAt']
        if oauth_expires.present?
          expires_at = Time.parse(oauth_expires.to_s) rescue nil
          if expires_at && expires_at <= 5.minutes.from_now
            oauth_provider = config[:oauthProvider] || config['oauthProvider']
            refresh_token = config[:oauthRefreshToken] || config['oauthRefreshToken']
            graph_scope = oauth_provider.to_s == 'microsoft' ? GRAPH_SCOPE : nil
            refreshed = refresh_oauth_access_token_for_send(oauth_provider, refresh_token, scope: graph_scope)
            access_token = refreshed if refreshed
          end
        end

        unless oauth_email.present? && access_token.present?
          return { success: false, error: "Microsoft Graph not configured: email=#{oauth_email.present?}, token=#{access_token.present?}" }
        end

        from_name = config[:fromName] || config['fromName'] || oauth_email
        # Build a minimal connection-like context and delegate
        mock_params = email_params.merge(to: email_params[:to])
        is_html = email_params[:content]&.include?('<') && (email_params[:content]&.include?('</') || email_params[:content]&.include?('/>'))

        message = {
          subject: email_params[:subject],
          body: { contentType: is_html ? 'HTML' : 'Text', content: email_params[:content] },
          from: { emailAddress: { address: oauth_email, name: from_name } },
          toRecipients: Array(email_params[:to]).flat_map { |a| a.to_s.split(',').map(&:strip) }.reject(&:blank?).map { |e| { emailAddress: { address: e } } }
        }

        message[:ccRecipients] = email_params[:cc].to_s.split(',').map(&:strip).reject(&:blank?).map { |e| { emailAddress: { address: e } } } if email_params[:cc].present?
        message[:bccRecipients] = email_params[:bcc].to_s.split(',').map(&:strip).reject(&:blank?).map { |e| { emailAddress: { address: e } } } if email_params[:bcc].present?
        message[:replyTo] = reply_to.to_s.split(',').map(&:strip).reject(&:blank?).map { |e| { emailAddress: { address: e } } } if reply_to.present?

        payload = { message: message, saveToSentItems: true }

        Rails.logger.info "[send_email_via_graph_from_config] Sending to #{email_params[:to]} as #{oauth_email}"

        uri = URI('https://graph.microsoft.com/v1.0/me/sendMail')
        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{access_token}"
        request['Content-Type'] = 'application/json'
        request.body = payload.to_json

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
          http.request(request)
        end

        # Handle 401 - token may have wrong audience (SMTP scope vs Graph scope)
        if response.code.to_i == 401
          Rails.logger.warn "[send_email_via_graph_from_config] 401 Unauthorized - refreshing with Graph scope"
          oauth_provider = config[:oauthProvider] || config['oauthProvider']
          refresh_token = config[:oauthRefreshToken] || config['oauthRefreshToken']
          new_token = refresh_oauth_access_token_for_send(oauth_provider, refresh_token, scope: GRAPH_SCOPE)
          if new_token
            request = Net::HTTP::Post.new(uri)
            request['Authorization'] = "Bearer #{new_token}"
            request['Content-Type'] = 'application/json'
            request.body = payload.to_json
            response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
              http.request(request)
            end
          end
        end

        if response.code.to_i == 202
          Rails.logger.info "[send_email_via_graph_from_config] Success"
          { success: true, message_id: response['x-ms-request-id'] || "graph-#{SecureRandom.hex(8)}" }
        else
          error_msg = begin
            JSON.parse(response.body).dig('error', 'message')
          rescue
            response.body.to_s.truncate(200)
          end
          Rails.logger.error "[send_email_via_graph_from_config] Failed (#{response.code}): #{error_msg}"
          { success: false, error: "Microsoft Graph API error (#{response.code}): #{error_msg}" }
        end
      rescue => e
        Rails.logger.error "[send_email_via_graph_from_config] Exception: #{e.message}"
        { success: false, error: e.message }
      end

      GRAPH_SCOPE = 'https://graph.microsoft.com/Mail.Send offline_access'.freeze

      # Send email via Microsoft Graph API (avoids SMTP port blocking and SMTP AUTH issues)
      def send_email_via_microsoft_graph(email_params, connection, reply_to: nil)
        Rails.logger.info "[send_email_via_microsoft_graph] Sending to #{email_params[:to]} as #{connection.email_address}"

        # Ensure valid token (refresh with Graph scope if expired)
        access_token = connection.oauth_token_encrypted
        if connection.oauth_token_expired?
          refreshed = connection.refresh_oauth_token!(scope: GRAPH_SCOPE)
          access_token = refreshed if refreshed
        end

        unless access_token.present?
          return { success: false, error: 'No valid OAuth access token for Microsoft Graph' }
        end

        from_name = connection.display_name || current_user.full_name
        is_html = email_params[:content]&.include?('<') && (email_params[:content]&.include?('</') || email_params[:content]&.include?('/>'))

        message = {
          subject: email_params[:subject],
          body: {
            contentType: is_html ? 'HTML' : 'Text',
            content: email_params[:content]
          },
          from: {
            emailAddress: { address: connection.email_address, name: from_name }
          },
          toRecipients: Array(email_params[:to]).flat_map { |a| a.to_s.split(',').map(&:strip) }.reject(&:blank?).map { |e| { emailAddress: { address: e } } }
        }

        message[:ccRecipients] = email_params[:cc].to_s.split(',').map(&:strip).reject(&:blank?).map { |e| { emailAddress: { address: e } } } if email_params[:cc].present?
        message[:bccRecipients] = email_params[:bcc].to_s.split(',').map(&:strip).reject(&:blank?).map { |e| { emailAddress: { address: e } } } if email_params[:bcc].present?
        message[:replyTo] = reply_to.to_s.split(',').map(&:strip).reject(&:blank?).map { |e| { emailAddress: { address: e } } } if reply_to.present?

        payload = { message: message, saveToSentItems: true }

        uri = URI('https://graph.microsoft.com/v1.0/me/sendMail')
        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{access_token}"
        request['Content-Type'] = 'application/json'
        request.body = payload.to_json

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
          http.request(request)
        end

        # Handle 401 - token may have wrong audience (SMTP scope vs Graph scope)
        if response.code.to_i == 401
          Rails.logger.warn "[send_email_via_microsoft_graph] 401 Unauthorized - refreshing with Graph scope"
          new_token = connection.refresh_oauth_token_for_graph!
          if new_token
            request = Net::HTTP::Post.new(uri)
            request['Authorization'] = "Bearer #{new_token}"
            request['Content-Type'] = 'application/json'
            request.body = payload.to_json
            response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
              http.request(request)
            end
          end
        end

        if response.code.to_i == 202
          Rails.logger.info "[send_email_via_microsoft_graph] Success"
          connection.record_usage!
          { success: true, message_id: response['x-ms-request-id'] || "graph-#{SecureRandom.hex(8)}" }
        else
          error_msg = begin
            JSON.parse(response.body).dig('error', 'message')
          rescue
            response.body.to_s.truncate(200)
          end
          Rails.logger.error "[send_email_via_microsoft_graph] Failed (#{response.code}): #{error_msg}"
          connection.record_error!(error_msg)
          { success: false, error: "Microsoft Graph API error (#{response.code}): #{error_msg}" }
        end
      rescue => e
        Rails.logger.error "[send_email_via_microsoft_graph] Exception: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        { success: false, error: e.message }
      end

      def refresh_oauth_access_token_for_send(provider, refresh_token, scope: nil)
        return nil if refresh_token.blank?

        token_url = case provider.to_s
                    when 'microsoft' then 'https://login.microsoftonline.com/common/oauth2/v2.0/token'
                    when 'google'    then 'https://oauth2.googleapis.com/token'
                    else return nil
                    end

        client_id     = ENV["#{provider.upcase}_OAUTH_CLIENT_ID"] ||
                        Rails.application.credentials.dig(:oauth, provider.to_sym, :client_id)
        client_secret = ENV["#{provider.upcase}_OAUTH_CLIENT_SECRET"] ||
                        Rails.application.credentials.dig(:oauth, provider.to_sym, :client_secret)

        form_data = {
          client_id:     client_id,
          client_secret: client_secret,
          refresh_token: refresh_token,
          grant_type:    'refresh_token'
        }
        form_data[:scope] = scope if scope.present?

        uri = URI(token_url)
        req = Net::HTTP::Post.new(uri)
        req.set_form_data(form_data)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
        tokens = JSON.parse(res.body)

        return nil if tokens['error'].present?

        tokens['access_token']
      rescue => e
        Rails.logger.error "[Crm::CommunicationsController] OAuth token refresh failed: #{e.message}"
        nil
      end

      # Send email via Gmail OAuth
      def send_email_via_gmail(email_params, config, reply_to: nil)
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
          else
            return { success: false, error: "Failed to refresh Gmail token: #{token_result[:error]}" }
          end
        end

        unless access_token.present?
          return { success: false, error: 'Gmail access token not configured. Please connect your Gmail account.' }
        end

        Rails.logger.info "[send_email_via_gmail] Sending to #{email_params[:to]}, reply_to: #{reply_to}"

        # Create RFC 2822 formatted email
        email_content = create_rfc2822_email(email_params, from_email, from_name, reply_to: reply_to)
        
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
      def create_rfc2822_email(email_params, from_email, from_name, reply_to: nil)
        lines = []
        lines << "From: #{from_name} <#{from_email}>"
        lines << "To: #{email_params[:to]}"
        lines << "Reply-To: #{reply_to}" if reply_to.present?
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
        Rails.logger.info "[decrypt_if_needed] Input value: #{value.inspect[0..100]}"
        
        return value unless value.present?
        
        unless value.to_s.start_with?('encrypted:')
          Rails.logger.info "[decrypt_if_needed] Value is not encrypted, returning as-is"
          return value
        end
        
        encrypted_value = value.to_s.sub('encrypted:', '')
        Rails.logger.info "[decrypt_if_needed] Attempting to decrypt: #{encrypted_value[0..50]}..."
        
        decrypted = decrypt(encrypted_value)
        
        Rails.logger.info "[decrypt_if_needed] Decryption result: #{decrypted ? "(#{decrypted.length} chars)" : '(nil)'}"
        
        if decrypted.present?
          return decrypted
        else
          Rails.logger.warn "[decrypt_if_needed] Decryption returned nil, returning original encrypted value"
          return value
        end
      rescue => e
        Rails.logger.error("[decrypt_if_needed] Error: #{e.message}")
        Rails.logger.error(e.backtrace.first(3).join("\n"))
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
      # Generate reply-to address for email tracking
      def generate_reply_to_address
        # Always use platform-tracked reply address so inbound replies
        # are routed through SES and captured by the webhook.
        # The user's personal email is used as the FROM address, not REPLY-TO.
        return nil unless @lead.present?

        entity_type = @lead.class.name.downcase
        "reply+#{entity_type}-#{@lead.id}@#{ReplyToAddressService.mail_domain}"
      end

      def build_email_metadata(email_params, config = {})
        meta = {
          provider: config[:provider] || 'smtp',
          template_id: email_params[:template_id],
          to: email_params[:to],
          cc: email_params[:cc],
          bcc: email_params[:bcc],
          has_attachments: email_params[:attachments].present?,
          from_email: config[:fromEmail],
          from_name: config[:fromName],
          sender_user_id: current_user&.id,
          assigned_user_id: @lead&.owner_id
        }
        meta[:impersonated_by] = original_user.id if impersonating?
        meta.compact
      end

      # Build SMS metadata
      def build_sms_metadata(sms_params, config = {})
        meta = {
          provider: config[:provider] || 'twilio',
          template_id: sms_params[:template_id],
          to: sms_params[:to],
          character_count: sms_params[:content]&.length,
          from_number: config[:fromNumber],
          sender_user_id: current_user&.id,
          assigned_user_id: @lead&.owner_id
        }
        meta[:impersonated_by] = original_user.id if impersonating?
        meta.compact
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
          read_at:      parse_time(params[:read_at] || params[:readAt] || params[:opened_at] || params[:openedAt]),
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

      # Strip HTML tags and decode HTML entities
      def strip_html_tags(html_string)
        return '' if html_string.blank?
        
        # Remove all HTML tags
        text = html_string.gsub(/<[^>]*>/, ' ')
        
        # Decode common HTML entities
        text = text.gsub('&nbsp;', ' ')
                   .gsub('&amp;', '&')
                   .gsub('&lt;', '<')
                   .gsub('&gt;', '>')
                   .gsub('&quot;', '"')
                   .gsub('&#39;', "'")
        
        # Collapse multiple spaces and trim
        text.gsub(/\s+/, ' ').strip
      end

      # Consistent JSON serialization for communication logs
      def comm_log_json(comm)
        # Handle metadata - could be Hash, String (from text column), or nil
        metadata_obj = {}
        
        if comm.metadata.present?
          if comm.metadata.is_a?(Hash)
            metadata_obj = comm.metadata
          elsif comm.metadata.is_a?(String)
            # Try to parse as JSON first
            begin
              metadata_obj = JSON.parse(comm.metadata)
            rescue JSON::ParserError
              # If JSON parse fails, try to eval Ruby hash string (from older records)
              begin
                # Replace Ruby syntax with JSON syntax
                json_str = comm.metadata.gsub(/:(\w+)=>/, '"\1":')  # :key=> to "key":
                                        .gsub(/=>/, ':')                 # => to :
                                        .gsub(/nil/, 'null')            # nil to null
                metadata_obj = JSON.parse(json_str)
              rescue => e
                Rails.logger.warn "Failed to parse metadata for communication #{comm.id}: #{e.message}"
                metadata_obj = {}
              end
            end
          end
        end
        
        # Strip HTML from body for clean preview
        clean_body = strip_html_tags(comm.body || '')
        
        {
          id:          comm.id,
          leadId:      comm.communicable_id,
          entityId:    comm.communicable_id,
          entityType:  comm.communicable_type,
          type:        comm.channel,
          commType:    comm.channel,
          direction:   comm.direction,
          subject:     comm.subject,
          content:     clean_body,
          body:        clean_body,
          status:      comm.status,
          sentAt:      comm.sent_at&.iso8601,
          deliveredAt: comm.delivered_at&.iso8601,
          readAt:      comm.read_at&.iso8601,
          source:      metadata_obj['source'] || 'manual',
          metadata:    metadata_obj,
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
