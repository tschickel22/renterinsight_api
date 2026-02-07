class AddCompanyIdAndUserIdToCommunications < ActiveRecord::Migration[8.0]
  def change
    add_column :communications, :company_id, :integer unless column_exists?(:communications, :company_id)
    add_column :communications, :user_id, :integer unless column_exists?(:communications, :user_id)
    
    add_index :communications, :company_id unless index_exists?(:communications, :company_id)
    add_index :communications, :user_id unless index_exists?(:communications, :user_id)
    
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
          AND communications.company_id IS NULL
        SQL
        
        # For Contact communications
        execute <<-SQL
          UPDATE communications
          SET company_id = contacts.company_id
          FROM contacts
          WHERE communications.communicable_type = 'Contact'
          AND communications.communicable_id = contacts.id
          AND communications.company_id IS NULL
        SQL
      end
    end
  end
end
