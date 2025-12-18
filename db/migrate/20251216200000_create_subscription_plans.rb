# frozen_string_literal: true

class CreateSubscriptionPlans < ActiveRecord::Migration[8.0]
  def change
    create_table :subscription_plans do |t|
      # Basic Info
      t.string :name, null: false                    # Internal key: "starter", "professional", "enterprise"
      t.string :display_name, null: false            # User-facing: "Starter", "Professional", "Enterprise"
      t.text :description
      t.string :category, null: false, default: 'professional'  # starter, professional, enterprise
      
      # Zoho Integration
      t.string :zoho_plan_code                       # DMS_STARTER, DMS_PROFESSIONAL, etc.
      t.string :zoho_product_id                      # Zoho product reference
      
      # Pricing
      t.decimal :pricing_monthly, precision: 10, scale: 2, default: 0
      t.decimal :pricing_annual, precision: 10, scale: 2, default: 0
      t.string :currency, default: 'USD'
      t.string :billing_model, default: 'flat'      # flat, per_user, tiered
      
      # Limits
      t.integer :max_users, default: 10
      t.integer :max_storage_gb, default: 50
      t.integer :max_locations, default: 1
      t.integer :max_api_calls, default: 10000
      
      # Trial & Setup
      t.boolean :trial_enabled, default: true
      t.integer :trial_days, default: 14
      t.decimal :setup_fee, precision: 10, scale: 2, default: 0
      
      # Discounts
      t.string :discount_type                        # percent, amount, null
      t.decimal :discount_value, precision: 10, scale: 2
      t.string :zoho_coupon_code
      
      # Status & Ordering
      t.boolean :is_active, default: true
      t.boolean :is_popular, default: false
      t.integer :position, default: 0               # For ordering in UI
      
      # Metadata
      t.jsonb :metadata, default: {}                # For custom attributes
      
      t.timestamps
    end

    add_index :subscription_plans, :name, unique: true
    add_index :subscription_plans, :zoho_plan_code, unique: true, where: "zoho_plan_code IS NOT NULL"
    add_index :subscription_plans, :category
    add_index :subscription_plans, :is_active
    add_index :subscription_plans, [:is_active, :position]
  end
end
