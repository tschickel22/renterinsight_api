# frozen_string_literal: true

class CreateBankRules < ActiveRecord::Migration[8.0]
  def change
    create_table :bank_rules do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.references :bank_account, foreign_key: true, null: true
      t.string :match_type, null: false
      t.string :match_field, default: 'description'
      t.string :match_value, null: false
      t.decimal :min_amount, precision: 15, scale: 2
      t.decimal :max_amount, precision: 15, scale: 2
      t.string :transaction_direction, default: 'any'
      t.references :assign_account, foreign_key: { to_table: :chart_of_accounts }, null: false
      t.references :assign_contact, foreign_key: { to_table: :contacts }, null: true
      t.string :assign_memo
      t.boolean :auto_confirm, default: false
      t.integer :priority, default: 100
      t.integer :match_count, default: 0
      t.boolean :is_active, default: true
      t.datetime :last_matched_at
      t.timestamps
    end

    add_index :bank_rules, [:company_id, :priority]
    add_index :bank_rules, [:company_id, :is_active]
  end
end
