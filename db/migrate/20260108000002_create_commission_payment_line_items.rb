# frozen_string_literal: true

class CreateCommissionPaymentLineItems < ActiveRecord::Migration[8.0]
  def change
    create_table :commission_payment_line_items do |t|
      t.references :commission_payment, null: false, foreign_key: { on_delete: :cascade }, index: { name: 'index_comm_line_items_on_payment_id' }
      t.references :commission_component, null: true, foreign_key: { on_delete: :nullify }
      
      # Line item details
      t.string :description, null: false, comment: 'Display name of commission component'
      
      # What was this calculated on?
      t.string :calculation_basis, null: false, comment: 'What amount was used as basis (front_gross, back_gross, etc.)'
      t.string :calculation_method, null: false, comment: 'How it was calculated (flat_rate, percentage, tiered, per_unit)'
      
      # Calculation inputs
      t.decimal :rate, precision: 8, scale: 4, null: true, comment: 'Rate used (percentage or per-unit amount)'
      t.decimal :basis_amount, precision: 15, scale: 2, null: false, default: 0, comment: 'Dollar amount commission was calculated on'
      
      # Result
      t.decimal :calculated_amount, precision: 15, scale: 2, null: false, comment: 'Commission earned from this component'
      
      # Display order
      t.integer :display_order, default: 0
      
      # Additional details (e.g., tier breakdown for tiered components)
      t.jsonb :calculation_details, default: {}, null: false
      
      t.timestamps
    end
    
    # Indexes
    add_index :commission_payment_line_items, [:commission_payment_id, :display_order], name: 'index_comm_line_items_on_payment_and_order'
    add_index :commission_payment_line_items, :calculation_basis
    add_index :commission_payment_line_items, :calculation_method
  end
end
