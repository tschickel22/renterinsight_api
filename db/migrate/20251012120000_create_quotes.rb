# frozen_string_literal: true

class CreateQuotes < ActiveRecord::Migration[8.0]
  def change
    create_table :quotes do |t|
      # Foreign Keys
      t.references :account, null: true, foreign_key: true
      t.references :contact, null: true, foreign_key: true
      t.string :customer_id # For external customer references
      t.string :vehicle_id # For external vehicle references
      
      # Quote Details
      t.string :quote_number, null: false
      t.string :status, null: false, default: 'draft'
      
      # Financial Information
      t.decimal :subtotal, precision: 15, scale: 2, default: 0.0, null: false
      t.decimal :tax, precision: 15, scale: 2, default: 0.0, null: false
      t.decimal :total, precision: 15, scale: 2, default: 0.0, null: false
      
      # Quote Items (stored as JSON)
      t.json :items, default: []
      
      # Dates
      t.date :valid_until
      t.datetime :sent_at
      t.datetime :viewed_at
      t.datetime :accepted_at
      t.datetime :rejected_at
      
      # Additional Information
      t.text :notes
      t.json :custom_fields, default: {}
      
      # Soft Delete
      t.boolean :is_deleted, default: false, null: false
      t.datetime :deleted_at
      
      t.timestamps
    end

    # Indexes (account_id and contact_id already indexed by t.references)
    add_index :quotes, :quote_number, unique: true
    add_index :quotes, :status
    add_index :quotes, :customer_id
    add_index :quotes, :vehicle_id
    add_index :quotes, :valid_until
    add_index :quotes, :is_deleted
    add_index :quotes, :created_at
  end
end
