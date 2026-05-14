# frozen_string_literal: true

class CreateFiscalPeriods < ActiveRecord::Migration[8.0]
  def change
    create_table :fiscal_periods do |t|
      t.references :company, null: false, foreign_key: true
      t.integer :fiscal_year, null: false
      t.integer :period_number, null: false
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.string :status, default: 'open'
      t.datetime :closed_at
      t.references :closed_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :fiscal_periods,
              [:company_id, :fiscal_year, :period_number],
              unique: true,
              name: 'idx_fiscal_periods_company_year_period'
    add_index :fiscal_periods, [:company_id, :status]
  end
end
