class AddInvitationFieldsToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :invitation_token, :string
    add_column :users, :invitation_sent_at, :datetime
    add_column :users, :invitation_expires_at, :datetime
    
    add_index :users, :invitation_token, unique: true
  end
end
