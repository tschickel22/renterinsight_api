# frozen_string_literal: true

module Api
  module Platform
    class CommunicationsController < ApplicationController
      before_action :set_entity, only: [:history, :stats, :destroy]
      before_action :authorize_communication_access!, only: [:email, :sms]

      # GET /api/platform/communications/:entity_type/:entity_id/history
      def history
        communications = Communication
          .where(communicable_type: @entity_type, communicable_id: @entity_id)
          .order(created_at: :desc)
        
        render json: communications.map { |comm| comm_log_json(comm) }, status: :ok
      end

      # GET /api/platform/communications/:entity_type/:entity_id/stats
      def stats
        begin
          # Get all communications for this entity
          comms = Communication.where(
            communicable_type: @entity_type,
            communicable_id: @entity_id
          )
          
          # Get email communications
          email_comms = comms.where(channel: 'email')
          email_sent = email_comms.where(direction: 'outbound').count
          
          # Calculate email stats
          email_opened = email_comms.where(direction: 'outbound').where.not(read_at: nil).count
          
          # Safe metadata query - check if metadata column is jsonb or text
          email_clicked = begin
            # Try jsonb query first
            email_comms.where(direction: 'outbound')
              .where("metadata->>'clicked' = 'true'").count
          rescue ActiveRecord::StatementInvalid
            # Fallback for text columns - just count as 0
            0
          end
          
          open_rate = email_sent > 0 ? (email_opened.to_f / email_sent * 100).round(1) : 0
          click_rate = email_sent > 0 ? (email_clicked.to_f / email_sent * 100).round(1) : 0
          
          # Get SMS communications
          sms_comms = comms.where(channel: 'sms')
          sms_sent = sms_comms.where(direction: 'outbound').count
          sms_delivered = sms_comms.where(direction: 'outbound', status: 'delivered').count
          delivery_rate = sms_sent > 0 ? (sms_delivered.to_f / sms_sent * 100).round(1) : 0
          
          # Calculate response rate (inbound messages / outbound messages)
          outbound_count = comms.where(direction: 'outbound').count
          inbound_count = comms.where(direction: 'inbound').count
          response_rate = outbound_count > 0 ? (inbound_count.to_f / outbound_count * 100).round(1) : 0
          
          # Last contact date
          last_comm = comms.order(created_at: :desc).first
          last_contact_at = last_comm&.created_at
          
          render json: {
            total: comms.count,
            email: {
              count: email_sent,
              openRate: open_rate,
              clickRate: click_rate,
              opened: email_opened,
              clicked: email_clicked
            },
            sms: {
              count: sms_sent,
              deliveryRate: delivery_rate,
              delivered: sms_delivered
            },
            lastContactAt: last_contact_at&.iso8601,
            responseRate: response_rate,
            outboundCount: outbound_count,
            inboundCount: inbound_count
          }, status: :ok
        rescue => e
          Rails.logger.error("[Platform::CommunicationsController#stats] Error: #{e.message}")
          render json: { error: e.message }, status: :internal_server_error
        end
      end

      # POST /api/platform/communications/email
      def email
        result = send_email_unified
        
        if result[:success]
          render json: result, status: result[:id] ? :created : :ok
        else
          render json: result, status: :unprocessable_entity
        end
      end

      # POST /api/platform/communications/sms
      def sms
        result = send_sms_unified
        
        if result[:success]
          render json: result, status: result[:id] ? :created : :ok
        else
          render json: result, status: :unprocessable_entity
        end
      end

      # DELETE /api/platform/communications/:entity_type/:entity_id/messages/:id
      def destroy
        communication = Communication.find_by(
          id: params[:id],
          communicable_type: @entity_type,
          communicable_id: @entity_id
        )

        unless communication
          render json: { error: 'Communication not found' }, status: :not_found
          return
        end

        communication.destroy!
        render json: { success: true, message: 'Communication deleted successfully' }, status: :ok
      rescue => e
        Rails.logger.error("[Platform::CommunicationsController#destroy] Error: #{e.message}")
        render json: { error: e.message }, status: :internal_server_error
      end

      private

      def set_entity
        @entity_type = params[:entity_type]
        @entity_id = params[:entity_id]
        
        # Validate entity exists
        entity_class = @entity_type.constantize rescue nil
        unless entity_class
          render json: { error: "Invalid entity type: #{@entity_type}" }, status: :bad_request
          return
        end
        
        # Scope entity lookup to current company for tenant isolation
        if entity_class.column_names.include?('company_id')
          @entity = entity_class.where(company_id: current_company_id).find_by(id: @entity_id)
        else
          # For entities without company_id, still do a basic lookup but log warning
          Rails.logger.warn "[Platform::CommunicationsController] Entity #{@entity_type} has no company_id - cannot enforce tenant isolation"
          @entity = entity_class.find_by(id: @entity_id)
        end
        
        unless @entity
          render json: { error: "#{@entity_type} not found" }, status: :not_found
        end
      rescue => e
        render json: { error: e.message }, status: :bad_request
      end
      
      # Verify the user can send communications (either platform admin or within their company)
      def authorize_communication_access!
        # Platform admins can send from any context
        return true if current_user&.platform_admin? || current_user&.super_admin?
        
        # For entity-scoped sends, verify entity belongs to user's company
        if params[:entity_type].present? && params[:entity_id].present?
          entity_class = params[:entity_type].constantize rescue nil
          return true unless entity_class
          
          if entity_class.column_names.include?('company_id')
            entity = entity_class.find_by(id: params[:entity_id])
            unless entity&.company_id == current_company_id
              render json: { error: 'Unauthorized - Entity belongs to another company' }, status: :forbidden
              return false
            end
          end
        end
        
        true
      end

      def send_email_unified
        # Get settings
        settings = get_effective_settings
        email_config = settings.dig(:communications, :email) || settings.dig('communications', 'email') || {}
        
        Rails.logger.info "[Platform::CommunicationsController#email] Email config keys: #{email_config.keys}"
        
        unless email_configured?(email_config)
          return { 
            ok: false, 
            success: false,
            error: 'Email is not configured. Please configure email settings in Platform Settings.'
          }
        end

        # Decrypt settings like password reset does
        email_config = decrypt_settings(email_config)

        # Extract parameters
        email_params = extract_email_params
        
        # Create communication BEFORE sending (so we have ID for tracking pixel)
        communication = create_pending_communication(email_params, email_config) if params[:entity_id]
        
        # Auto-generate Reply-To address for tracking
        if communication
          generated_reply_to = ReplyToAddressService.generate_for(communication, user: current_user)
          communication.update_column(:reply_to, generated_reply_to)
          Rails.logger.info "[Platform::CommunicationsController] Auto-generated reply_to: #{generated_reply_to} for communication #{communication.id}"
          
          # Add tracking pixel to email body
          enhanced_body = add_tracking_pixel(email_params[:content], communication.id)
          # Update the communication record with the HTML version
          communication.update!(body: enhanced_body)
        else
          enhanced_body = email_params[:content]
        end
        
        # Configure ActionMailer based on provider
        provider = (email_config['provider'] || email_config[:provider] || 'smtp').to_sym
        
        case provider
        when :smtp
          configure_action_mailer_smtp(email_config)
        when :gmail
          configure_action_mailer_gmail(email_config)
        when :aws_ses
          configure_action_mailer_ses(email_config)
        when :sendgrid
          configure_action_mailer_sendgrid(email_config)
        else
          Rails.logger.warn "[Platform::CommunicationsController] Unknown email provider: #{provider}, falling back to SMTP"
          configure_action_mailer_smtp(email_config)
        end
        
        # Send email via ActionMailer with enhanced body
        send_result = send_email_via_action_mailer(
          email_params.merge(content: enhanced_body), 
          email_config,
          reply_to: communication&.reply_to
        )
        
        unless send_result[:success]
          # Mark communication as failed if it was created
          communication&.mark_as_failed!(send_result[:error] || 'Failed to send email')
          
          return {
            ok: false,
            success: false,
            error: send_result[:error] || 'Failed to send email'
          }
        end

        # Update communication with sent status and message ID
        if communication
          communication.update!(
            status: 'sent',
            sent_at: Time.current,
            external_id: send_result[:message_id]
          )
          CommunicationEvent.track_send(communication, details: { message_id: send_result[:message_id] })
          
          return { 
            ok: true, 
            success: true,
            id: communication.id,
            messageId: send_result[:message_id],
            provider: email_config['provider'] || email_config[:provider] || 'smtp'
          }
        end

        # Test email without entity
        {
          ok: true, 
          success: true,
          message: 'Email sent successfully',
          messageId: send_result[:message_id],
          provider: email_config['provider'] || email_config[:provider] || 'smtp'
        }
      rescue => e
        Rails.logger.error("[Platform::CommunicationsController#email] Error: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        communication&.mark_as_failed!(e.message)
        {
          ok: false,
          success: false,
          error: e.message
        }
      end

      def send_sms_unified
        # Get settings
        settings = get_effective_settings
        sms_config = settings.dig(:communications, :sms) || settings.dig('communications', 'sms') || {}
        
        Rails.logger.info "[Platform::CommunicationsController#sms] SMS config: #{sms_config.keys}"
        
        unless sms_configured?(sms_config)
          return { 
            ok: false, 
            success: false,
            error: 'SMS is not configured. Please configure SMS settings in Platform Settings.'
          }
        end

        # Decrypt settings
        sms_config = decrypt_settings(sms_config)

        # Extract parameters
        sms_params = extract_sms_params
        
        # Send SMS via helper
        send_result = send_sms_via_provider(sms_params[:to], sms_params[:content], sms_config)
        
        unless send_result[:success]
          return {
            ok: false,
            success: false,
            error: send_result[:error] || 'Failed to send SMS'
          }
        end

        # Create communication log if entity is provided
        entity_type = params[:entity_type]
        entity_id = params[:entity_id]
        
        if entity_type.present? && entity_id.present?
          entity = entity_type.constantize.find_by(id: entity_id)
          
          if entity
            log = Communication.create!(
              communicable: entity,
              channel: 'sms',
              direction: 'outbound',
              body: sms_params[:content],
              status: 'sent',
              sent_at: Time.current,
              to_address: sms_params[:to],
              from_address: sms_config['fromNumber'] || sms_config[:fromNumber],
              external_id: send_result[:message_sid],  # ⚠️ CRITICAL: Store message_sid for webhook matching
              metadata: {
                message_sid: send_result[:message_sid],
                provider: sms_config['provider'] || sms_config[:provider] || 'twilio',
                template_id: sms_params[:template_id],
                initial_status: send_result[:status]
              }.compact
            )
            
            # Track send event
            CommunicationEvent.track_send(log, details: { message_sid: send_result[:message_sid] })

            return { 
              ok: true, 
              success: true,
              id: log.id,
              messageId: send_result[:message_sid],
              provider: sms_config['provider'] || sms_config[:provider] || 'twilio'
            }
          end
        end

        # Test SMS without entity
        {
          ok: true, 
          success: true,
          message: 'SMS sent successfully',
          messageId: send_result[:message_sid],
          provider: sms_config['provider'] || sms_config[:provider] || 'twilio'
        }
      rescue => e
        Rails.logger.error("[Platform::CommunicationsController#sms] Error: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        {
          ok: false,
          success: false,
          error: e.message
        }
      end

      def get_effective_settings
        # Waterfall: User → Location → Company → Platform
        # User email connection has HIGHEST priority for EMAIL only
        # SMS always uses Location → Company → Platform (users don't have SMS numbers)
        
        location_settings = fetch_location_settings
        company_settings = fetch_company_settings
        platform_settings = fetch_platform_settings
        
        Rails.logger.info "[get_effective_settings] Waterfall check:"
        Rails.logger.info "  - Platform settings: #{platform_settings.dig(:communications, :email, :provider) || 'none'}"
        Rails.logger.info "  - Company settings: #{company_settings.dig(:communications, :email, :provider) || 'none'}"
        Rails.logger.info "  - Location settings: #{location_settings.dig(:communications, :email, :provider) || 'none'}"
        
        # Start with platform (lowest priority)
        result = platform_settings.deep_dup
        
        # Merge company (overrides platform)
        result = merge_settings(result, company_settings) if company_settings.present?
        
        # Merge location (overrides company)
        result = merge_settings(result, location_settings) if location_settings.present?
        
        # Check user email connection LAST (highest priority for EMAIL only)
        # Only override email settings - preserve SMS from location/company/platform
        user_settings = fetch_user_email_settings
        if user_settings.present?
          Rails.logger.info "[get_effective_settings] ✅ Overlaying USER email connection for #{current_user&.email}"
          result[:communications] ||= {}
          result[:communications][:email] = user_settings.dig(:communications, :email)
        end
        
        final_email = result.dig(:communications, :email, :provider) || 'none'
        final_sms = result.dig(:communications, :sms, :isEnabled) || result.dig(:communications, :sms, 'isEnabled') || false
        Rails.logger.info "[get_effective_settings] ✅ Final email: #{final_email}, SMS enabled: #{final_sms}"
        
        result
      rescue => e
        Rails.logger.error("[Platform::CommunicationsController] Error fetching settings: #{e.message}")
        {
          communications: {
            email: { isEnabled: false },
            sms: { isEnabled: false }
          }
        }
      end

      # Fetch user's personal email connection settings (highest priority in waterfall)
      def fetch_user_email_settings
        return {} unless current_user
        return {} unless current_user.respond_to?(:has_email_connection?) && current_user.has_email_connection?
        
        connection = current_user.user_email_connection
        return {} unless connection&.smtp_credentials_valid?
        
        Rails.logger.info "[fetch_user_email_settings] User #{current_user.email} has email connection configured"
        
        {
          communications: {
            email: {
              provider: :smtp,
              isEnabled: true,
              fromEmail: connection.email_address,
              fromName: current_user.name || current_user.email,
              smtpHost: connection.smtp_host,
              smtpPort: connection.smtp_port,
              smtpUsername: connection.smtp_username,
              smtpPassword: connection.smtp_password,
              smtpAuthentication: 'plain',
              smtpEnableStarttls: true
            }
          }
        }
      rescue => e
        Rails.logger.warn("[fetch_user_email_settings] Error: #{e.message}")
        {}
      end

      def fetch_platform_settings
        stored = Setting.get('Platform', 0, 'communications')
        
        Rails.logger.info "[fetch_platform_settings] Raw stored value present: #{stored.present?}"
        Rails.logger.info "[fetch_platform_settings] Raw stored keys: #{stored.keys if stored.is_a?(Hash)}"
        
        return {} unless stored
        
        if stored.is_a?(Hash)
          # CRITICAL: symbolize_keys so we can access with :email, :provider, etc.
          result = { communications: stored.deep_symbolize_keys }
          provider = result.dig(:communications, :email, :provider)
          Rails.logger.info "[fetch_platform_settings] Provider after symbolize: #{provider}"
          result
        else
          {}
        end
      rescue => e
        Rails.logger.warn("[Platform::CommunicationsController] Could not fetch platform settings: #{e.message}")
        {}
      end

      def fetch_company_settings
        # Get current company (not platform company)
        company = @company || ::Company.find_by(id: current_company_id)
        return {} unless company
        
        # Platform company (ID=1) has no company-level settings, skip it
        return {} if company.id == 1
        
        stored = Setting.get('Company', company.id, 'communications')
        return {} unless stored
        
        if stored.is_a?(Hash)
          { communications: stored.deep_symbolize_keys }
        else
          {}
        end
      rescue => e
        Rails.logger.warn("[Platform::CommunicationsController] Could not fetch company settings: #{e.message}")
        {}
      end
      
      def fetch_location_settings
        # Check if there's a current location selected
        location_id = Current.location_id
        return {} unless location_id
        
        location = ::Location.find_by(id: location_id)
        return {} unless location
        
        stored = Setting.get('Location', location.id, 'communications')
        return {} unless stored
        
        if stored.is_a?(Hash)
          { communications: stored.deep_symbolize_keys }
        else
          {}
        end
      rescue => e
        Rails.logger.warn("[Platform::CommunicationsController] Could not fetch location settings: #{e.message}")
        {}
      end

      def merge_settings(base, override)
        # Merge override settings on top of base settings
        # override settings take priority and replace base settings
        
        base = base.deep_symbolize_keys if base.respond_to?(:deep_symbolize_keys)
        override = override.deep_symbolize_keys if override.respond_to?(:deep_symbolize_keys)
        
        result = base.deep_dup
        
        # Deep merge email settings - override replaces base
        if override.dig(:communications, :email)
          result[:communications] ||= {}
          result[:communications][:email] ||= {}
          # Use deep_merge so nested hashes are properly merged
          result[:communications][:email] = result[:communications][:email].deep_merge(override[:communications][:email])
        end
        
        # Deep merge SMS settings - override replaces base
        if override.dig(:communications, :sms)
          result[:communications] ||= {}
          result[:communications][:sms] ||= {}
          result[:communications][:sms] = result[:communications][:sms].deep_merge(override[:communications][:sms])
        end
        
        result
      end

      def email_configured?(config)
        is_enabled = config[:isEnabled] || config['isEnabled']
        from_email = config[:fromEmail] || config['fromEmail']
        provider = config[:provider] || config['provider']
        smtp_host = config[:smtpHost] || config['smtpHost']
        
        is_enabled == true &&
        from_email.present? &&
        (provider.present? || smtp_host.present?)
      end

      def sms_configured?(config)
        is_enabled = config[:isEnabled] || config['isEnabled']
        from_number = config[:fromNumber] || config['fromNumber']
        provider = config[:provider] || config['provider']
        
        is_enabled == true &&
        from_number.present? &&
        provider.present?
      end

      def extract_email_params
        # Extract attachments from FormData (params[:attachments] will be a hash with numeric keys)
        attachments = []
        if params[:attachments].is_a?(ActionController::Parameters)
          params[:attachments].values.each do |file|
            attachments << file if file.respond_to?(:read)
          end
        elsif params[:attachments].is_a?(Array)
          attachments = params[:attachments].select { |f| f.respond_to?(:read) }
        end
        
        # If template_id is provided, load template attachments
        template_id = params[:template_id] || params[:templateId]
        if template_id.present?
          begin
            template = Template.find(template_id)
            if template.attachments.attached?
              template.attachments.each do |attachment|
                # Add template attachment as a hash with filename and content
                attachments << {
                  filename: attachment.filename.to_s,
                  content: attachment.download
                }
              end
            end
          rescue ActiveRecord::RecordNotFound
            Rails.logger.warn("[extract_email_params] Template #{template_id} not found")
          end
        end
        
        {
          subject: params[:subject],
          content: params[:body] || params[:html] || params[:content],
          to: params[:to],
          template_id: template_id,
          cc: params[:cc],
          bcc: params[:bcc],
          attachments: attachments
        }
      end

      def extract_sms_params
        {
          content: params[:message] || params[:content] || params[:body],
          to: params[:to],
          template_id: params[:template_id] || params[:templateId]
        }
      end

      # Configure ActionMailer SMTP like password reset does
      def configure_action_mailer_smtp(email_settings)
        smtp_config = {
          address: email_settings['smtpHost'] || email_settings[:smtpHost] || 'smtp.gmail.com',
          port: (email_settings['smtpPort'] || email_settings[:smtpPort] || 587).to_i,
          user_name: email_settings['smtpUsername'] || email_settings[:smtpUsername],
          password: email_settings['smtpPassword'] || email_settings[:smtpPassword],
          authentication: (email_settings['smtpAuthentication'] || email_settings[:smtpAuthentication] || 'plain').to_sym,
          enable_starttls_auto: email_settings['smtpEnableStarttls'].nil? ? true : email_settings['smtpEnableStarttls']
        }

        ActionMailer::Base.delivery_method = :smtp
        ActionMailer::Base.smtp_settings = smtp_config
        ActionMailer::Base.perform_deliveries = true
        ActionMailer::Base.raise_delivery_errors = true
        
        Rails.logger.info("📧 ActionMailer SMTP configured: #{smtp_config[:address]}:#{smtp_config[:port]} (user: #{smtp_config[:user_name]})")
      rescue StandardError => e
        Rails.logger.error("❌ Failed to configure ActionMailer SMTP: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
      end
      
      # Configure ActionMailer for Gmail Relay
      def configure_action_mailer_gmail(email_settings)
        smtp_config = {
          address: 'smtp.gmail.com',
          port: 587,
          user_name: email_settings['smtpUsername'] || email_settings[:smtpUsername],
          password: email_settings['smtpPassword'] || email_settings[:smtpPassword],
          authentication: :plain,
          enable_starttls_auto: true
        }
        
        ActionMailer::Base.delivery_method = :smtp
        ActionMailer::Base.smtp_settings = smtp_config
        ActionMailer::Base.perform_deliveries = true
        ActionMailer::Base.raise_delivery_errors = true
        
        Rails.logger.info("📧 ActionMailer Gmail configured: smtp.gmail.com:587 (user: #{smtp_config[:user_name]})")
      rescue StandardError => e
        Rails.logger.error("❌ Failed to configure ActionMailer Gmail: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
      end
      
      # Configure ActionMailer for AWS SES using SDK (not SMTP)
      # This uses IAM credentials directly - no SMTP password needed!
      def configure_action_mailer_ses(email_settings)
        # Require the custom delivery method
        require_relative '../../../../lib/aws_ses_delivery'
        
        # Register the custom AWS SES delivery method
        ActionMailer::Base.add_delivery_method(:aws_ses_sdk, AwsSesDelivery)
        
        aws_region = email_settings['awsRegion'] || email_settings[:awsRegion] || 'us-east-1'
        access_key = email_settings['awsAccessKeyId'] || email_settings[:awsAccessKeyId]
        secret_key = email_settings['awsSecretAccessKey'] || email_settings[:awsSecretAccessKey]
        
        # Debug logging
        Rails.logger.info "[configure_action_mailer_ses] Using AWS SDK (not SMTP)"
        Rails.logger.info "[configure_action_mailer_ses] Access Key present: #{access_key.present?}"
        Rails.logger.info "[configure_action_mailer_ses] Secret Key present: #{secret_key.present?}"
        Rails.logger.info "[configure_action_mailer_ses] Region: #{aws_region}"
        
        # Configure delivery method
        ActionMailer::Base.delivery_method = :aws_ses_sdk
        ActionMailer::Base.aws_ses_sdk_settings = {
          access_key_id: access_key,
          secret_access_key: secret_key,
          region: aws_region
        }
        ActionMailer::Base.perform_deliveries = true
        ActionMailer::Base.raise_delivery_errors = true
        
        Rails.logger.info("📧 ActionMailer AWS SES SDK configured: region=#{aws_region}, key=#{access_key}")
      rescue StandardError => e
        Rails.logger.error("❌ Failed to configure ActionMailer AWS SES: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
      end
      
      # Configure ActionMailer for SendGrid
      def configure_action_mailer_sendgrid(email_settings)
        smtp_config = {
          address: 'smtp.sendgrid.net',
          port: 587,
          user_name: 'apikey',
          password: email_settings['sendgridApiKey'] || email_settings[:sendgridApiKey],
          authentication: :plain,
          enable_starttls_auto: true
        }
        
        ActionMailer::Base.delivery_method = :smtp
        ActionMailer::Base.smtp_settings = smtp_config
        ActionMailer::Base.perform_deliveries = true
        ActionMailer::Base.raise_delivery_errors = true
        
        Rails.logger.info("📧 ActionMailer SendGrid configured: smtp.sendgrid.net:587")
      rescue StandardError => e
        Rails.logger.error("❌ Failed to configure ActionMailer SendGrid: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
      end

      # Send email via ActionMailer like password reset does
      def send_email_via_action_mailer(email_params, config, reply_to: nil)
        from_email = config['fromEmail'] || config[:fromEmail]
        from_name = config['fromName'] || config[:fromName] || 'RenterInsight'
        
        Rails.logger.info "[send_email_via_action_mailer] Sending to #{email_params[:to]} from #{from_email}"
        Rails.logger.info "[send_email_via_action_mailer] Reply-To: #{reply_to}" if reply_to.present?
        Rails.logger.info "[send_email_via_action_mailer] Attachments count: #{email_params[:attachments]&.length || 0}"
        
        mail = CommunicationMailer.send_communication(
          to: email_params[:to],
          subject: email_params[:subject],
          body: email_params[:content],
          from_email: from_email,
          from_name: from_name,
          cc: email_params[:cc],
          bcc: email_params[:bcc],
          reply_to: reply_to,
          file_attachments: email_params[:attachments] || []
        )
        
        mail.deliver_now
        
        Rails.logger.info "[send_email_via_action_mailer] Success: #{mail.message_id}"
        { 
          success: true, 
          message_id: mail.message_id
        }
      rescue => e
        Rails.logger.error "[send_email_via_action_mailer] Exception: #{e.message}"
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        { success: false, error: e.message }
      end

      def send_sms_via_provider(to, message, config)
        provider = (config['provider'] || config[:provider] || 'twilio').to_sym
        
        case provider
        when :twilio
          send_sms_via_twilio(to, message, config)
        else
          { success: false, error: "Unknown SMS provider: #{provider}" }
        end
      end

      def send_sms_via_twilio(to, message, config)
        require 'net/http'
        require 'uri'
        require 'json'
        
        account_sid = config['twilioAccountSid'] || config[:twilioAccountSid]
        auth_token = config['twilioAuthToken'] || config[:twilioAuthToken]
        from_number = config['fromNumber'] || config[:fromNumber]
        
        Rails.logger.info "[send_sms_via_twilio] Sending to #{to} from #{from_number}"
        
        # Configure status callback URL for delivery tracking
        # Skip callback URL if using localhost (Twilio rejects localhost URLs)
        callback_url = nil
        if request.present? && !request.host.include?('localhost')
          callback_url = "#{request.protocol}#{request.host_with_port}/webhooks/twilio/sms/status"
          Rails.logger.info "[send_sms_via_twilio] Callback URL: #{callback_url}"
        else
          Rails.logger.warn "[send_sms_via_twilio] Skipping StatusCallback (localhost or no request context)"
        end
        
        uri = URI.parse("https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json")
        
        request_obj = Net::HTTP::Post.new(uri)
        request_obj.basic_auth(account_sid, auth_token)
        
        form_data = {
          'From' => from_number,
          'To' => to,
          'Body' => message
        }
        
        # Only add StatusCallback if we have a valid URL
        form_data['StatusCallback'] = callback_url if callback_url.present?
        
        request_obj.set_form_data(form_data)
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request_obj)
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

      # Decrypt settings like password reset does
      def decrypt_settings(settings)
        decrypted = settings.deep_dup
        
        # Decrypt sensitive fields
        decrypted.each do |key, value|
          if value.is_a?(String) && value.start_with?('encrypted:')
            decrypted[key] = decrypt(value)
          end
        end
        
        decrypted
      end

      def decrypt(encrypted_value)
        return encrypted_value unless encrypted_value.start_with?('encrypted:')
        
        encrypted_data = encrypted_value.sub('encrypted:', '')
        secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
        key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
        crypt = ActiveSupport::MessageEncryptor.new(key)
        
        crypt.decrypt_and_verify(encrypted_data)
      rescue StandardError => e
        Rails.logger.error("Failed to decrypt setting: #{e.message}")
        nil
      end

      def comm_log_json(comm)
        {
          id: comm.id,
          leadId: comm.communicable_id,
          entityId: comm.communicable_id,
          entityType: comm.communicable_type,
          type: comm.channel,
          direction: comm.direction,
          subject: comm.subject,
          content: comm.body,
          status: comm.status,
          sentAt: comm.sent_at&.iso8601,
          deliveredAt: comm.delivered_at&.iso8601,
          readAt: comm.read_at&.iso8601,
          metadata: comm.metadata || {},
          createdAt: comm.created_at&.iso8601,
          updatedAt: comm.updated_at&.iso8601
        }.compact
      end
      
      # Create communication record before sending (to get ID for tracking)
      def create_pending_communication(email_params, config)
        entity_type = params[:entity_type]
        entity_id = params[:entity_id]
        
        return nil unless entity_type.present? && entity_id.present?
        
        entity = entity_type.constantize.find_by(id: entity_id)
        return nil unless entity
        
        Communication.create!(
          communicable: entity,
          channel: 'email',
          direction: 'outbound',
          subject: email_params[:subject],
          body: email_params[:content],
          status: 'pending',
          to_address: email_params[:to],
          from_address: config['fromEmail'] || config[:fromEmail],
          cc_addresses: email_params[:cc],
          bcc_addresses: email_params[:bcc],
          metadata: {
            template_id: email_params[:template_id]
          }.compact
        )
      end
      
      # Add tracking pixel to email HTML
      def add_tracking_pixel(html_body, communication_id)
        return html_body unless html_body.present? && communication_id.present?
        
        # Ensure content is HTML
        html_body = ensure_html_format(html_body)
        
        # Generate tracking pixel URL
        pixel_url = "#{request.protocol}#{request.host_with_port}/webhooks/email/#{communication_id}/pixel.gif"
        
        # Tracking pixel IMG tag
        tracking_pixel = "<img src=\"#{pixel_url}\" width=\"1\" height=\"1\" alt=\"\" style=\"display:none\" />"
        
        # If HTML contains </body>, insert before it
        if html_body.include?('</body>')
          html_body.sub('</body>', "#{tracking_pixel}</body>")
        else
          # Otherwise append to end
          "#{html_body}#{tracking_pixel}"
        end
      end
      
      # Ensure email body is in HTML format
      def ensure_html_format(body)
        return body if body.blank?
        
        # Already HTML - return as is
        return body if body.include?('<html') || body.include?('<body')
        
        # Convert plain text to HTML
        # Preserve line breaks and basic formatting
        formatted_body = body.gsub("\n", "<br>")
        
        # Wrap in basic HTML structure
        <<~HTML
          <html>
            <head>
              <meta charset="UTF-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0">
            </head>
            <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333;">
              #{formatted_body}
            </body>
          </html>
        HTML
      end
      
      # ==================== TEMPLATE MANAGEMENT ====================
      
      # GET /api/platform/communications/templates
      def index_templates
        templates = Template.where(template_type: %w[email sms]).order(created_at: :desc)
        render json: templates.map { |t| template_json(t) }, status: :ok
      end
      
      # GET /api/platform/communications/templates/:id
      def show_template
        template = Template.find(params[:id])
        render json: template_json(template), status: :ok
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Template not found' }, status: :not_found
      end
      
      # POST /api/platform/communications/templates
      def create_template
        template = Template.new(template_params)
        
        # Handle file attachments if present
        if params[:attachments].present?
          params[:attachments].each do |file|
            template.attachments.attach(file) if file.respond_to?(:read)
          end
        end
        
        if template.save
          render json: template_json(template), status: :created
        else
          render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/platform/communications/templates/:id
      def update_template
        template = Template.find(params[:id])
        
        # Handle new file attachments if present
        if params[:attachments].present?
          params[:attachments].each do |file|
            template.attachments.attach(file) if file.respond_to?(:read)
          end
        end
        
        if template.update(template_params)
          render json: template_json(template), status: :ok
        else
          render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Template not found' }, status: :not_found
      end
      
      # DELETE /api/platform/communications/templates/:id
      def destroy_template
        template = Template.find(params[:id])
        template.destroy!
        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Template not found' }, status: :not_found
      end
      
      # DELETE /api/platform/communications/templates/:id/attachments/:attachment_id
      def delete_template_attachment
        template = Template.find(params[:id])
        attachment = template.attachments.find(params[:attachment_id])
        attachment.purge
        render json: template_json(template), status: :ok
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Template or attachment not found' }, status: :not_found
      end
      
      def template_params
        params.require(:template).permit(:name, :template_type, :subject, :body, :is_active)
      end
      
      def template_json(template)
        attachments_data = []
        
        if template.attachments.attached?
          attachments_data = template.attachments.map do |attachment|
            {
              id: attachment.id,
              filename: attachment.filename.to_s,
              content_type: attachment.content_type,
              byte_size: attachment.byte_size,
              url: Rails.application.routes.url_helpers.rails_blob_path(attachment, only_path: true),
              created_at: attachment.created_at&.iso8601
            }
          end
        end
        
        {
          id: template.id,
          name: template.name,
          template_type: template.template_type,
          type: template.template_type,
          subject: template.subject,
          body: template.body,
          isActive: template.is_active,
          is_active: template.is_active,
          attachments: attachments_data,
          createdAt: template.created_at&.iso8601,
          updatedAt: template.updated_at&.iso8601
        }
      end
    end
  end
end
