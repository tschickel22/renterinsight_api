# Service for syncing sent emails from user's Gmail/Outlook via IMAP
# Reads Sent folder, matches recipients to Leads/Contacts, creates Communication records
# NOTE: Only syncs to companies where this Gmail account is configured (prevents cross-company data leakage)
class ImapSentEmailService
  require 'net/imap'
  require 'mail'
  
  # Sync sent emails for a user
  # @param user [User] User with email credentials (email_username, email_password, smtp_server)
  # @param minutes_back [Integer] How many minutes to look back (default: 10)
  # @return [Hash] { success: boolean, synced_count: integer, total_emails: integer, communications: array, error: string }
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
    
    # Derive IMAP server from SMTP server (smtp.gmail.com -> imap.gmail.com)
    imap_server = user.smtp_server.gsub('smtp.', 'imap.')
    imap_port = 993
    
    synced_communications = []
    
    begin
      Rails.logger.info "[ImapSync] Connecting to #{imap_server}:#{imap_port} for user #{user.id}"
      
      # Connect to IMAP server with SSL
      imap = Net::IMAP.new(imap_server, imap_port, true)
      
      # Login
      imap.login(user.email_username, user.email_password)
      Rails.logger.info "[ImapSync] Connected successfully"
      
      # Find and select Sent folder
      sent_folder = find_sent_folder(imap)
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
      Rails.logger.info "[ImapSync] Selected folder: #{sent_folder}"
      
      # Search for emails from last N minutes
      # IMAP SINCE is date-only and uses email's Date header (not UTC), so search from yesterday
      # Then filter by actual time in Ruby to handle timezone differences
      search_date = 1.day.ago.to_date
      message_ids = imap.search(['SINCE', search_date])
      
      Rails.logger.info "[ImapSync] Found #{message_ids.count} sent emails since #{search_date}"
      
      # Fetch emails and process
      cutoff_time = Time.current - minutes_back.minutes
      
      message_ids.each do |msg_id|
        begin
          # Fetch the email envelope and body
          fetch_data = imap.fetch(msg_id, ['ENVELOPE', 'RFC822', 'UID']).first
          next unless fetch_data
          
          envelope = fetch_data.attr['ENVELOPE']
          raw_email = fetch_data.attr['RFC822']
          imap_uid = fetch_data.attr['UID']
          
          # Parse the email
          mail = Mail.new(raw_email)
          sent_time = mail.date ? Time.parse(mail.date.to_s) : Time.current
          
          # Skip if older than our time window (SINCE is date-only, this adds time precision)
          next if sent_time < cutoff_time
          
          # Extract recipient email (first TO address)
          recipient_email = envelope.to&.first&.mailbox && envelope.to.first.host ? 
            "#{envelope.to.first.mailbox}@#{envelope.to.first.host}" : nil
          
          Rails.logger.info "[ImapSync] Processing email to: #{recipient_email}"
          
          next unless recipient_email
          
          # Check if we already synced this email (by IMAP UID)
          # Note: metadata is TEXT (serialized hash), not JSONB, so use LIKE
          existing_comm = Communication.where("metadata LIKE ?", "%imap_uid=>#{imap_uid}%").first
          if existing_comm
            Rails.logger.debug "[ImapSync] Skipping already synced email UID #{imap_uid}"
            next
          end
          
          # SECURITY: Only sync to companies where this Gmail account is configured
          # Get all company IDs where this email_username (Gmail account) is set up
          user_company_ids = User.where('LOWER(email_username) = ?', user.email_username.downcase)
                                .pluck(:company_id)
                                .uniq
          
          Rails.logger.info "[ImapSync] Gmail account #{user.email_username} configured in companies: #{user_company_ids.join(', ')}"
          
          # Search for Lead or Contact ONLY in companies where this Gmail account is configured
          lead = Lead.where(company_id: user_company_ids)
                    .where('LOWER(email) = ?', recipient_email.downcase)
                    .first
          
          contact = Contact.where(company_id: user_company_ids)
                          .where('LOWER(email) = ?', recipient_email.downcase)
                          .first
          
          communicable = lead || contact
          
          if communicable
            Rails.logger.info "[ImapSync] Match found - #{communicable.class.name} ##{communicable.id} in Company #{communicable.company_id}"
            
            # Create Communication in the lead/contact's company
            comm = Communication.create!(
              communicable: communicable,
              company_id: communicable.company_id,
              user_id: user.id,  # Track who sent the email
              channel: 'email',
              direction: 'outbound',
              subject: mail.subject || '(No Subject)',
              body: extract_email_body(mail),
              from_address: user.email_username,
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
              }
            )
            
            synced_communications << comm
            Rails.logger.info "[ImapSync] Created Communication ##{comm.id} for #{communicable.class.name} ##{communicable.id} in Company #{communicable.company_id}"
          else
            Rails.logger.debug "[ImapSync] No matching Lead/Contact found for #{recipient_email} in companies where #{user.email_username} is configured"
          end
          
        rescue => e
          Rails.logger.error "[ImapSync] Error processing message #{msg_id}: #{e.message}"
          Rails.logger.error e.backtrace.first(3).join("\n")
          next
        end
      end
      
      # Cleanup
      imap.logout
      imap.disconnect
      
      {
        success: true,
        synced_count: synced_communications.count,
        total_emails: message_ids.count,
        communications: synced_communications,
        error: nil
      }
      
    rescue Net::IMAP::NoResponseError => e
      Rails.logger.error "[ImapSync] IMAP error: #{e.message}"
      {
        success: false,
        error: "IMAP error: #{e.message}",
        synced_count: 0,
        total_emails: 0,
        communications: []
      }
    rescue => e
      Rails.logger.error "[ImapSync] Connection error: #{e.class} - #{e.message}"
      {
        success: false,
        error: "#{e.class}: #{e.message}",
        synced_count: 0,
        total_emails: 0,
        communications: []
      }
    end
  end
  
  private
  
  # Find the Sent folder (different names for Gmail vs Outlook)
  def self.find_sent_folder(imap)
    possible_folders = [
      '[Gmail]/Sent Mail',  # Gmail
      'Sent Items',         # Outlook
      'Sent',               # Generic
      'INBOX.Sent'          # Some IMAP servers
    ]
    
    possible_folders.each do |folder_name|
      begin
        imap.examine(folder_name)
        return folder_name
      rescue Net::IMAP::NoResponseError
        next
      end
    end
    
    nil
  end
  
  # Extract plain text body from email (handles multipart emails)
  def self.extract_email_body(mail)
    if mail.multipart?
      # Try to get plain text part first
      text_part = mail.text_part
      html_part = mail.html_part
      
      if text_part
        text_part.decoded
      elsif html_part
        # Strip HTML tags for plain text storage
        html_part.decoded.gsub(/<[^>]*>/, '').strip
      else
        mail.body.decoded
      end
    else
      mail.body.decoded
    end
  rescue => e
    Rails.logger.warn "[ImapSync] Error extracting email body: #{e.message}"
    "(Could not extract email body)"
  end
end
