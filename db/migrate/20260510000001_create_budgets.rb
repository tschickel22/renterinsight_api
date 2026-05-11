# frozen_string_literal: true

class CreateBudgets < ActiveRecord::Migration[8.0]
  def change
    create_table :budgets do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :location, foreign_key: true
      t.integer :fiscal_year, null: false
      t.string :name, null: false
      t.text :description
      t.string :budget_type, null: false, default: 'annual'
      t.string :status, null: false, default: 'draft'
      t.string :consolidation_type, null: false, default: 'standalone'
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :approved_at
      t.datetime :locked_at
      t.references :locked_by, foreign_key: { to_table: :users }
      t.text :notes
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :budgets, [:company_id, :fiscal_year]
    add_index :budgets, [:company_id, :status]
    add_index :budgets, [:company_id, :location_id]
    add_index :budgets, [:company_id, :consolidation_type]
    add_index :budgets,
              [:company_id, :fiscal_year, :location_id, :name],
              unique: true,
              name: 'index_budgets_on_company_year_location_name'
  end
end
