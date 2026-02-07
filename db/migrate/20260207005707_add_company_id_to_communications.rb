class AddCompanyIdAndUserIdToCommunications < ActiveRecord::Migration[8.0]
  def change
    add_column :communications, :company_id, :integer
    add_column :communications, :user_id, :integer
    
    add_index :communications, :company_id
    add_index :communications, :user_id
    
    # Backfill company_id for existing communications
    reversible do |dir|
      dir.up do
        # For Lead communications
        execute <<-SQL
          UPDATE communications
          SET company_id = leads.company_id
          FROM leads
          WHERE communications.communicable_type = 'Lead'
          AND communications.communicable_id = leads.id
        SQL
        
        # For Contact communications
        execute <<-SQL
          UPDATE communications
          SET company_id = contacts.company_id
          FROM contacts
          WHERE communications.communicable_type = 'Contact'
          AND communications.communicable_id = contacts.id
        SQL
        
        # Note: user_id will be NULL for existing communications
        # Future IMAP syncs will populate it with the sender's user ID
      end
    end
  end
end
