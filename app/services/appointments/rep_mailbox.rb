# frozen_string_literal: true

module Appointments
  # Sends a fully built message from the assigned rep's own connected mailbox
  # (Gmail or Outlook), so the customer sees it from the rep and replies go to
  # the rep. The message goes as raw MIME so the calendar part survives intact.
  # Returns false when the rep has no usable connection or the send fails;
  # callers then send from the company address instead.
  module RepMailbox
    GRAPH_SEND_URL = 'https://graph.microsoft.com/v1.0/me/sendMail'

    module_function

    def connection_for(user)
      conn = user.try(:default_email_connection)
      return nil unless conn&.oauth_provider? && conn.oauth_refresh_token_encrypted.present?
      return nil if conn.needs_reauth?

      conn
    rescue StandardError
      nil
    end

    def from_for(user, conn)
      name = conn.try(:display_name).presence || user.try(:full_name).presence
      address = Mail::Address.new(conn.email_address)
      address.display_name = name if name
      address.format
    end

    def deliver(message, conn)
      message.message_id ||= Mail::MessageIdField.new.message_id
      ok = case conn.provider
           when 'oauth_gmail' then deliver_gmail(message, conn)
           when 'oauth_outlook' then deliver_outlook(message, conn)
           else false
           end
      conn.record_usage! if ok && conn.respond_to?(:record_usage!)
      ok
    rescue StandardError => e
      Rails.logger.warn("[Appointments::RepMailbox] connection #{conn&.id}: #{e.class}: #{e.message}")
      false
    end

    def deliver_gmail(message, conn)
      token = conn.oauth_token_expired? ? conn.refresh_oauth_token! : conn.oauth_token_encrypted
      result = Providers::Email::GmailApiProvider.deliver_raw(
        raw_message: message.to_s, access_token: token, refresh_token: conn.oauth_refresh_token_encrypted,
        message_id: message.message_id
      )
      Rails.logger.warn("[Appointments::RepMailbox] gmail #{conn.id}: #{result[:error]}") unless result[:success]
      result[:success]
    end

    # Graph's sendMail takes a whole MIME message as base64 text.
    def deliver_outlook(message, conn)
      token = conn.oauth_token_expired? ? conn.refresh_oauth_token_for_graph! : conn.oauth_token_encrypted
      body = Base64.strict_encode64(message.to_s)
      response = post_graph(token, body)
      if response.code.to_i == 401
        token = conn.refresh_oauth_token_for_graph!
        response = post_graph(token, body) if token.present?
      end
      ok = response.code.to_i == 202
      Rails.logger.warn("[Appointments::RepMailbox] outlook #{conn.id}: #{response.code} #{response.body.to_s[0, 300]}") unless ok
      ok
    end

    def post_graph(token, body)
      uri = URI(GRAPH_SEND_URL)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{token}"
      request['Content-Type'] = 'text/plain'
      request.body = body
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
    end
  end
end
