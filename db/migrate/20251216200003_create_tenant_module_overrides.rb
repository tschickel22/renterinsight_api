# frozen_string_literal: true

class CreateTenantModuleOverrides < ActiveRecord::Migration[8.0]
  def change
    create_table :tenant_module_overrides do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.string :module_key, null: false             # e.g., "crm.prospecting", "finance.loans"
      t.boolean :is_enabled, null: false            # true = force enable, false = force disable
      t.string :override_reason                     # Why this was overridden (audit trail)
      t.references :overridden_by, foreign_key: { to_table: :users }, index: true
      
      t.timestamps
    end

    # Ensure unique module override per company
    add_index :tenant_module_overrides, 
              [:company_id, :module_key], 
              unique: true, 
              name: 'idx_tenant_module_override_unique'
    
    add_index :tenant_module_overrides, :module_key
    add_index :tenant_module_overrides, [:module_key, :is_enabled]
  end
end
