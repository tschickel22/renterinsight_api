class CreateInvitations < ActiveRecord::Migration[8.0]
  def change
    create_table :invitations do |t|
      # Core fields
      t.string :invitation_type, null: false # company_user, portal_user, tenant
      t.string :token_digest, null: false
      t.string :email, null: false
      t.string :phone # Optional SMS delivery
      t.string :status, null: false, default: 'pending' # pending, accepted, expired, revoked
      
      # Recipient info
      t.string :recipient_name
      t.json :recipient_data, default: {} # Additional data for pre-filling forms
      
      # Invitation metadata
      t.references :invited_by, foreign_key: { to_table: :users }, null: false
      t.references :company, foreign_key: true # Context for company/portal invitations
      t.string :role # For user invitations (admin, staff, etc.)
      t.json :permissions, default: [] # For granular permissions
      
      # Delivery tracking
      t.string :delivery_method, null: false # email, sms, both
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :viewed_at
      t.datetime :accepted_at
      t.datetime :expires_at, null: false
      
      # Security & audit
      t.integer :resend_count, default: 0
      t.datetime :last_sent_at
      t.string :ip_address # IP when invitation was accepted
      t.string :user_agent # User agent when accepted
      t.integer :attempts, default: 0 # Failed acceptance attempts
      
      # Notes & customization
      t.text :message # Optional personal message from inviter
      t.text :notes # Internal notes
      
      t.timestamps
    end
    
    add_index :invitations, :token_digest, unique: true
    add_index :invitations, :email
    add_index :invitations, [:invitation_type, :status]
    add_index :invitations, :expires_at
    add_index :invitations, :status
    add_index :invitations, [:company_id, :status]
  end
end
