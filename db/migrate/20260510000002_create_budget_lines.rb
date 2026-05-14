# frozen_string_literal: true

class CreateBudgetLines < ActiveRecord::Migration[8.0]
  def change
    create_table :budget_lines do |t|
      t.references :budget, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.references :chart_of_account, null: false, foreign_key: true, index: true
      (1..12).each do |month|
        t.decimal :"month_#{month}", precision: 15, scale: 2, default: 0.0, null: false
      end
      t.decimal :annual_total, precision: 15, scale: 2, default: 0.0, null: false
      t.text :notes
      t.timestamps
    end

    add_index :budget_lines,
              [:budget_id, :chart_of_account_id],
              unique: true,
              name: 'index_budget_lines_on_budget_and_account'
  end
end
