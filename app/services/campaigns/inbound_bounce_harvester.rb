# frozen_string_literal: true

module Campaigns
  # Reads a sending mailbox's INBOX for bounce (NDR) and auto-reply (OOO)
  # messages and feeds them to Campaigns::BounceHandler.
  #
  # Why this exists: campaigns send from each owner's Gmail/Outlook account
  # (provider oauth_gmail / oauth_outlook), NOT via SES. Non-delivery reports
  # and out-of-office replies for that mail come back to the *sender's* mailbox
  # with the envelope sender — they never reach our reply+campaign-<id>@ inbound
  # webhook. So the delivered/bounced signal is invisible to us unless we read
  # the mailbox. This mirrors ImapSentEmailService (which already reads the Sent
  # folder every 10 min under the same Mail.Read / IMAP scope) but reads Inbox.
  #
  # Matching: BounceHandler keys on a "campaign-<send_id>" token. Our campaign
  # emails carry Reply-To reply+campaign-<send_id>@<domain>, which NDRs echo in
  # the wrapped original message and OOO replies echo in their To/References.
  # We pull that token from the raw message; if absent, we fall back to the most
  # recent CampaignSend to the failed recipient address.
  class InboundBounceHarvester
    GRAPH_INBOX_URL = 'https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages'
    CAMPAIGN_TOKEN_RE = /reply\+campaign-(\d+)@/i
    LOOSE_TOKEN_RE = /campaign-(\d+)/i
    RECIPIENT_FALLBACK_WINDOW = 7.days
    EMAIL_RE = /[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i

    Result = Struct.new(:scanned, :handled, :bounces, :auto_replies, :error, keyword_init: true) do
      def self.empty(error: nil)
        new(scanned: 0, handled: 0, bounces: 0, auto_replies: 0, error: error)
      end
    end

    # Harvest a single connection. minutes_back should exceed the schedule
    # interval so a slow-arriving NDR isn't missed between runs.
    def self.harvest_connection(connection, minutes_back: 30)
      return Result.empty(error: 'inactive') unless connection&.is_active

      cutoff = (Time.current - minutes_back.minutes).utc
      messages =
        if connection.provider == 'oauth_outlook'
          fetch_graph_inbox(connection, cutoff)
        else
          fetch_imap_inbox(connection, cutoff)
        end

      return messages if messages.is_a?(Result) # error passthrough

      result = Result.empty
      Array(messages).each do |parsed|
        result.scanned += 1
        outcome = dispatch_message(parsed, company_id: connection.user&.company_id)
        next unless outcome
        result.handled += 1
        result.bounces += 1 if %i[bounce_hard bounce_soft].include?(outcome)
        result.auto_replies += 1 if outcome == :auto_reply
      end
      result
    rescue => e
      Rails.logger.error "[BounceHarvest] connection #{connection&.id}: #{e.class}: #{e.message}"
      Result.empty(error: e.message)
    end

    # Core, provider-agnostic and unit-testable: classify one parsed message,
    # resolve the campaign send it belongs to, hand it to BounceHandler.
    # parsed: { headers:, from:, subject:, body_text:, content_type:, to: }
    # Returns the classification symbol when handled, nil otherwise.
    def self.dispatch_message(parsed, company_id: nil)
      classification = Campaigns::BounceHandler.classify(parsed)
      return nil if classification == :real_reply

      token = resolve_token(parsed, company_id: company_id)
      return nil unless token

      res = Campaigns::BounceHandler.process(token: token, parsed_email: parsed)
      res&.handled ? res.classification : nil
    end

    # "campaign-<id>" token from the raw message, or a recipient-match fallback.
    def self.resolve_token(parsed, company_id: nil)
      blob = "#{parsed[:headers]} #{parsed[:subject]} #{parsed[:body_text]}"
      if (m = blob.match(CAMPAIGN_TOKEN_RE) || blob.match(LOOSE_TOKEN_RE))
        return "campaign-#{m[1]}"
      end

      send_id = fallback_send_id_for_recipient(parsed, company_id: company_id)
      send_id ? "campaign-#{send_id}" : nil
    end

    # When the token is stripped, find the most recent campaign send to any
    # address named in the message (the bounced recipient), scoped to the
    # sending user's company and a recent window.
    def self.fallback_send_id_for_recipient(parsed, company_id: nil)
      blob = "#{parsed[:body_text]} #{parsed[:headers]} #{parsed[:to]}"
      addrs = blob.scan(EMAIL_RE).map { |a| a.downcase.strip }.uniq
      # Drop our own reply address so the bounce is attributed to the recipient rather
      # than to us. Resolved rather than hardcoded: with the literal here, a reply
      # domain moved to mail.dealertide.com would survive this filter and become the
      # "bounced recipient", matching every recent send to it.
      our_domain = ReplyToAddressService.mail_domain.to_s.downcase
      addrs.reject! { |a| a.include?('reply+') || (our_domain.present? && a.end_with?("@#{our_domain}")) }
      return nil if addrs.empty?

      scope = CampaignSend
              .joins(:campaign_enrollment)
              .where(campaign_enrollments: { email_address_snapshot: addrs })
              .where('campaign_sends.sent_at >= ?', RECIPIENT_FALLBACK_WINDOW.ago)
              .where(bounced_at: nil)
      scope = scope.where(company_id: company_id) if company_id
      scope.order(sent_at: :desc).limit(1).pick(:id)
    end

    # ---- Microsoft Graph (Outlook) ----------------------------------------

    def self.fetch_graph_inbox(connection, cutoff)
      token = connection.ensure_graph_token!
      return Result.empty(error: 'no_graph_token') if token.blank?

      raw = graph_get(token, cutoff)
      if raw.is_a?(Hash) && (raw[:error_code] == 401 || raw[:error_code] == 403)
        token = connection.refresh_oauth_token_for_graph_read!
        raw = token ? graph_get(token, cutoff) : raw
      end
      if raw.is_a?(Hash) && raw[:error_code].present?
        connection.record_error!(raw[:error_message] || "Graph inbox error #{raw[:error_code]}")
        return Result.empty(error: raw[:error_message])
      end
      connection.clear_error!
      Array(raw).map { |m| parse_graph_message(m) }
    end

    def self.graph_get(access_token, cutoff)
      query = URI.encode_www_form(
        '$filter' => "receivedDateTime ge #{cutoff.iso8601}",
        '$select' => 'id,subject,body,from,toRecipients,receivedDateTime,internetMessageHeaders',
        '$orderby' => 'receivedDateTime desc',
        '$top' => '50'
      )
      uri = URI("#{GRAPH_INBOX_URL}?#{query}")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{access_token}"
      req['Content-Type'] = 'application/json'
      # Ask Graph to include the message-level headers we classify on.
      req['Prefer'] = 'outlook.body-content-type="text"'
      resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |h| h.request(req) }
      return (JSON.parse(resp.body)['value'] || []) if resp.code.to_i == 200

      { error_code: resp.code.to_i, error_message: resp.body.to_s[0, 300] }
    rescue => e
      { error_code: 0, error_message: "#{e.class}: #{e.message}" }
    end

    def self.parse_graph_message(msg)
      headers = Array(msg['internetMessageHeaders']).map { |h| "#{h['name']}: #{h['value']}" }.join("\n")
      {
        headers: headers,
        from: msg.dig('from', 'emailAddress', 'address').to_s,
        subject: msg['subject'].to_s,
        body_text: msg.dig('body', 'content').to_s,
        content_type: headers[/^content-type:\s*(.+)$/i, 1].to_s,
        to: Array(msg['toRecipients']).map { |r| r.dig('emailAddress', 'address') }.compact.join(', ')
      }
    end

    # ---- IMAP (Gmail / SMTP) ----------------------------------------------

    def self.fetch_imap_inbox(connection, cutoff)
      return Result.empty(error: 'imap_unavailable') unless connection.respond_to?(:imap_available?) && connection.imap_available?

      imap = Net::IMAP.new(connection.imap_server, connection.imap_port, true)
      if connection.respond_to?(:oauth_provider?) && connection.oauth_provider?
        connection.imap_authenticate_oauth!(imap)
      else
        imap.login(connection.smtp_username, connection.smtp_password_encrypted)
      end
      imap.select('INBOX')

      since = cutoff.strftime('%d-%b-%Y')
      ids = imap.search(['SINCE', since]) || []
      out = ids.last(100).map do |id|
        fetched = imap.fetch(id, 'RFC822')&.first
        raw = fetched&.attr&.dig('RFC822')
        raw ? parse_rfc822(raw) : nil
      end.compact
      imap.logout; imap.disconnect
      out
    rescue => e
      Rails.logger.error "[BounceHarvest] IMAP #{connection&.id}: #{e.message}"
      Result.empty(error: e.message)
    end

    def self.parse_rfc822(raw)
      mail = Mail.read_from_string(raw)
      body_text = (mail.text_part&.decoded || mail.body&.decoded || mail.decoded).to_s
      {
        headers: mail.header.raw_source.to_s,
        from: mail.from&.first.to_s,
        subject: mail.subject.to_s,
        body_text: body_text,
        content_type: mail.content_type.to_s,
        to: Array(mail.to).join(', ')
      }
    rescue => e
      Rails.logger.warn "[BounceHarvest] rfc822 parse failed: #{e.message}"
      nil
    end
  end
end
