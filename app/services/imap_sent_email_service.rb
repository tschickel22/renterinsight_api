# Service for syncing sent emails from user's Gmail/Outlook
# Reads Sent folder, matches recipients to Leads/Contacts, creates Communication records
# Supports SMTP credentials, OAuth/IMAP (Gmail), and Microsoft Graph API (Outlook)
# NOTE: Only syncs to companies where this email account is configured (prevents cross-company data leakage)
class ImapSentEmailService
  require 'net/imap'
  require 'mail'

  GRAPH_SENT_URL = 'https://graph.microsoft.com/v1.0/me/mailFolders/sentitems/messages'.freeze

  # Sync sent emails via a UserEmailConnection (supports OAuth and SMTP)
  # Microsoft Outlook connections use Graph API (port 993 IMAP blocked on Render)
  # Gmail and SMTP connections continue using IMAP
  # @param connection [UserEmailConnection] The email connection with credentials
  # @param minutes_back [Integer] How many minutes to look back (default: 10)
  def self.sync_via_connection(connection, minutes_back = 10)
    # Route Microsoft OAuth connections through Graph API instead of IMAP
    if connection.provider == 'oauth_outlook'
      return sync_via_microsoft_graph(connection, minutes_back)
    end

    unless connection.imap_available?
      return {
        success: false,
        error: "IMAP not available for connection #{connection.id} (#{connection.provider})",
        synced_count: 0,
        total_emails: 0,
        communications: []
      }
    end

    user = connection.user
    imap_host = connection.imap_server
    imap_port = connection.imap_port

    synced_communications = []

    begin
      Rails.logger.info "[ImapSync] Connecting to #{imap_host}:#{imap_port} for connection #{connection.id} (#{connection.provider})"

      imap = Net::IMAP.new(imap_host, imap_port, true)

      # Authenticate based on connection type
      if connection.oauth_provider?
        connection.imap_authenticate_oauth!(imap)
      else
        imap.login(connection.smtp_username, connection.smtp_password_encrypted)
      end
      Rails.logger.info "[ImapSync] Connected successfully via #{connection.provider}"

      # Find and select Sent folder
      sent_folder = find_sent_folder_from_list(imap, connection.sent_folder_names)
      unless sent_folder
        imap.logout
        imap.disconnect
        return {
          success: false,
          error: "Could not find Sent folder",
          synced_count: 0,
          total_emails: 0,
          communications: []
        }
      end

      imap.select(sent_folder)

      # Process emails (shared logic)
      synced_communications = process_sent_emails(
        imap, user, connection.email_address, minutes_back
      )

      imap.logout
      imap.disconnect

      {
        success: true,
        synced_count: synced_communications.count,
        total_emails: synced_communications.count,
        communications: synced_communications,
        error: nil
      }
    rescue Net::IMAP::NoResponseError => e
      Rails.logger.error "[ImapSync] IMAP error for connection #{connection.id}: #{e.message}"
      { success: false, error: "IMAP error: #{e.message}", synced_count: 0, total_emails: 0, communications: [] }
    rescue => e
      Rails.logger.error "[ImapSync] Connection error for #{connection.id}: #{e.class} - #{e.message}"
      { success: false, error: "#{e.class}: #{e.message}", synced_count: 0, total_emails: 0, communications: [] }
    end
  end

  # Sync sent emails via Microsoft Graph API (replaces IMAP for Outlook OAuth)
  # Uses GET /me/mailFolders/sentitems/messages with date filter
  # @param connection [UserEmailConnection] The oauth_outlook connection
  # @param minutes_back [Integer] How many minutes to look back (default: 10)
  def self.sync_via_microsoft_graph(connection, minutes_back = 10)
    user = connection.user
    from_email = connection.email_address

    Rails.logger.info "[GraphSync] Syncing sent emails for #{from_email} (connection #{connection.id}) via Microsoft Graph API"

    # Get valid Graph API token
    access_token = connection.ensure_graph_token!
    unless access_token.present?
      return {
        success: false,
        error: "No valid OAuth token for Microsoft Graph. Please re-connect your Microsoft account.",
        synced_count: 0,
        total_emails: 0,
        communications: []
      }
    end

    # Fetch sent items from Graph API
    cutoff_time = (Time.current - minutes_back.minutes).utc.iso8601
    messages = fetch_graph_sent_items(access_token, cutoff_time)

    # Handle 401/403 - retry with Graph-scoped token refresh
    if messages.is_a?(Hash) && messages[:error_code].present?
      code = messages[:error_code]
      if code == 401 || code == 403
        Rails.logger.warn "[GraphSync] #{code} from Graph API - refreshing token with read scope"
        new_token = connection.refresh_oauth_token_for_graph_read!
        if new_token
          messages = fetch_graph_sent_items(new_token, cutoff_time)
        end
      end

      # Still an error after retry?
      if messages.is_a?(Hash) && messages[:error_code].present?
        error_msg = messages[:error_message] || "Graph API error (#{messages[:error_code]})"
        if messages[:error_code] == 403
          error_msg = "Insufficient permissions to read sent emails. Please re-connect your Microsoft account to grant Mail.Read access."
        end
        Rails.logger.error "[GraphSync] #{error_msg}"
        connection.record_error!(error_msg)
        return { success: false, error: error_msg, synced_count: 0, total_emails: 0, communications: [] }
      end
    end

    messages = [] unless messages.is_a?(Array)

    Rails.logger.info "[GraphSync] Fetched #{messages.count} sent emails since #{cutoff_time}"

    # Process messages through shared matching logic
    synced = process_graph_sent_emails(messages, user, from_email)

    connection.record_usage!
    connection.clear_error!

    {
      success: true,
      synced_count: synced.count,
      total_emails: messages.count,
      communications: synced,
      error: nil
    }
  rescue => e
    Rails.logger.error "[GraphSync] Error for connection #{connection.id}: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    connection.record_error!(e.message)
    { success: false, error: "#{e.class}: #{e.message}", synced_count: 0, total_emails: 0, communications: [] }
  end

  # Sync sent emails for a user (legacy method using User fields)
  # @param user [User] User with email credentials (email_username, email_password, smtp_server)
  # @param minutes_back [Integer] How many minutes to look back (default: 10)
  def self.sync_sent_emails(user, minutes_back = 10)
    unless user.email_username.present? && user.email_password.present? && user.smtp_server.present?
      return {
        success: false,
        error: "User #{user.id} missing email credentials",
        synced_count: 0,
        total_emails: 0,
        communications: []
      }
    end

    imap_server = user.smtp_server.gsub('smtp.', 'imap.')
    imap_port = 993

    begin
      Rails.logger.info "[ImapSync] Connecting to #{imap_server}:#{imap_port} for user #{user.id}"

      imap = Net::IMAP.new(imap_server, imap_port, true)
      imap.login(user.email_username, user.email_password)
      Rails.logger.info "[ImapSync] Connected successfully"

      sent_folder = find_sent_folder(imap)
      unless sent_folder
        imap.logout
        imap.disconnect
        return { success: false, error: "Could not find Sent folder", synced_count: 0, total_emails: 0, communications: [] }
      end

      imap.select(sent_folder)

      synced = process_sent_emails(imap, user, user.email_username, minutes_back)

      imap.logout
      imap.disconnect

      { success: true, synced_count: synced.count, total_emails: synced.count, communications: synced, error: nil }
    rescue Net::IMAP::NoResponseError => e
      Rails.logger.error "[ImapSync] IMAP error: #{e.message}"
      { success: false, error: "IMAP error: #{e.message}", synced_count: 0, total_emails: 0, communications: [] }
    rescue => e
      Rails.logger.error "[ImapSync] Connection error: #{e.class} - #{e.message}"
      { success: false, error: "#{e.class}: #{e.message}", synced_count: 0, total_emails: 0, communications: [] }
    end
  end

  private

  # ========================================
  # Microsoft Graph API methods
  # ========================================

  # Fetch sent items from Microsoft Graph API
  # Returns Array of message hashes on success, or { error_code:, error_message: } on failure
  def self.fetch_graph_sent_items(access_token, cutoff_iso8601, top: 50)
    query = URI.encode_www_form(
      '$filter' => "sentDateTime ge #{cutoff_iso8601}",
      '$select' => 'id,subject,body,from,toRecipients,ccRecipients,bccRecipients,sentDateTime,internetMessageId',
      '$orderby' => 'sentDateTime desc',
      '$top' => top.to_s
    )

    uri = URI("#{GRAPH_SENT_URL}?#{query}")
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{access_token}"
    request['Content-Type'] = 'application/json'

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
      http.request(request)
    end

    if response.code.to_i == 200
      parsed = JSON.parse(response.body)
      messages = parsed['value'] || []

      # Handle pagination — fetch additional pages if present
      next_link = parsed['@odata.nextLink']
      while next_link.present? && messages.count < 200
        page_uri = URI(next_link)
        page_req = Net::HTTP::Get.new(page_uri)
        page_req['Authorization'] = "Bearer #{access_token}"
        page_res = Net::HTTP.start(page_uri.hostname, page_uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
          http.request(page_req)
        end
        break unless page_res.code.to_i == 200

        page_data = JSON.parse(page_res.body)
        messages.concat(page_data['value'] || [])
        next_link = page_data['@odata.nextLink']
      end

      messages
    else
      error_msg = begin
        JSON.parse(response.body).dig('error', 'message')
      rescue
        response.body.to_s.truncate(200)
      end
      { error_code: response.code.to_i, error_message: error_msg }
    end
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "[GraphSync] Timeout fetching sent items: #{e.message}"
    { error_code: 0, error_message: "Microsoft Graph API timeout: #{e.message}" }
  end

  # Process Graph API sent email messages — same matching logic as IMAP path
  # @param messages [Array<Hash>] Graph API message objects
  # @param user [User] The user who owns the connection
  # @param from_email_address [String] The sender email address
  # @return [Array<Communication>] Created communication records
  def self.process_graph_sent_emails(messages, user, from_email_address)
    synced = []

    # Get all company IDs where this email account is configured
    all_company_ids = company_ids_for_email(from_email_address)
    Rails.logger.info "[GraphSync] Email #{from_email_address} configured in companies: #{all_company_ids.join(', ')}"

    messages.each do |msg|
      begin
        # Extract fields from Graph API message
        internet_message_id = msg['internetMessageId']
        graph_id = msg['id']
        subject = msg['subject'] || '(No Subject)'
        sent_time = msg['sentDateTime'].present? ? Time.parse(msg['sentDateTime']) : Time.current
        body_content = msg.dig('body', 'content') || ''
        body_type = msg.dig('body', 'contentType') || 'Text'

        # Extract primary recipient
        to_recipients = msg['toRecipients'] || []
        recipient_email = to_recipients.first&.dig('emailAddress', 'address')
        next unless recipient_email.present?

        # Sanitize HTML body to plain text for storage consistency
        body_text = if body_type == 'HTML'
          sanitize_html_body(body_content)
        else
          body_content
        end

        # Deduplicate by internetMessageId or graph_id
        dedup_id = internet_message_id.presence || graph_id
        existing_comm = find_existing_communication(dedup_id, graph_id)
        next if existing_comm

        # Match recipient to Lead or Contact in allowed companies
        lead = Lead.where(company_id: all_company_ids)
                   .where('LOWER(email) = ?', recipient_email.downcase)
                   .first

        contact = Lead.none # don't query Contact yet if lead found
        contact = Contact.where(company_id: all_company_ids)
                         .where('LOWER(email) = ?', recipient_email.downcase)
                         .first unless lead

        communicable = lead || contact
        next unless communicable

        # Extract CC/BCC for metadata
        cc_addresses = (msg['ccRecipients'] || []).map { |r| r.dig('emailAddress', 'address') }.compact.join(', ')
        bcc_addresses = (msg['bccRecipients'] || []).map { |r| r.dig('emailAddress', 'address') }.compact.join(', ')

        # Also check if platform already sent this email (matches by to_address + sent_at window)
        platform_sent = Communication.where(
          communicable: communicable,
          channel: 'email',
          direction: 'outbound',
          to_address: recipient_email
        ).where(sent_at: (sent_time - 30.seconds)..(sent_time + 30.seconds)).exists?
        next if platform_sent

        comm = Communication.create!(
          communicable: communicable,
          company_id: communicable.company_id,
          user_id: user.id,
          channel: 'email',
          direction: 'outbound',
          subject: subject,
          body: body_text,
          from_address: from_email_address,
          to_address: recipient_email,
          status: 'sent',
          sent_at: sent_time,
          metadata: {
            source: 'graph_sync',
            graph_message_id: graph_id,
            internet_message_id: internet_message_id,
            recipient_email: recipient_email,
            from: from_email_address,
            cc: cc_addresses.presence,
            bcc: bcc_addresses.presence
          }.compact
        )

        synced << comm
        Rails.logger.info "[GraphSync] Created Communication ##{comm.id} for #{communicable.class.name} ##{communicable.id}"
      rescue => e
        Rails.logger.error "[GraphSync] Error processing message #{msg['id']}: #{e.message}"
        next
      end
    end

    synced
  end

  # Find existing communication by internetMessageId or graph_message_id (dedup)
  def self.find_existing_communication(internet_message_id, graph_id)
    if Communication.columns_hash['metadata'].sql_type == 'jsonb'
      # Check both graph_message_id and internet_message_id, plus legacy imap_uid references
      comm = Communication.where("metadata @> ?", { internet_message_id: internet_message_id }.to_json).first if internet_message_id.present?
      comm ||= Communication.where("metadata @> ?", { graph_message_id: graph_id }.to_json).first if graph_id.present?
      comm ||= Communication.where("metadata @> ?", { imap_message_id: internet_message_id }.to_json).first if internet_message_id.present?
      comm
    else
      if internet_message_id.present?
        comm = Communication.where("metadata LIKE ?", "%#{internet_message_id}%").first
        return comm if comm
      end
      if graph_id.present?
        Communication.where("metadata LIKE ?", "%#{graph_id}%").first
      end
    end
  end

  # Get all company IDs where an email address is configured (shared between IMAP and Graph paths)
  def self.company_ids_for_email(email_address)
    user_company_ids = User.where('LOWER(email_username) = ?', email_address.downcase)
                          .pluck(:company_id)
                          .uniq

    connection_company_ids = UserEmailConnection.where('LOWER(email_address) = ?', email_address.downcase)
                                                .where(is_active: true)
                                                .pluck(:company_id)
                                                .uniq

    (user_company_ids + connection_company_ids).uniq
  end

  # ========================================
  # IMAP methods (Gmail, SMTP, non-Microsoft)
  # ========================================

  # Process sent emails from an already-connected IMAP session
  # Shared logic between sync_sent_emails (legacy) and sync_via_connection
  def self.process_sent_emails(imap, user, from_email_address, minutes_back)
    synced = []

    # Search for emails from last N minutes (IMAP SINCE is date-only)
    search_date = 1.day.ago.to_date
    message_ids = imap.search(['SINCE', search_date])
    cutoff_time = Time.current - minutes_back.minutes

    Rails.logger.info "[ImapSync] Found #{message_ids.count} sent emails since #{search_date}"

    all_company_ids = company_ids_for_email(from_email_address)
    Rails.logger.info "[ImapSync] Email #{from_email_address} configured in companies: #{all_company_ids.join(', ')}"

    message_ids.each do |msg_id|
      begin
        fetch_data = imap.fetch(msg_id, ['ENVELOPE', 'RFC822', 'UID']).first
        next unless fetch_data

        envelope = fetch_data.attr['ENVELOPE']
        raw_email = fetch_data.attr['RFC822']
        imap_uid = fetch_data.attr['UID']

        mail = Mail.new(raw_email)
        sent_time = mail.date ? Time.parse(mail.date.to_s) : Time.current

        next if sent_time < cutoff_time

        recipient_email = envelope.to&.first&.mailbox && envelope.to.first.host ?
          "#{envelope.to.first.mailbox}@#{envelope.to.first.host}" : nil

        next unless recipient_email

        # Deduplicate by IMAP UID (supports both jsonb and text metadata columns)
        existing_comm = if Communication.columns_hash['metadata'].sql_type == 'jsonb'
          Communication.where("metadata @> ?", { imap_uid: imap_uid }.to_json).first
        else
          Communication.where("metadata LIKE ? OR metadata LIKE ?",
            "%\"imap_uid\":#{imap_uid}%", "%imap_uid=>#{imap_uid}%").first
        end
        next if existing_comm

        # Match recipient to Lead or Contact in allowed companies
        lead = Lead.where(company_id: all_company_ids)
                   .where('LOWER(email) = ?', recipient_email.downcase)
                   .first

        contact = Contact.where(company_id: all_company_ids)
                         .where('LOWER(email) = ?', recipient_email.downcase)
                         .first

        communicable = lead || contact

        if communicable
          comm = Communication.create!(
            communicable: communicable,
            company_id: communicable.company_id,
            user_id: user.id,
            channel: 'email',
            direction: 'outbound',
            subject: mail.subject || '(No Subject)',
            body: extract_email_body(mail),
            from_address: from_email_address,
            to_address: recipient_email,
            status: 'sent',
            sent_at: sent_time,
            metadata: {
              source: 'imap_sync',
              imap_uid: imap_uid,
              recipient_email: recipient_email,
              from: mail.from&.first,
              cc: mail.cc&.join(', '),
              bcc: mail.bcc&.join(', ')
            }.compact
          )

          synced << comm
          Rails.logger.info "[ImapSync] Created Communication ##{comm.id} for #{communicable.class.name} ##{communicable.id}"
        end
      rescue => e
        Rails.logger.error "[ImapSync] Error processing message #{msg_id}: #{e.message}"
        next
      end
    end

    synced
  end

  # Find the Sent folder from a list of possible names
  def self.find_sent_folder_from_list(imap, folder_names)
    folder_names.each do |folder_name|
      begin
        imap.examine(folder_name)
        return folder_name
      rescue Net::IMAP::NoResponseError
        next
      end
    end
    nil
  end

  # Find the Sent folder (default list for legacy method)
  def self.find_sent_folder(imap)
    find_sent_folder_from_list(imap, [
      '[Gmail]/Sent Mail',
      'Sent Items',
      'Sent',
      'INBOX.Sent'
    ])
  end

  # Extract email body from email (handles multipart emails)
  # Prefers plain text for clean display; falls back to sanitized HTML
  def self.extract_email_body(mail)
    if mail.multipart?
      text_part = mail.text_part
      html_part = mail.html_part

      if text_part
        text_part.decoded
      elsif html_part
        sanitize_html_body(html_part.decoded)
      else
        mail.body.decoded
      end
    else
      content_type = mail.content_type.to_s.downcase
      if content_type.include?('text/html')
        sanitize_html_body(mail.body.decoded)
      else
        mail.body.decoded
      end
    end
  rescue => e
    Rails.logger.warn "[ImapSync] Error extracting email body: #{e.message}"
    "(Could not extract email body)"
  end

  # Clean up HTML email body — remove Outlook VML, style blocks, head, and XML tags
  def self.sanitize_html_body(html)
    body = html.dup
    # Extract just the <body> content if present
    if body =~ /<body[^>]*>(.*)<\/body>/mi
      body = $1
    end
    # Remove style blocks
    body.gsub!(/<style[^>]*>.*?<\/style>/mi, '')
    # Remove script blocks
    body.gsub!(/<script[^>]*>.*?<\/script>/mi, '')
    # Remove HTML comments (including Outlook conditional comments)
    body.gsub!(/<!--.*?-->/m, '')
    # Remove XML/VML namespace tags (o:p, v:shape, w:*, etc.)
    body.gsub!(/<\/?[ovw]:[^>]*>/mi, '')
    # Remove remaining HTML tags
    body.gsub!(/<[^>]*>/, '')
    # Clean up whitespace
    body.gsub!(/&nbsp;/i, ' ')
    body.gsub!(/\r\n?/, "\n")
    body.gsub!(/[ \t]+/, ' ')
    body.gsub!(/\n{3,}/, "\n\n")
    body.strip
  end
end
