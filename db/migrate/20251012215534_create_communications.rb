class CreateCommunications < ActiveRecord::Migration[7.0]
  def change
    create_table :communications do |t|
      # Polymorphic association
      t.references :communicable, polymorphic: true, null: false, index: true
      
      # Threading
      t.references :communication_thread, foreign_key: true, index: true
      
      # Communication type
      t.string :direction, null: false
      t.string :channel, null: false
      t.string :provider
      
      # Status tracking
      t.string :status, null: false, default: 'pending'
      
      # Email/SMS fields
      t.string :subject
      t.text :body
      t.string :from_address
      t.string :to_address
      t.text :cc_addresses
      t.text :bcc_addresses
      t.string :reply_to
      
      # Portal visibility
      t.boolean :portal_visible, default: false
      
      # Timestamps for status
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :failed_at
      
      # Error tracking
      t.text :error_message
      
      # Metadata - using text instead of jsonb for SQLite
      t.text :metadata
      
      # External provider message ID
      t.string :external_id
      
      t.timestamps
    end
    
    # Additional indexes
    add_index :communications, :channel
    add_index :communications, :status
    add_index :communications, :direction
    add_index :communications, :created_at
    add_index :communications, :external_id
    add_index :communications, :portal_visible
  end
end
