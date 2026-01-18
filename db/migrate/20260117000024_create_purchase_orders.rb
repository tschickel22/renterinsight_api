# frozen_string_literal: true

class CreatePurchaseOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :purchase_orders do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, null: true, foreign_key: true
      t.references :supplier, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }, null: true
      t.references :approved_by, foreign_key: { to_table: :users }, null: true
      
      t.string :po_number, null: false
      t.string :status, null: false, default: 'draft'
      t.date :order_date, null: false
      t.date :expected_delivery_date
      t.date :delivery_date
      
      t.decimal :subtotal, precision: 10, scale: 2, default: 0.0
      t.decimal :tax_amount, precision: 10, scale: 2, default: 0.0
      t.decimal :shipping_cost, precision: 10, scale: 2, default: 0.0
      t.decimal :total_amount, precision: 10, scale: 2, default: 0.0
      
      t.string :shipping_method
      t.string :tracking_number
      t.text :notes
      t.text :terms
      
      t.string :ship_to_name
      t.string :ship_to_address1
      t.string :ship_to_address2
      t.string :ship_to_city
      t.string :ship_to_state
      t.string :ship_to_zip
      t.string :ship_to_country, default: 'US'
      
      t.datetime :sent_at
      t.datetime :approved_at
      t.datetime :cancelled_at
      t.string :cancelled_reason
      
      t.boolean :is_deleted, default: false, null: false
      t.datetime :deleted_at
      t.jsonb :custom_fields, default: {}
      
      t.timestamps
    end

    add_index :purchase_orders, [:company_id, :po_number], unique: true, 
              where: "is_deleted = false"
    add_index :purchase_orders, [:company_id, :status]
    add_index :purchase_orders, [:company_id, :supplier_id]
    add_index :purchase_orders, [:company_id, :location_id]
    add_index :purchase_orders, [:order_date]
    add_index :purchase_orders, [:expected_delivery_date]
    add_index :purchase_orders, :is_deleted
    add_index :purchase_orders, :status

    create_table :purchase_order_lines do |t|
      t.references :purchase_order, null: false, foreign_key: true
      t.references :part, null: false, foreign_key: true
      
      t.integer :line_number, null: false
      t.decimal :quantity_ordered, precision: 10, scale: 3, null: false
      t.decimal :quantity_received, precision: 10, scale: 3, default: 0.0, null: false
      t.decimal :unit_cost, precision: 10, scale: 2, null: false
      t.decimal :line_total, precision: 10, scale: 2, null: false
      
      t.text :description
      t.text :notes
      t.date :expected_date
      t.string :manufacturer_part_no
      
      t.jsonb :custom_fields, default: {}
      
      t.timestamps
    end

    add_index :purchase_order_lines, [:purchase_order_id, :line_number], unique: true
    add_index :purchase_order_lines, :part_id unless index_exists?(:purchase_order_lines, :part_id)
    add_index :purchase_order_lines, [:purchase_order_id, :part_id] unless index_exists?(:purchase_order_lines, [:purchase_order_id, :part_id])
    
    add_reference :inventory_transactions, :purchase_order_line, null: true, foreign_key: true unless column_exists?(:inventory_transactions, :purchase_order_line_id)
  end
end
