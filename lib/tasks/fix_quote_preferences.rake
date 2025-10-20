namespace :fix do
  desc "Migrate Quote-level communication preferences to Contact/Account level"
  task quote_preferences: :environment do
    puts "Starting migration of Quote preferences to Contact/Account preferences..."
    
    migrated = 0
    deleted = 0
    skipped = 0
    
    # Find all preferences with recipient_type='Quote'
    CommunicationPreference.where(recipient_type: 'Quote').find_each do |quote_pref|
      quote = Quote.find_by(id: quote_pref.recipient_id)
      
      unless quote
        puts "  Quote ##{quote_pref.recipient_id} not found, deleting orphaned preference"
        quote_pref.destroy
        deleted += 1
        next
      end
      
      # Determine the actual recipient (contact or account)
      actual_recipient = quote.contact || quote.account
      
      unless actual_recipient
        puts "  Quote ##{quote.id} has no contact or account, deleting preference"
        quote_pref.destroy
        deleted += 1
        next
      end
      
      # Check if preference already exists for the actual recipient
      existing_pref = CommunicationPreference.find_by(
        recipient: actual_recipient,
        channel: quote_pref.channel,
        category: quote_pref.category
      )
      
      if existing_pref
        # Preference already exists for contact/account
        # Keep the more permissive setting (opted_in=true takes precedence)
        if quote_pref.opted_in? && !existing_pref.opted_in?
          puts "  Updating #{actual_recipient.class.name} ##{actual_recipient.id} to opted_in for #{quote_pref.channel}/#{quote_pref.category}"
          existing_pref.opt_in!(ip_address: 'System Migration', user_agent: 'DataMigration')
          migrated += 1
        else
          skipped += 1
        end
        
        # Delete the Quote-level preference
        quote_pref.destroy
      else
        # No existing preference, migrate this one
        puts "  Migrating Quote ##{quote.id} preference to #{actual_recipient.class.name} ##{actual_recipient.id} for #{quote_pref.channel}/#{quote_pref.category}"
        
        CommunicationPreference.create!(
          recipient: actual_recipient,
          channel: quote_pref.channel,
          category: quote_pref.category,
          opted_in: quote_pref.opted_in,
          opted_in_at: quote_pref.opted_in_at,
          opted_out_at: quote_pref.opted_out_at,
          opted_out_reason: quote_pref.opted_out_reason,
          ip_address: quote_pref.ip_address,
          user_agent: quote_pref.user_agent,
          compliance_metadata: quote_pref.compliance_metadata
        )
        
        quote_pref.destroy
        migrated += 1
      end
    end
    
    puts "\nMigration complete!"
    puts "  Migrated: #{migrated}"
    puts "  Deleted: #{deleted}"
    puts "  Skipped: #{skipped}"
    puts "  Total processed: #{migrated + deleted + skipped}"
  end
  
  desc "Delete all Quote-level communication preferences"
  task delete_quote_preferences: :environment do
    puts "Deleting all Quote-level communication preferences..."
    
    count = CommunicationPreference.where(recipient_type: 'Quote').count
    CommunicationPreference.where(recipient_type: 'Quote').delete_all
    
    puts "Deleted #{count} Quote-level preferences"
  end
  
  desc "Show Quote-level preferences that exist"
  task show_quote_preferences: :environment do
    puts "Quote-level communication preferences:\n"
    
    CommunicationPreference.where(recipient_type: 'Quote').find_each do |pref|
      quote = Quote.find_by(id: pref.recipient_id)
      
      if quote
        contact_account = quote.contact || quote.account
        puts "  Quote ##{quote.id} (#{quote.quote_number}) - #{pref.channel}/#{pref.category} - opted_in: #{pref.opted_in}"
        if contact_account
          puts "    -> Should be #{contact_account.class.name} ##{contact_account.id}"
        else
          puts "    -> No contact or account!"
        end
      else
        puts "  Quote ##{pref.recipient_id} (NOT FOUND) - #{pref.channel}/#{pref.category} - opted_in: #{pref.opted_in}"
      end
    end
    
    total = CommunicationPreference.where(recipient_type: 'Quote').count
    puts "\nTotal: #{total} Quote-level preferences"
  end
end
