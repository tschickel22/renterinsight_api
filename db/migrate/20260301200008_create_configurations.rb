# frozen_string_literal: true

class CreateConfigurations < ActiveRecord::Migration[8.0]
  def change
    create_table :configurations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :floor_plan, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.references :configurable, polymorphic: true
      t.string :name
      t.jsonb :selections, default: []
      t.decimal :base_price, precision: 10, scale: 2
      t.decimal :options_total, precision: 10, scale: 2
      t.decimal :total_price, precision: 10, scale: 2
      t.decimal :price_range_low, precision: 10, scale: 2
      t.decimal :price_range_high, precision: 10, scale: 2
      t.string :public_token, null: false
      t.string :status, default: 'draft', null: false
      t.string :customer_name
      t.string :customer_email
      t.string :customer_phone
      t.datetime :shared_at
      t.datetime :viewed_at
      t.datetime :quoted_at

      t.timestamps
    end

    add_index :configurations, :public_token, unique: true
    add_index :configurations, :status
    add_index :configurations, [:company_id, :status]
    add_index :configurations, [:configurable_type, :configurable_id]
  end
end
