# frozen_string_literal: true

module Providers
  module Email
    class MicrosoftGraphProvider < BaseProvider
      GRAPH_SEND_URL = 'https://graph.microsoft.com/v1.0/me/sendMail'

      def send_message(to:, from: nil, subject:, body:, cc: nil, bcc: nil, reply_to: nil, attachments: [], content_type: 'text/html', **options)
        validate_config!

        access_token = ensure_valid_token!
        from_address = from || config[:from_email]
        from_name = config[:from_name] || from_address

        Rails.logger.info "📧 [MicrosoftGraph] Sending email to #{to} from #{from_address}"
        Rails.logger.info "📧 [MicrosoftGraph] Reply-To: #{reply_to}" if reply_to.present?

        payload = build_graph_payload(
          to: to,
          from_address: from_address,
          from_name: from_name,
          subject: subject,
          body: body,
          cc: cc,
          bcc: bcc,
          reply_to: reply_to,
          attachments: attachments,
          content_type: content_type
        )

        response = post_to_graph(access_token, payload)

        # Handle 401 - token may have wrong audience (SMTP scope vs Graph scope)
        # Retry once with a Graph-scoped token
        if response.code.to_i == 401
          Rails.logger.warn "[MicrosoftGraph] 401 Unauthorized - attempting Graph-scoped token refresh"
          new_token = refresh_token_for_graph_scope!
          if new_token
            Rails.logger.info "[MicrosoftGraph] Retrying with Graph-scoped token"
            response = post_to_graph(new_token, payload)
          end
        end

        if response.code.to_i == 202
          Rails.logger.info "✅ [MicrosoftGraph] Email sent successfully to #{to}"
          record_connection_usage!
          {
            success: true,
            external_id: response['x-ms-request-id'] || "graph-#{SecureRandom.hex(8)}",
            provider: 'microsoft_graph'
          }
        else
          error_body = parse_error(response)
          Rails.logger.error "❌ [MicrosoftGraph] Send failed (#{response.code}): #{error_body}"
          record_connection_error!(error_body)
          raise DeliveryError, "Microsoft Graph API error (#{response.code}): #{error_body}"
        end
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Rails.logger.error "❌ [MicrosoftGraph] Timeout: #{e.message}"
        raise DeliveryError, "Microsoft Graph API timeout: #{e.message}"
      end

      private

      def validate_config!
        super
        raise ConfigurationError, "OAuth access token is required for Microsoft Graph" if config[:smtp_password].blank? && config[:oauth_access_token].blank?
      end

      GRAPH_SCOPE = UserEmailConnection::GRAPH_SEND_SCOPE

      # Get a valid access token, refreshing if expired
      def ensure_valid_token!
        # The token may come from config as :smtp_password (legacy XOAUTH2 path)
        # or as :oauth_access_token
        token = config[:oauth_access_token] || config[:smtp_password]

        # Check if the user connection has a refresh method
        if user_connection&.oauth_token_expired?
          Rails.logger.info "[MicrosoftGraph] Token expired, refreshing with Graph scope..."
          refreshed = user_connection.refresh_oauth_token!(scope: GRAPH_SCOPE)
          if refreshed
            Rails.logger.info "[MicrosoftGraph] Token refreshed successfully with Graph scope"
            return refreshed
          else
            Rails.logger.warn "[MicrosoftGraph] Token refresh failed, using existing token"
          end
        end

        token
      end

      # Refresh token specifically for Graph API scope (used on 401 retry)
      def refresh_token_for_graph_scope!
        if user_connection&.oauth_refresh_token_encrypted.present?
          user_connection.refresh_oauth_token_for_graph!
        else
          # Fall back to config-based refresh
          refresh_token = config[:oauth_refresh_token] || config[:oauthRefreshToken]
          return nil if refresh_token.blank?

          client_id     = ENV['MICROSOFT_OAUTH_CLIENT_ID'] ||
                          Rails.application.credentials.dig(:oauth, :microsoft, :client_id)
          client_secret = ENV['MICROSOFT_OAUTH_CLIENT_SECRET'] ||
                          Rails.application.credentials.dig(:oauth, :microsoft, :client_secret)

          uri = URI('https://login.microsoftonline.com/common/oauth2/v2.0/token')
          req = Net::HTTP::Post.new(uri)
          req.set_form_data(
            client_id:     client_id,
            client_secret: client_secret,
            refresh_token: refresh_token,
            grant_type:    'refresh_token',
            scope:         GRAPH_SCOPE
          )
          res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
          tokens = JSON.parse(res.body)
          return nil if tokens['error'].present?

          tokens['access_token']
        end
      rescue => e
        Rails.logger.error "[MicrosoftGraph] Graph-scoped token refresh failed: #{e.message}"
        nil
      end

      def user_connection
        return @user_connection if defined?(@user_connection)
        @user_connection = user&.default_email_connection
      end

      def build_graph_payload(to:, from_address:, from_name:, subject:, body:, cc: nil, bcc: nil, reply_to: nil, attachments: [], content_type: 'text/html')
        is_html = content_type.to_s.downcase.include?('html') ||
                  (body.to_s.include?('<') && (body.to_s.include?('</') || body.to_s.include?('/>')))

        message = {
          subject: subject,
          body: {
            contentType: is_html ? 'HTML' : 'Text',
            content: body
          },
          from: {
            emailAddress: {
              address: from_address,
              name: from_name
            }
          },
          toRecipients: build_recipients(to)
        }

        message[:ccRecipients] = build_recipients(cc) if cc.present?
        message[:bccRecipients] = build_recipients(bcc) if bcc.present?
        message[:replyTo] = build_recipients(reply_to) if reply_to.present?

        if attachments.present?
          message[:attachments] = attachments.map do |att|
            content = att[:content]
            encoded = content.is_a?(String) ? Base64.strict_encode64(content) : Base64.strict_encode64(content.to_s)
            {
              '@odata.type': '#microsoft.graph.fileAttachment',
              name: att[:filename],
              contentType: att[:content_type] || 'application/octet-stream',
              contentBytes: encoded
            }
          end
        end

        { message: message, saveToSentItems: true }
      end

      def build_recipients(addresses)
        return [] if addresses.blank?

        Array(addresses).flat_map { |addr| addr.to_s.split(',').map(&:strip) }.reject(&:blank?).map do |email|
          { emailAddress: { address: email.strip } }
        end
      end

      def post_to_graph(access_token, payload)
        uri = URI(GRAPH_SEND_URL)
        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{access_token}"
        request['Content-Type'] = 'application/json'
        request.body = payload.to_json

        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
          http.request(request)
        end
      end

      def parse_error(response)
        parsed = JSON.parse(response.body)
        parsed.dig('error', 'message') || parsed.to_s
      rescue JSON::ParserError
        response.body.to_s.truncate(200)
      end

      def record_connection_usage!
        user_connection&.record_usage!
      rescue => e
        Rails.logger.warn "[MicrosoftGraph] Failed to record usage: #{e.message}"
      end

      def record_connection_error!(message)
        user_connection&.record_error!(message)
      rescue => e
        Rails.logger.warn "[MicrosoftGraph] Failed to record error: #{e.message}"
      end
    end
  end
end
