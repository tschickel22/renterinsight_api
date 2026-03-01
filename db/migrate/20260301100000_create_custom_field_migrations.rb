# frozen_string_literal: true

class CreateCustomFieldMigrations < ActiveRecord::Migration[8.0]
  def change
    create_table :custom_field_migrations do |t|
      t.references :source_custom_field, null: false, foreign_key: { to_table: :custom_fields }
      t.string :target_module, null: false
      t.references :target_custom_field, foreign_key: { to_table: :custom_fields }, null: true
      t.string :migration_type, null: false, default: 'create_new'
      t.references :company, null: false, foreign_key: true
      t.timestamps
    end

    add_index :custom_field_migrations, [:source_custom_field_id, :target_module], unique: true, name: 'idx_cf_migrations_source_target_module'
  end
end
