# frozen_string_literal: true

class AddWebhookConfigAndRoundRobin < ActiveRecord::Migration[8.0]
  def change
    # Per-key config for inbound-lead webhooks (Zapier/FB/etc):
    #   default_source_id, default_location_id,
    #   assignment_mode ('specific' | 'round_robin' | 'unassigned'),
    #   assigned_user_id (for :specific),
    #   round_robin_list_id (for :round_robin),
    #   dedupe_enabled (bool)
    add_column :api_keys, :webhook_config, :jsonb, default: {}, null: false
    add_index :api_keys, :webhook_config, using: :gin

    # Shared list for round-robin assignment. Referenced from api_keys and
    # from workflow AssignOwner action nodes so both use one cursor and one
    # skip-inactive rule.
    create_table :round_robin_assignment_lists do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.jsonb :user_ids, default: [], null: false      # ordered [12, 15, 18]
      t.integer :cursor, default: 0, null: false       # points to next assignee
      t.boolean :active, default: true, null: false
      t.timestamps
    end

    add_index :round_robin_assignment_lists, [:company_id, :name], unique: true
  end
end
