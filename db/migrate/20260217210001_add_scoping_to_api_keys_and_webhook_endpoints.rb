# frozen_string_literal: true

class AddScopingToApiKeysAndWebhookEndpoints < ActiveRecord::Migration[8.0]
  def change
    # API Keys: Make company_id nullable for platform-level keys
    change_column_null :api_keys, :company_id, true

    # Webhook Endpoints: Make company_id nullable for platform-level webhooks
    change_column_null :webhook_endpoints, :company_id, true

    # Webhook Endpoints: Add location_ids for optional location filtering
    # NULL = all locations, [1,2,3] = only fire for those locations
    add_column :webhook_endpoints, :location_ids, :jsonb, default: nil

    # Webhook Endpoints: Add description for better identification
    add_column :webhook_endpoints, :description, :string

    # Webhook Endpoints: Track who created it (api_keys already has this)
    add_column :webhook_endpoints, :created_by_user_id, :bigint
    add_index :webhook_endpoints, :created_by_user_id
  end
end
