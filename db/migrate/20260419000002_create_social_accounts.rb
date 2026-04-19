# frozen_string_literal: true

class CreateSocialAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :social_accounts do |t|
      t.bigint  :company_id, null: false
      t.bigint  :location_id
      t.string  :platform, null: false
      t.string  :account_type, null: false
      t.string  :external_id, null: false
      t.string  :name
      t.string  :page_url
      t.text    :access_token_encrypted
      t.string  :token_type
      t.datetime :token_expires_at
      t.string  :status, default: 'active'
      t.datetime :last_sync_at
      t.jsonb   :metadata, default: {}
      t.boolean :is_deleted, default: false

      t.timestamps
    end

    add_index :social_accounts, [:company_id, :platform]
    add_index :social_accounts, [:location_id, :platform]
    add_index :social_accounts, [:external_id, :platform]
  end
end
