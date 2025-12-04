# frozen_string_literal: true

class CreateManufacturerArTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :manufacturer_ar_transactions do |t|
      # Tenant Isolation
      t.bigint :company_id, null: false
      t.bigint :location_id
      
      # Relationships
      t.bigint :warranty_claim_id, null: false
      t.bigint :manufacturer_id, null: false
      
      # Transaction Details
      t.string :transaction_number, null: false # e.g., "MAR-2025-1234"
      t.decimal :original_claim_amount, precision: 12, scale: 2, null: false
      t.decimal :amount_paid_to_date, precision: 12, scale: 2, default: 0.0
      t.decimal :amount_outstanding, precision: 12, scale: 2, null: false
      
      # Status
      t.string :status, null: false, default: 'open'
      # Statuses: open, partial, paid, short_paid, written_off
      
      # Important Dates
      t.date :claim_date
      t.date :expected_payment_date
      t.date :paid_in_full_date
      
      # Notes
      t.text :notes
      t.text :write_off_reason # If written off
      
      # Soft Delete
      t.boolean :is_deleted, default: false, null: false
      t.datetime :deleted_at
      
      t.timestamps
    end
    
    # Foreign Keys
    add_foreign_key :manufacturer_ar_transactions, :companies, on_delete: :cascade
    add_foreign_key :manufacturer_ar_transactions, :locations, on_delete: :nullify
    add_foreign_key :manufacturer_ar_transactions, :warranty_claims, on_delete: :restrict
    add_foreign_key :manufacturer_ar_transactions, :manufacturers, on_delete: :restrict
    
    # Indexes
    add_index :manufacturer_ar_transactions, :company_id
    add_index :manufacturer_ar_transactions, :location_id
    add_index :manufacturer_ar_transactions, :warranty_claim_id
    add_index :manufacturer_ar_transactions, :manufacturer_id
    add_index :manufacturer_ar_transactions, [:company_id, :transaction_number], unique: true
    add_index :manufacturer_ar_transactions, :status
    add_index :manufacturer_ar_transactions, [:company_id, :status]
    add_index :manufacturer_ar_transactions, [:manufacturer_id, :status]
    add_index :manufacturer_ar_transactions, :claim_date
    add_index :manufacturer_ar_transactions, :expected_payment_date
  end
end
