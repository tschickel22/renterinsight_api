class AddInvitationTokenToBuyerPortalAccesses < ActiveRecord::Migration[7.0]
  def change
    add_column :buyer_portal_accesses, :invitation_token, :string
    add_column :buyer_portal_accesses, :invitation_token_expires_at, :datetime
    add_column :buyer_portal_accesses, :invitation_accepted_at, :datetime
    
    add_index :buyer_portal_accesses, :invitation_token, unique: true
  end
end
