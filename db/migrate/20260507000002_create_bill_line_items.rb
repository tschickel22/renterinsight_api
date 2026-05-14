# frozen_string_literal: true

class CreateBillLineItems < ActiveRecord::Migration[8.0]
  def change
    create_table :bill_line_items do |t|
      t.references :bill, null: false, foreign_key: true
      t.references :chart_of_account, null: false, foreign_key: true
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.string :description
      t.references :location, foreign_key: true
      t.string :department
      t.integer :position, default: 0
      t.timestamps
    end
  end
end
