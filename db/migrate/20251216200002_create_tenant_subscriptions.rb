# frozen_string_literal: true

class CreateTenantSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :tenant_subscriptions do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :subscription_plan, null: false, foreign_key: true, index: true
      
      # Zoho Integration
      t.string :zoho_subscription_id
      t.string :zoho_customer_id
      
      # Status
      t.string :status, null: false, default: 'active'  # active, trial, past_due, cancelled, suspended
      t.string :billing_cycle, default: 'monthly'       # monthly, annual
      
      # Period Tracking
      t.datetime :current_period_start
      t.datetime :current_period_end
      t.datetime :trial_ends_at
      t.datetime :cancelled_at
      t.string :cancellation_reason
      
      # Usage Tracking (snapshot for quick access)
      t.integer :current_users, default: 0
      t.integer :current_storage_gb, default: 0
      t.integer :current_locations, default: 0
      
      # Grace Period
      t.datetime :grace_period_ends_at
      t.boolean :in_grace_period, default: false
      
      # Metadata
      t.jsonb :metadata, default: {}
      t.jsonb :billing_history, default: []           # Store recent billing events
      
      t.timestamps
    end

    # Each company should only have one active subscription
    add_index :tenant_subscriptions, 
              [:company_id, :status], 
              name: 'idx_tenant_sub_company_status'
    
    add_index :tenant_subscriptions, :zoho_subscription_id, unique: true, where: "zoho_subscription_id IS NOT NULL"
    add_index :tenant_subscriptions, :status
    add_index :tenant_subscriptions, :trial_ends_at
    add_index :tenant_subscriptions, :current_period_end
  end
end
