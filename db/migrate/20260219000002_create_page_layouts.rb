# frozen_string_literal: true

class CreatePageLayouts < ActiveRecord::Migration[8.0]
  def change
    create_table :page_layouts do |t|
      t.integer :company_id, null: false
      t.string :module_name, null: false
      t.string :layout_type, null: false, default: 'detail'
      t.jsonb :layout_data, null: false, default: {}
      t.boolean :is_default, default: false
      t.bigint :created_by_id
      t.bigint :updated_by_id

      t.timestamps
    end

    add_index :page_layouts, [:company_id, :module_name, :layout_type], unique: true, name: 'idx_page_layouts_company_module_type'
    add_index :page_layouts, :company_id
  end
end
