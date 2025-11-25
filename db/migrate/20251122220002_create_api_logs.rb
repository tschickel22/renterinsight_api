# frozen_string_literal: true

class CreateApiLogs < ActiveRecord::Migration[8.0]
  def up
    # Idempotent: only create if not exists
    return if table_exists?(:api_logs)
    
    create_table :api_logs do |t|
      # Tenant isolation
      t.bigint :company_id
      
      # API details
      t.string :provider, null: false # 'zego', 'stripe', 'twilio', etc.
      t.string :action # API action/method called
      t.string :url # API endpoint URL
      t.string :status, default: 'pending' # 'pending', 'success', 'failure', 'error'
      
      # Request/Response
      t.text :request # Request body (cleaned of sensitive data)
      t.text :response # Response body
      
      # Timing
      t.datetime :started_at
      t.datetime :completed_at
      t.integer :duration_ms # Duration in milliseconds
      
      # Request metadata
      t.string :ip_address
      t.string :user_agent
      t.jsonb :metadata, default: {} # Additional context
      
      # Audit
      t.timestamps
    end
    
    # Indexes
    add_index :api_logs, :company_id
    add_index :api_logs, :provider
    add_index :api_logs, :status
    add_index :api_logs, [:provider, :action]
    add_index :api_logs, :created_at
    add_index :api_logs, [:company_id, :provider, :created_at]
    
    # Foreign key
    add_foreign_key :api_logs, :companies, column: :company_id
    
    puts "✅ API logs table created successfully"
  end
  
  def down
    drop_table :api_logs if table_exists?(:api_logs)
  end
end
