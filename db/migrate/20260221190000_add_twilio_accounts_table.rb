# frozen_string_literal: true

class AddTwilioAccountsTable < ActiveRecord::Migration[8.0]
  def change
    create_table :twilio_accounts do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.string :sub_account_sid, null: false
      t.text :auth_token, null: false
      t.string :phone_number, null: false
      t.string :phone_number_sid, null: false
      t.string :status, null: false, default: 'provisioning'
      t.datetime :provisioned_at
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :twilio_accounts, :sub_account_sid, unique: true
    add_index :twilio_accounts, :phone_number, unique: true
    add_index :twilio_accounts, :status
  end
end
