class CreateCommunicationPreferences < ActiveRecord::Migration[7.0]
  def change
    create_table :communication_preferences do |t|
      # Polymorphic association
      t.references :recipient, polymorphic: true, null: false, index: true
      
      # Preference details
      t.string :channel, null: false
      t.string :category
      
      # Opt-in/out status
      t.boolean :opted_in, default: true, null: false
      t.datetime :opted_in_at
      t.datetime :opted_out_at
      
      # Unsubscribe token
      t.string :unsubscribe_token
      
      # Opt-out details
      t.text :opted_out_reason
      
      # Compliance tracking
      t.string :ip_address
      t.string :user_agent
      t.text :compliance_metadata  # text instead of jsonb for SQLite
      
      t.timestamps
    end
    
    add_index :communication_preferences, :channel
    add_index :communication_preferences, :category
    add_index :communication_preferences, :opted_in
    add_index :communication_preferences, :unsubscribe_token, unique: true
    add_index :communication_preferences, 
              [:recipient_type, :recipient_id, :channel, :category],
              unique: true,
              name: 'idx_prefs_on_recipient_channel_category'
  end
end
