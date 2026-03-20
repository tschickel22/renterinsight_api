# frozen_string_literal: true

class CreateProjectCostItems < ActiveRecord::Migration[8.0]
  def change
    create_table :project_cost_items do |t|
      t.references :company, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :project_phase, null: true, foreign_key: true
      t.references :project_task, null: true, foreign_key: true
      t.string :cost_type, null: false
      t.string :category
      t.string :description, null: false
      t.string :vendor_name
      t.string :invoice_number
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.decimal :quantity, precision: 10, scale: 2, default: 1
      t.decimal :unit_price, precision: 12, scale: 2
      t.date :date
      t.string :status, default: 'pending'
      t.datetime :paid_at
      t.references :approved_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :notes
      t.string :receipt_url
      t.string :receipt_s3_key
      t.references :part, null: true, foreign_key: { on_delete: :nullify }
      t.references :inventory_transaction, null: true, foreign_key: { on_delete: :nullify }
      t.boolean :is_deleted, default: false
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :project_cost_items, :cost_type
    add_index :project_cost_items, :status
    add_index :project_cost_items, :date
  end
end
