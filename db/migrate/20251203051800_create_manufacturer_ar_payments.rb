# frozen_string_literal: true

class CreateManufacturerArPayments < ActiveRecord::Migration[8.0]
  def change
    create_table :manufacturer_ar_payments do |t|
      # Tenant Isolation
      t.bigint :company_id, null: false
      
      # Relationships
      t.bigint :manufacturer_ar_transaction_id, null: false
      
      # Payment Details
      t.string :payment_number, null: false # e.g., "MARP-2025-1234"
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.date :payment_date, null: false
      
      # Payment Method
      t.string :payment_method # 'check', 'wire', 'ach', 'other'
      t.string :reference_number # Check number, wire confirmation, etc.
      
      # Attachments (remittance advice, check image, etc.)
      # Will use ActiveStorage has_many_attached :attachments
      
      # Notes
      t.text :notes
      
      # Audit
      t.string :recorded_by # User who recorded the payment
      
      t.timestamps
    end
    
    # Foreign Keys
    add_foreign_key :manufacturer_ar_payments, :companies, on_delete: :cascade
    add_foreign_key :manufacturer_ar_payments, :manufacturer_ar_transactions, on_delete: :cascade
    
    # Indexes
    add_index :manufacturer_ar_payments, :company_id
    add_index :manufacturer_ar_payments, :manufacturer_ar_transaction_id, name: 'index_mfr_ar_payments_on_transaction_id'
    add_index :manufacturer_ar_payments, [:company_id, :payment_number], unique: true
    add_index :manufacturer_ar_payments, :payment_date
    add_index :manufacturer_ar_payments, :payment_method
  end
end
