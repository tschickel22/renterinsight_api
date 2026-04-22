# frozen_string_literal: true

class CreateFacebookIntegrations < ActiveRecord::Migration[8.0]
  def change
    create_table :facebook_integrations do |t|
      t.bigint :company_id, null: false
      t.bigint :location_id

      t.string :page_id, null: false
      t.string :page_name

      t.text :page_access_token
      t.text :user_access_token
      t.datetime :token_expires_at

      t.string :status, default: 'active'

      t.jsonb :subscribed_fields, default: ['leadgen']
      t.jsonb :field_mapping, default: {}

      t.bigint :default_source_id
      t.bigint :default_owner_id
      t.bigint :default_workflow_id

      t.integer  :lead_count, default: 0
      t.datetime :last_lead_at

      t.jsonb   :metadata, default: {}
      t.boolean :is_deleted, default: false

      t.timestamps
    end

    add_index :facebook_integrations, :company_id
    add_index :facebook_integrations, :page_id
    add_index :facebook_integrations, :status
  end
end
