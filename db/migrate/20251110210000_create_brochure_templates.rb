# frozen_string_literal: true

class CreateBrochureTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :brochure_templates do |t|
      t.string :name, null: false
      t.text :description
      t.string :template_key, null: false
      t.string :theme
      t.string :preview_image
      t.jsonb :template_data, null: false, default: {}
      t.boolean :is_default, default: false
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :brochure_templates, :template_key, unique: true
    add_index :brochure_templates, :is_default
    add_index :brochure_templates, :active
  end
end
