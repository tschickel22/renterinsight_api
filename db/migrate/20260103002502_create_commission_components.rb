# frozen_string_literal: true

class CreateCommissionComponents < ActiveRecord::Migration[8.0]
  def change
    create_table :commission_components do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, foreign_key: true  # null = company-wide
      
      t.string :name, null: false
      t.string :component_type, null: false
      t.string :applies_to_role              # "salesperson", "manager", "f_and_i", null = all
      t.boolean :is_active, default: true
      
      # For percent_of_gross type
      t.string :gross_type                   # "front", "back", "total", "commissionable_front", "addon"
      t.decimal :rate, precision: 8, scale: 6
      
      # For flat types
      t.decimal :flat_amount, precision: 15, scale: 2
      
      # For monthly_bonus type
      t.integer :units_threshold
      t.string :threshold_period             # "monthly", "quarterly"
      
      # Conditions (simple)
      t.string :deal_type                    # "new", "used", "all"
      t.string :vertical                     # "rv", "mh", "all"
      
      t.integer :sequence, default: 0        # Order of calculation
      t.text :description
      
      t.timestamps
    end
    
    # Indexes for efficient queries
    add_index :commission_components, [:company_id, :is_active], name: 'index_commission_components_on_company_and_active'
    add_index :commission_components, [:company_id, :location_id, :is_active, :sequence], name: 'index_commission_components_lookup'
    add_index :commission_components, [:component_type], name: 'index_commission_components_on_type'
    add_index :commission_components, [:applies_to_role], name: 'index_commission_components_on_role'
  end
end
