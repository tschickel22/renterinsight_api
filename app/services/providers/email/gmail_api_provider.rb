# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'base64'

module Providers
  module Email
    # Sends through Gmail's REST API instead of SMTP.
    #
    # Why this exists: SMTP over XOAUTH2 requires the full https://mail.google.com/
    # grant, which Google classifies as a restricted scope and gates behind an
    # annual security assessment. messages.send works with gmail.send, which is
    # merely sensitive. So this transport is what makes the narrow scope viable
    # at all, and it is selected per-connection by UserEmailConnection#requires_rest_send?.
    #
    # Takes an already-encoded RFC 2822 message rather than building one, so the
    # callers keep using the same Mail object they build for the SMTP path and
    # nothing about attachments, inline images, or headers changes with the
    # transport.
    class GmailApiProvider
      SEND_URL  = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'
      TOKEN_URL = 'https://oauth2.googleapis.com/token'

      class << self
        # @param raw_message [String] full RFC 2822 message
        # @return [Hash] { success:, message_id:, gmail_id: } or { success: false, error: }
        def deliver_raw(raw_message:, access_token:, refresh_token: nil,
                        client_id: nil, client_secret: nil, message_id: nil)
          if raw_message.blank?
            return { success: false, error: 'Cannot send an empty message' }
          end

          # Gmail wants base64url with the padding stripped.
          encoded = Base64.urlsafe_encode64(raw_message).delete('=')

          token = access_token.presence
          # No usable access token but we can mint one, so do that rather than
          # burning a request that is certain to 401.
          if token.blank? && refresh_token.present?
            token = refresh_access_token(refresh_token: refresh_token, client_id: client_id, client_secret: client_secret)
          end

          return { success: false, error: 'Gmail access token not available. Reconnect the mailbox.' } if token.blank?

          response = post(token, encoded)

          # An expired access token is the ordinary case, not an error worth
          # surfacing. Refresh once and retry before giving up.
          if response.code.to_i == 401 && refresh_token.present?
            Rails.logger.info '[GmailApi] 401 from send, refreshing access token and retrying'
            refreshed = refresh_access_token(refresh_token: refresh_token, client_id: client_id, client_secret: client_secret)
            response = post(refreshed, encoded) if refreshed.present?
          end

          parse_response(response, message_id)
        rescue => e
          Rails.logger.error "[GmailApi] Exception: #{e.class}: #{e.message}"
          { success: false, error: e.message }
        end

        def refresh_access_token(refresh_token:, client_id: nil, client_secret: nil)
          client_id     ||= ENV['GOOGLE_OAUTH_CLIENT_ID'] || Rails.application.credentials.dig(:oauth, :google, :client_id)
          client_secret ||= ENV['GOOGLE_OAUTH_CLIENT_SECRET'] || Rails.application.credentials.dig(:oauth, :google, :client_secret)

          uri = URI(TOKEN_URL)
          request = Net::HTTP::Post.new(uri)
          request.set_form_data(
            'client_id'     => client_id,
            'client_secret' => client_secret,
            'refresh_token' => refresh_token,
            'grant_type'    => 'refresh_token'
          )

          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
          body = JSON.parse(response.body) rescue {}

          if response.code.to_i == 200 && body['access_token'].present?
            body['access_token']
          else
            # Surfaced verbatim so EmailConnectionHealth can recognise
            # invalid_grant and prompt the user to reconnect.
            Rails.logger.error "[GmailApi] Token refresh failed: #{body['error']} #{body['error_description']}"
            nil
          end
        rescue => e
          Rails.logger.error "[GmailApi] Token refresh exception: #{e.message}"
          nil
        end

        private

        def post(access_token, encoded_message)
          uri = URI(SEND_URL)
          request = Net::HTTP::Post.new(uri)
          request['Authorization'] = "Bearer #{access_token}"
          request['Content-Type']  = 'application/json'
          request.body = { raw: encoded_message }.to_json

          Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
        end

        def parse_response(response, message_id)
          body = JSON.parse(response.body) rescue {}

          if response.code.to_i == 200
            Rails.logger.info "[GmailApi] Sent, gmail id #{body['id']}"
            {
              success: true,
              # Prefer the RFC Message-ID from our own message so external_id
              # means the same thing here as on every other transport. Gmail's
              # own id is a different namespace and is kept alongside it.
              message_id: message_id.presence || body['id'],
              gmail_id: body['id']
            }
          else
            error = body.dig('error', 'message') || "Gmail API error (HTTP #{response.code})"
            Rails.logger.error "[GmailApi] Send failed: #{error}"
            { success: false, error: error }
          end
        end
      end
    end
  end
end
