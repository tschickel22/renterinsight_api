# frozen_string_literal: true

# A change to a factory order the factory already has (backlog E52, phase 1):
# the lines and colors added, removed or changed against what was sent, the
# cost difference, and the production status the rep reports. Approved by
# the factory, it rewrites the PO. Signatures come with the agreement.
class CreatePurchaseOrderChangeOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :purchase_order_change_orders do |t|
      t.references :company, null: false, foreign_key: true
      t.references :purchase_order, null: false, foreign_key: true
      t.references :deal, foreign_key: true
      t.references :deal_home_build, foreign_key: { on_delete: :nullify }
      t.integer :number, null: false
      t.string :status, null: false, default: 'draft'
      t.string :production_status, null: false, default: 'not_released'
      t.jsonb :changes_list, null: false, default: {}
      t.jsonb :new_snapshot, null: false, default: {}
      t.decimal :cost_delta, precision: 12, scale: 2, null: false, default: 0
      t.text :notes
      t.datetime :emailed_at
      t.string :emailed_to
      t.datetime :approved_at
      t.datetime :voided_at
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :purchase_order_change_orders, %i[purchase_order_id number], unique: true
  end
end
