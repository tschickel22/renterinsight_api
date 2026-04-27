class CreateLocationEmailConnections < ActiveRecord::Migration[8.0]
  def change
    create_table :location_email_connections do |t|
      t.bigint :location_id, null: false
      t.bigint :company_id, null: false
      t.string :provider, null: false
      t.string :email_address, null: false
      t.string :display_name
      t.string :smtp_host
      t.integer :smtp_port, default: 587
      t.string :smtp_username
      t.text :smtp_password_encrypted
      t.string :smtp_authentication, default: 'plain'
      t.boolean :smtp_enable_tls, default: true
      t.boolean :smtp_enable_starttls, default: true
      t.text :oauth_token_encrypted
      t.text :oauth_refresh_token_encrypted
      t.datetime :oauth_expires_at
      t.string :oauth_provider
      t.boolean :is_default, default: false
      t.boolean :is_active, default: true
      t.datetime :verified_at
      t.string :verification_token
      t.datetime :verification_sent_at
      t.datetime :last_used_at
      t.datetime :last_error_at
      t.text :last_error_message
      t.timestamps
    end
    add_index :location_email_connections, :location_id, unique: true
    add_index :location_email_connections, :company_id
  end
end
