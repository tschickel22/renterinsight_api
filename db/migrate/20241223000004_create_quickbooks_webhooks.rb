class CreateQuickbooksWebhooks < ActiveRecord::Migration[8.0]
  def change
    create_table :quickbooks_webhooks do |t|
      t.references :company, null: false, foreign_key: true
      
      t.string :realm_id, null: false # QB company ID from webhook
      t.string :event_name, null: false # 'Customer.Create', 'Invoice.Update', etc.
      t.string :entity_name # 'Customer', 'Invoice', etc.
      t.string :entity_id # QB entity ID
      t.string :operation # 'Create', 'Update', 'Delete', 'Merge'
      
      t.jsonb :webhook_payload # Full webhook payload
      t.string :status, default: 'pending' # 'pending', 'processed', 'error', 'ignored'
      t.text :processing_error
      t.datetime :processed_at
      t.integer :retry_count, default: 0
      
      t.timestamps
    end
    
    add_index :quickbooks_webhooks, [:company_id, :status, :created_at]
    add_index :quickbooks_webhooks, [:realm_id, :entity_id]
    add_index :quickbooks_webhooks, :event_name
  end
end
