# frozen_string_literal: true

class CreateInventoryTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :inventory_transactions do |t|
      t.references :company, null: false, foreign_key: true
      t.references :part, null: false, foreign_key: true
      t.references :location, null: false, foreign_key: true
      t.references :bin, foreign_key: true
      
      # Transaction details
      t.string :transaction_type, null: false
      t.decimal :quantity, precision: 10, scale: 3, null: false
      t.decimal :unit_cost, precision: 10, scale: 2
      
      # Reference to source transaction (for transfers)
      t.references :source_transaction, foreign_key: { to_table: :inventory_transactions }
      
      # Tracking fields
      t.string :serial_number
      t.string :lot_number
      t.date :lot_expiration_date
      
      # Related entities
      t.bigint :purchase_order_line_id
      t.bigint :job_id
      t.string :reference_type
      t.bigint :reference_id
      
      # Metadata
      t.text :notes
      t.string :transaction_number
      
      # Audit
      t.references :created_by, foreign_key: { to_table: :users }
      t.datetime :transaction_date, null: false
      t.timestamps
      
      # Indexes
      t.index [:company_id, :part_id]
      t.index [:company_id, :location_id]
      t.index [:company_id, :transaction_date]
      t.index [:company_id, :transaction_type]
      t.index :transaction_number, unique: true
      t.index [:reference_type, :reference_id]
      t.index :serial_number
      t.index :lot_number
    end
  end
end
