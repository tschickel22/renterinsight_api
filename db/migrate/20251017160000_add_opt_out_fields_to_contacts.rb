class AddOptOutFieldsToContacts < ActiveRecord::Migration[8.0]
  def change
    add_column :contacts, :opt_out_email, :boolean, default: false, null: false
    add_column :contacts, :opt_out_email_at, :datetime
    add_column :contacts, :opt_out_sms, :boolean, default: false, null: false
    add_column :contacts, :opt_out_sms_at, :datetime
    
    add_index :contacts, :opt_out_email
    add_index :contacts, :opt_out_sms
  end
end
