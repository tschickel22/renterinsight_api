# frozen_string_literal: true

class CreateCommissionPayments < ActiveRecord::Migration[8.0]
  def change
    create_table :commission_payments do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, foreign_key: true
      t.references :deal, null: false, foreign_key: true
      t.references :payee_user, null: false, foreign_key: { to_table: :users }
      
      t.string :payment_number, null: false
      t.string :status, default: 'pending', null: false
      
      # Amounts
      t.decimal :amount, precision: 15, scale: 2, null: false
      
      # Calculation details (JSONB for audit trail)
      t.jsonb :calculation_details, default: {}
      
      # Workflow tracking
      t.references :approved_by_user, foreign_key: { to_table: :users }
      t.datetime :approved_at
      t.references :paid_by_user, foreign_key: { to_table: :users }
      t.datetime :paid_at
      t.string :payment_method  # "check", "direct_deposit", "cash"
      t.string :payment_reference  # Check number, transaction ID, etc.
      
      # Reversal support
      t.boolean :is_reversed, default: false
      t.references :reversed_by_user, foreign_key: { to_table: :users }
      t.datetime :reversed_at
      t.text :reversal_reason
      
      # Notes and metadata
      t.text :notes
      t.jsonb :metadata, default: {}
      
      # Soft delete
      t.boolean :is_deleted, default: false
      t.datetime :deleted_at
      
      t.timestamps
    end
    
    # Indexes for efficient queries
    add_index :commission_payments, [:company_id, :payment_number], unique: true, name: 'index_commission_payments_unique_number'
    add_index :commission_payments, [:company_id, :status], name: 'index_commission_payments_status'
    add_index :commission_payments, [:payee_user_id, :status], name: 'index_commission_payments_payee_status'
    add_index :commission_payments, [:deal_id], name: 'index_commission_payments_deal'
    add_index :commission_payments, [:approved_at], name: 'index_commission_payments_approved_at'
    add_index :commission_payments, [:paid_at], name: 'index_commission_payments_paid_at'
    add_index :commission_payments, [:is_deleted], name: 'index_commission_payments_deleted'
  end
end
