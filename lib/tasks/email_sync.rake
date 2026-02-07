# Rake tasks for IMAP email sync testing and manual operations
namespace :email_sync do
  desc "Test IMAP connection for a user by ID or email"
  task :test, [:identifier] => :environment do |t, args|
    identifier = args[:identifier]
    
    if identifier.blank?
      puts "❌ Usage: bin/rake email_sync:test[user_id_or_email]"
      puts "   Example: bin/rake email_sync:test[1]"
      puts "   Example: bin/rake email_sync:test[user@example.com]"
      exit 1
    end
    
    # Find user by ID or email_username
    user = if identifier.match?(/^\d+$/)
      User.find_by(id: identifier.to_i)
    else
      User.find_by("email_username ILIKE ?", identifier)
    end
    
    unless user
      puts "❌ User not found: #{identifier}"
      exit 1
    end
    
    unless user.email_username.present? && user.smtp_server.present?
      puts "❌ User #{user.email} has no email settings configured"
      puts "   email_username: #{user.email_username || 'NOT SET'}"
      puts "   smtp_server: #{user.smtp_server || 'NOT SET'}"
      exit 1
    end
    
    puts "\n🔌 Testing IMAP connection for #{user.email_username}..."
    puts "   User ID: #{user.id}"
    puts "   Login email: #{user.email}"
    puts "   SMTP Server: #{user.smtp_server}"
    
    # Derive IMAP server from SMTP server
    imap_server = user.smtp_server.gsub('smtp.', 'imap.')
    imap_port = 993
    
    puts "   Derived IMAP Server: #{imap_server}:#{imap_port}"
    puts ""
    
    begin
      require 'net/imap'
      
      puts "🔐 Attempting connection..."
      imap = Net::IMAP.new(imap_server, imap_port, true)
      puts "✅ SSL connection established"
      
      imap.login(user.email_username, user.email_password)
      puts "✅ Login successful"
      puts ""
      
      puts "📁 Available folders:"
      folders = imap.list("", "*")
      folders.each do |folder|
        puts "   - #{folder.name}"
      end
      puts ""
      
      # Try to find sent folder
      puts "📤 Looking for sent folder..."
      sent_folder = nil
      ['[Gmail]/Sent Mail', 'Sent Items', 'Sent', 'INBOX.Sent'].each do |folder_name|
        begin
          imap.examine(folder_name)
          sent_folder = folder_name
          break
        rescue Net::IMAP::NoResponseError
          next
        end
      end
      
      if sent_folder
        puts "✅ Found sent folder: #{sent_folder}"
        message_count = imap.status(sent_folder, ["MESSAGES"])["MESSAGES"]
        puts "   Total messages: #{message_count}"
      else
        puts "⚠️  Could not find sent folder automatically"
        puts "   Try manually: imap.examine('[Gmail]/Sent Mail')"
      end
      
      imap.logout
      imap.disconnect
      
      puts ""
      puts "✅ Connection test successful!"
      
    rescue Net::IMAP::NoResponseError => e
      puts "❌ IMAP Error: #{e.message}"
      puts ""
      puts "💡 Troubleshooting:"
      puts "   - Check that IMAP is enabled in Gmail settings"
      puts "   - Verify the folder name exists (case-sensitive)"
      exit 1
    rescue Net::IMAP::BadResponseError => e
      puts "❌ Authentication failed: #{e.message}"
      puts ""
      puts "💡 Troubleshooting:"
      puts "   - Verify email_username: #{user.email_username}"
      puts "   - Check that you're using an App-Specific Password (not regular Gmail password)"
      puts "   - Generate new app password at: https://myaccount.google.com/apppasswords"
      exit 1
    rescue => e
      puts "❌ Connection failed: #{e.class} - #{e.message}"
      puts ""
      puts "💡 Troubleshooting:"
      puts "   - Check internet connection"
      puts "   - Verify IMAP server: #{imap_server}:#{imap_port}"
      puts "   - Check firewall settings"
      exit 1
    end
  end
  
  desc "Manually sync sent emails for a user (last 60 minutes)"
  task :user, [:identifier] => :environment do |t, args|
    identifier = args[:identifier]
    
    if identifier.blank?
      puts "❌ Usage: bin/rake email_sync:user[user_id_or_email]"
      exit 1
    end
    
    # Find user
    user = if identifier.match?(/^\d+$/)
      User.find_by(id: identifier.to_i)
    else
      User.find_by("email_username ILIKE ?", identifier)
    end
    
    unless user
      puts "❌ User not found: #{identifier}"
      exit 1
    end
    
    puts "📧 Syncing sent emails for #{user.email_username}..."
    puts "   Looking back: 60 minutes"
    puts ""
    
    begin
      result = ImapSentEmailService.sync_sent_emails(user, 60)
      
      if result[:success]
        puts "✅ Success: Processed #{result[:synced_count]}/#{result[:total_emails]} emails"
        
        if result[:communications].any?
          puts ""
          puts "📨 Recent synced communications:"
          result[:communications].last(5).each do |comm|
            recipient = comm.communicable_type == 'Lead' ? 
              comm.communicable&.full_name : 
              comm.communicable&.email
            puts "  - To: #{recipient || comm.metadata['recipient_email']}"
            puts "    Subject: #{comm.subject}"
            puts "    Sent: #{comm.sent_at}"
            puts ""
          end
        else
          puts ""
          puts "ℹ️  No matching recipients found in Leads/Contacts"
        end
      else
        puts "❌ Sync failed: #{result[:error]}"
        exit 1
      end
      
    rescue => e
      puts "❌ Error: #{e.message}"
      puts e.backtrace.first(3)
      exit 1
    end
  end
  
  desc "Sync sent emails for all users with email settings"
  task :all => :environment do
    users = User.where.not(email_username: nil).where.not(smtp_server: nil)
    
    if users.none?
      puts "ℹ️  No users found with email settings configured"
      exit 0
    end
    
    puts "📧 Syncing sent emails for #{users.count} users..."
    puts ""
    
    success_count = 0
    error_count = 0
    
    users.each do |user|
      print "  #{user.email_username}... "
      
      begin
        result = ImapSentEmailService.sync_sent_emails(user, 30)
        
        if result[:success]
          puts "✅ #{result[:synced_count]}/#{result[:total_emails]}"
          success_count += 1
        else
          puts "❌ #{result[:error]}"
          error_count += 1
        end
      rescue => e
        puts "❌ #{e.message}"
        error_count += 1
      end
    end
    
    puts ""
    puts "📊 Summary:"
    puts "   Success: #{success_count}"
    puts "   Errors: #{error_count}"
    puts "   Total: #{users.count}"
  end
end
