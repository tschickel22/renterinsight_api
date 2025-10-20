# frozen_string_literal: true

class CreateCustomFields < ActiveRecord::Migration[7.1]
  def change
    create_table :custom_fields do |t|
      t.references :company, null: false, foreign_key: true
      t.string :module, null: false
      t.string :name, null: false
      t.string :label, null: false
      t.string :field_type, null: false
      t.boolean :required, default: false
      t.string :default_value
      t.text :options
      t.integer :display_order, default: 0

      t.timestamps
    end

    add_index :custom_fields, [:company_id, :module, :name], unique: true, name: 'index_custom_fields_on_company_module_name'
    add_index :custom_fields, [:company_id, :module]
  end
end
