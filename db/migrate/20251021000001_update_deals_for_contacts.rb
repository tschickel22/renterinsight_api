class UpdateDealsForContacts < ActiveRecord::Migration[8.0]
  def change
    # Make account_id optional - deals can have just a contact
    change_column_null :deals, :account_id, true
    
    # Add contact_id and vehicle_id to deals table
    add_column :deals, :contact_id, :integer
    add_column :deals, :vehicle_id, :integer
    
    # Add indexes for better query performance
    add_index :deals, :contact_id
    add_index :deals, :vehicle_id
    
    # Add foreign key for contact_id (vehicle_id can be a string reference for now)
    add_foreign_key :deals, :contacts, column: :contact_id
  end
end
