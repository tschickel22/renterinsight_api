# frozen_string_literal: true

class CreateQuickbooksEntityMappings < ActiveRecord::Migration[8.0]
  def change
    return if table_exists?(:quickbooks_entity_mappings)

    create_table :quickbooks_entity_mappings do |t|
      t.references :company, null: false, foreign_key: true
      t.string :entity_type, null: false
      t.bigint :ri_entity_id, null: false
      t.string :qb_entity_type, null: false
      t.string :qb_entity_id, null: false
      t.string :sync_status, default: 'synced'
      t.text :error_message
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :quickbooks_entity_mappings,
              [:company_id, :entity_type, :ri_entity_id],
              unique: true,
              name: 'idx_qb_entity_mappings_unique'
    add_index :quickbooks_entity_mappings,
              [:company_id, :qb_entity_type, :qb_entity_id],
              name: 'idx_qb_entity_mappings_qb'
  end
end
