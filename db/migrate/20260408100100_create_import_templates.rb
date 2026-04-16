class CreateImportTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :import_templates do |t|
      t.references :company, null: true, foreign_key: true, index: true
      t.string  :module_type, null: false
      t.string  :name, null: false
      t.text    :description
      t.jsonb   :column_mapping, default: {}, null: false
      t.string  :duplicate_strategy, default: 'skip'
      t.jsonb   :duplicate_match_fields, default: [], null: false
      t.jsonb   :options, default: {}, null: false
      t.boolean :is_platform_default, default: false, null: false
      t.timestamps
    end

    add_index :import_templates, :module_type
    add_index :import_templates, [:company_id, :module_type]
  end
end
