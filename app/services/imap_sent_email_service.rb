# Service for syncing sent emails from user's Gmail/Outlook via IMAP
# Reads Sent folder, matches recipients to Leads/Contacts, creates Communication records
# Supports both SMTP credentials and OAuth (XOAUTH2) connections
# NOTE: Only syncs to companies where this email account is configured (prevents cross-company data leakage)
class ImapSentEmailService
  require 'net/imap'
  require 'mail'

  # Sync sent emails via a UserEmailConnection (supports OAuth and SMTP)
  # @param connection [UserEmailConnection] The email connection with IMAP credentials
  # @param minutes_back [Integer] How many minutes to look back (default: 10)
  def self.sync_via_connection(connection, minutes_back = 10)
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

  # Process sent emails from an already-connected IMAP session
  # Shared logic between sync_sent_emails (legacy) and sync_via_connection
  def self.process_sent_emails(imap, user, from_email_address, minutes_back)
    synced = []

    # Search for emails from last N minutes (IMAP SINCE is date-only)
    search_date = 1.day.ago.to_date
    message_ids = imap.search(['SINCE', search_date])
    cutoff_time = Time.current - minutes_back.minutes

    Rails.logger.info "[ImapSync] Found #{message_ids.count} sent emails since #{search_date}"

    # Get all company IDs where this email account is configured
    user_company_ids = User.where('LOWER(email_username) = ?', from_email_address.downcase)
                          .pluck(:company_id)
                          .uniq

    # Also include companies from UserEmailConnection
    connection_company_ids = UserEmailConnection.where('LOWER(email_address) = ?', from_email_address.downcase)
                                                .where(is_active: true)
                                                .pluck(:company_id)
                                                .uniq

    all_company_ids = (user_company_ids + connection_company_ids).uniq
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
            }.to_json
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
