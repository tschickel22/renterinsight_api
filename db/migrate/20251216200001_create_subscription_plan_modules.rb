# frozen_string_literal: true

class CreateSubscriptionPlanModules < ActiveRecord::Migration[8.0]
  def change
    create_table :subscription_plan_modules do |t|
      t.references :subscription_plan, null: false, foreign_key: true, index: true
      t.string :module_key, null: false             # e.g., "crm.prospecting", "finance.loans"
      t.boolean :is_enabled, default: true, null: false
      
      t.timestamps
    end

    # Ensure unique module per plan
    add_index :subscription_plan_modules, 
              [:subscription_plan_id, :module_key], 
              unique: true, 
              name: 'idx_plan_modules_unique'
    
    add_index :subscription_plan_modules, :module_key
    add_index :subscription_plan_modules, [:module_key, :is_enabled]
  end
end
