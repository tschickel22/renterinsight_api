# frozen_string_literal: true

class CreateContractors < ActiveRecord::Migration[8.0]
  def change
    create_table :contractors do |t|
      t.references :company, null: false, foreign_key: true

      t.string :name, null: false
      t.string :contact_name
      t.string :email
      t.string :phone
      t.string :trade_type, default: 'general'
      t.string :license_number
      t.string :license_state
      t.date :license_expiry
      t.string :insurance_provider
      t.string :insurance_policy_number
      t.date :insurance_expiry
      t.boolean :bonded, default: false
      t.decimal :bond_amount, precision: 10, scale: 2
      t.date :bond_expiry
      t.decimal :hourly_rate, precision: 10, scale: 2
      t.text :notes
      t.string :status, default: 'active'
      t.decimal :rating, precision: 3, scale: 2
      t.boolean :is_deleted, default: false
      t.jsonb :custom_field_values, default: {}

      t.timestamps
    end

    add_index :contractors, :status
    add_index :contractors, :trade_type
    add_index :contractors, :email
  end
end
