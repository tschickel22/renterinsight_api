# frozen_string_literal: true

# E68 step 6: the installer's rate card for a linked dealer, price requests
# and change orders on handed-off jobs, all approved by the dealer.
# New tables and new nullable columns only, so the code running during a
# release never notices them.
class CreateLinkRateCardsAndChanges < ActiveRecord::Migration[8.0]
  def change
    create_table :link_rate_cards do |t|
      t.references :company_link, null: false, foreign_key: true
      t.integer :version, null: false
      t.string :status, null: false, default: 'submitted' # submitted, approved, declined, superseded, withdrawn
      t.jsonb :items, null: false, default: []           # [{ key, name, kind, unit, price }]
      t.text :note
      t.references :submitted_by, foreign_key: { to_table: :users }
      t.references :decided_by, foreign_key: { to_table: :users }
      t.datetime :decided_at
      t.text :decline_reason
      t.timestamps
    end
    add_index :link_rate_cards, %i[company_link_id version], unique: true

    create_table :project_link_changes do |t|
      t.references :project_link, null: false, foreign_key: true
      t.integer :number, null: false
      t.string :kind, null: false                         # price (the job's price), change (a change order)
      t.string :status, null: false, default: 'pending'   # pending, approved, declined, withdrawn
      t.text :description
      t.jsonb :lines, null: false, default: []           # [{ item_key, name, unit, qty, price, amount }]
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.references :dealer_phase, foreign_key: { to_table: :project_phases } # the one phase it holds, or nil for the job
      t.references :requested_by, foreign_key: { to_table: :users }
      t.references :decided_by, foreign_key: { to_table: :users }
      t.datetime :decided_at
      t.text :decline_reason
      t.references :dealer_cost_item, foreign_key: { to_table: :project_cost_items, on_delete: :nullify }
      t.timestamps
    end
    add_index :project_link_changes, %i[project_link_id number], unique: true
    add_index :project_link_changes, %i[project_link_id status]

    add_column :project_links, :price_source, :string # card, dealer, quote; nil on jobs sent before step 6
    add_column :project_links, :price_lines, :jsonb, null: false, default: []
    add_reference :project_links, :link_rate_card, foreign_key: true
  end
end
