# frozen_string_literal: true

class CreateAccountLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :account_links do |t|
      t.references :company, null: false, foreign_key: true
      t.string :linkable_type, null: false
      t.bigint :linkable_id, null: false
      t.string :link_purpose, null: false
      t.references :chart_of_account, null: false, foreign_key: true
      t.integer :priority, default: 0
      t.boolean :is_active, default: true
      t.timestamps
    end

    add_index :account_links,
              [:linkable_type, :linkable_id, :link_purpose],
              name: 'idx_account_links_polymorphic_purpose'
    add_index :account_links, [:company_id, :link_purpose]
  end
end
