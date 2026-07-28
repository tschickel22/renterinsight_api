# frozen_string_literal: true

# Job to sync sent emails from user's email account to RenterInsight Communications
# Runs every 5 minutes to capture emails sent from Gmail/Outlook to Leads/Contacts
# Microsoft Outlook uses Graph API; Gmail and SMTP use IMAP
#
# This eliminates the need for manual BCC - just send email normally and it auto-logs!
#
class SyncSentEmailsJob < ApplicationJob
  queue_as :default

  # Process all active email connections
  def perform(user_email_connection_id = nil)
    if user_email_connection_id
      # Process single connection (for testing or retry)
      connection = UserEmailConnection.find_by(id: user_email_connection_id)
      sync_connection(connection) if connection
    else
      # Process all active SMTP connections (IMAP path)
      UserEmailConnection.active.smtp.find_each do |connection|
        sync_connection(connection)
      end
    end
  end

  private

  def sync_connection(connection)
    # Microsoft OAuth connections use Graph API via ImapSentEmailService
    if connection.provider == 'oauth_outlook'
      Rails.logger.info "[SyncSentEmails] Processing #{connection.email_address} via Graph API (User ##{connection.user_id})"
      result = ImapSentEmailService.sync_via_microsoft_graph(connection, 10)
      if result[:success]
        Rails.logger.info "[SyncSentEmails] Graph sync: #{result[:synced_count]} emails for #{connection.email_address}"
      else
        Rails.logger.error "[SyncSentEmails] Graph sync failed for #{connection.email_address}: #{result[:error]}"
      end
      return
    end

    return unless connection.imap_available?

    Rails.logger.info "[SyncSentEmails] Processing #{connection.email_address} (User ##{connection.user_id})"

    begin
      imap = Net::IMAP.new(connection.imap_server, connection.imap_port, true)
      imap.login(connection.smtp_username, connection.smtp_password_encrypted)

      # Find sent folder
      sent_folder = select_sent_folder(imap, connection)
      unless sent_folder
        Rails.logger.warn "[SyncSentEmails] No sent folder found for #{connection.email_address}"
        connection.record_error!("No sent folder found. Tried: #{connection.sent_folder_names.join(', ')}")
        return
      end

      # Search for emails sent in last 10 minutes (to catch recent sends)
      since_date = 10.minutes.ago.strftime('%d-%b-%Y')
      message_ids = imap.search(['SINCE', since_date])

      Rails.logger.info "[SyncSentEmails] Found #{message_ids.count} sent emails for #{connection.email_address}"

      synced_count = 0
      message_ids.each do |message_id|
        if process_sent_email(imap, message_id, connection)
          synced_count += 1
        end
      end

      Rails.logger.info "[SyncSentEmails] Synced #{synced_count}/#{message_ids.count} emails for #{connection.email_address}"

      # Record successful sync
      connection.record_usage!
      connection.clear_error!

      imap.logout
      imap.disconnect

    rescue Net::IMAP::NoResponseError => e
      Rails.logger.error "[SyncSentEmails] IMAP Auth failed for #{connection.email_address}: #{e.message}"
      connection.record_error!("IMAP authentication failed: #{e.message}")
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      Rails.logger.error "[SyncSentEmails] IMAP timeout for #{connection.email_address}: #{e.message}"
      connection.record_error!("IMAP connection timeout")
    rescue SocketError => e
      Rails.logger.error "[SyncSentEmails] IMAP connection failed for #{connection.email_address}: #{e.message}"
      connection.record_error!("Could not connect to IMAP server")
    rescue => e
      Rails.logger.error "[SyncSentEmails] Error for #{connection.email_address}: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      connection.record_error!(e.message)
    end
  end

  def select_sent_folder(imap, connection)
    # Try common sent folder names
    connection.sent_folder_names.each do |folder|
      begin
        imap.select(folder)
        Rails.logger.info "[SyncSentEmails] Selected folder: #{folder}"
        return folder
      rescue Net::IMAP::NoResponseError
        # Folder doesn't exist, try next
      end
    end

    nil
  end

  def process_sent_email(imap, message_id, connection)
    # Fetch envelope (metadata)
    envelope_data = imap.fetch(message_id, 'ENVELOPE')[0]
    return false unless envelope_data

    envelope = envelope_data.attr['ENVELOPE']
    return false unless envelope&.to && envelope.to.first

    # Get Message-ID header to avoid duplicates
    uid = imap.fetch(message_id, 'UID')[0].attr['UID']
    message_id_header = imap.fetch(message_id, 'BODY[HEADER.FIELDS (MESSAGE-ID)]')[0].attr['BODY[HEADER.FIELDS (MESSAGE-ID)]']
    email_message_id = extract_message_id(message_id_header)

    # Check if already synced
    if email_message_id.present?
      existing = Communication.find_by(
        user_id: connection.user_id,
        metadata: { imap_message_id: email_message_id }
      )

      if existing
        Rails.logger.debug "[SyncSentEmails] Email already synced: #{email_message_id}"
        return false
      end
    end

    # Extract recipient email
    to_email = "#{envelope.to.first.mailbox}@#{envelope.to.first.host}".downcase

    # Find matching Lead or Contact
    lead = connection.company.leads.where('LOWER(email) = ?', to_email).first
    contact = connection.company.contacts.where('LOWER(email) = ?', to_email).first unless lead

    # Skip if no matching Lead/Contact
    unless lead || contact
      Rails.logger.debug "[SyncSentEmails] No Lead/Contact found for #{to_email}"
      return false
    end

    # Get email body
    body_data = imap.fetch(message_id, 'BODY[TEXT]')[0]&.attr['BODY[TEXT]'] || ''

    # Get HTML body if available
    html_body_data = imap.fetch(message_id, 'BODY[TEXT.HTML]')[0]&.attr['BODY[TEXT.HTML]']

    # Prefer HTML body for better formatting
    body_content = html_body_data.present? ? html_body_data : body_data

    # Create Communication record
    communication = Communication.create!(
      communicable: lead || contact,
      # Without this the synced email is invisible to company-scoped queries.
      company_id: (lead || contact).try(:company_id),
      user: connection.user,
      channel: 'email',
      direction: 'outbound',
      subject: envelope.subject,
      body: body_content.to_s.force_encoding('UTF-8'),
      sent_at: envelope.date || Time.current,
      status: 'sent',
      metadata: {
        source: 'imap_sync',
        imap_message_id: email_message_id,
        imap_uid: uid,
        email_connection_id: connection.id,
        synced_at: Time.current
      }
    )

    Rails.logger.info "[SyncSentEmails] Created Communication ##{communication.id} for #{to_email} (#{lead ? 'Lead' : 'Contact'} ##{(lead || contact).id})"

    true

  rescue => e
    Rails.logger.error "[SyncSentEmails] Error processing email #{message_id}: #{e.message}"
    false
  end

  def extract_message_id(header_data)
    return nil if header_data.blank?

    # Parse Message-ID header
    # Format: "Message-ID: <abc123@gmail.com>\r\n"
    match = header_data.match(/<([^>]+)>/)
    match ? match[1] : nil
  end
end
