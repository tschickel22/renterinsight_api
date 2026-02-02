# frozen_string_literal: true

class CreateUserEmailConnections < ActiveRecord::Migration[8.0]
  def change
    create_table :user_email_connections do |t|
      t.references :user, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      
      # Connection type: smtp, oauth_gmail, oauth_outlook, company_domain
      t.string :provider, null: false, default: 'smtp'
      
      # Email identity
      t.string :email_address, null: false
      t.string :display_name
      
      # SMTP configuration (encrypted fields use Rails credentials or attr_encrypted)
      t.string :smtp_host
      t.integer :smtp_port, default: 587
      t.string :smtp_username
      t.text :smtp_password_encrypted
      t.string :smtp_authentication, default: 'plain' # plain, login, cram_md5
      t.boolean :smtp_enable_tls, default: true
      t.boolean :smtp_enable_starttls, default: true
      
      # OAuth configuration (for future Gmail/Outlook integration)
      t.text :oauth_token_encrypted
      t.text :oauth_refresh_token_encrypted
      t.datetime :oauth_expires_at
      t.string :oauth_provider # google, microsoft
      
      # Status and verification
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

    # Indexes
    add_index :user_email_connections, [:user_id, :is_default], name: 'idx_user_email_connections_user_default'
    add_index :user_email_connections, [:company_id, :email_address], name: 'idx_user_email_connections_company_email'
    add_index :user_email_connections, :email_address
    add_index :user_email_connections, :verification_token, unique: true, where: 'verification_token IS NOT NULL'
    
    # Ensure only one default per user
    # Note: Partial unique indexes work in PostgreSQL, for SQLite we'll handle in model
    if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      execute <<-SQL
        CREATE UNIQUE INDEX idx_user_email_connections_one_default 
        ON user_email_connections (user_id) 
        WHERE is_default = true;
      SQL
    end
  end
end
